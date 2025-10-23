defmodule Concord.EventStream do
  @moduledoc """
  Real-time event streaming for Concord operations using GenStage.

  Provides change data capture (CDC) functionality, allowing applications
  to subscribe to data changes in real-time with back-pressure support.

  ## Features

  - Real-time notifications for put, delete, and bulk operations
  - Key pattern matching for filtering events
  - Back-pressure support via GenStage
  - Multiple concurrent subscribers
  - Minimal performance overhead

  ## Configuration

      config :concord,
        event_stream: [
          enabled: true,
          buffer_size: 10_000  # Max events to buffer
        ]

  ## Usage

      # Subscribe to all events
      {:ok, subscription} = Concord.EventStream.subscribe()

      # Subscribe with key pattern filter
      {:ok, subscription} = Concord.EventStream.subscribe(
        key_pattern: ~r/^user:/
      )

      # Receive events
      receive do
        {:concord_event, event} ->
          IO.inspect(event)
          # %{
          #   type: :put,
          #   key: "user:123",
          #   value: %{name: "Alice"},
          #   timestamp: ~U[2025-10-23 12:00:00Z],
          #   node: :"node1@127.0.0.1"
          # }
      end

      # Unsubscribe
      Concord.EventStream.unsubscribe(subscription)

  ## Event Format

  Events are maps with the following structure:

      %{
        type: :put | :delete | :put_many | :delete_many,
        key: binary(),           # For single operations
        keys: [binary()],        # For bulk operations
        value: term(),           # For put operations
        timestamp: DateTime.t(),
        node: atom(),
        metadata: map()
      }
  """

  use GenStage
  require Logger

  @type event :: %{
          type: atom(),
          key: binary() | nil,
          keys: [binary()] | nil,
          value: term() | nil,
          timestamp: DateTime.t(),
          node: atom(),
          metadata: map()
        }

  @type subscription :: GenStage.stage()

  ## Public API

  @doc """
  Starts the event stream GenStage producer.
  """
  def start_link(opts \\ []) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribes to Concord events.

  ## Options

  - `:key_pattern` - Regex pattern to filter keys (default: match all)
  - `:event_types` - List of event types to receive (default: all)
  - `:max_demand` - Maximum demand for back-pressure (default: 1000)

  ## Examples

      # Subscribe to all events
      {:ok, sub} = Concord.EventStream.subscribe()

      # Subscribe only to user-related keys
      {:ok, sub} = Concord.EventStream.subscribe(
        key_pattern: ~r/^user:/
      )

      # Subscribe only to delete events
      {:ok, sub} = Concord.EventStream.subscribe(
        event_types: [:delete, :delete_many]
      )
  """
  @spec subscribe(keyword()) :: {:ok, subscription()} | {:error, term()}
  def subscribe(opts \\ []) do
    if enabled?() do
      consumer = spawn_consumer(opts)
      {:ok, consumer}
    else
      {:error, :event_stream_disabled}
    end
  end

  @doc """
  Unsubscribes from Concord events.
  """
  @spec unsubscribe(subscription()) :: :ok
  def unsubscribe(subscription) do
    if Process.alive?(subscription) do
      GenStage.stop(subscription, :normal)
    end

    :ok
  end

  @doc """
  Publishes an event to all subscribers.

  This is called automatically by Concord operations via telemetry.
  You can also manually publish custom events.
  """
  @spec publish(event()) :: :ok
  def publish(event) do
    if enabled?() do
      GenStage.cast(__MODULE__, {:notify, event})
    end

    :ok
  end

  @doc """
  Returns true if event streaming is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config() |> Keyword.get(:enabled, false)
  end

  @doc """
  Returns current event stream statistics.
  """
  @spec stats() :: map()
  def stats do
    if enabled?() do
      GenStage.call(__MODULE__, :stats)
    else
      %{enabled: false}
    end
  end

  ## GenStage Callbacks (Producer)

  @impl true
  def init(_opts) do
    if enabled?() do
      Logger.info("Concord event stream started")
      {:producer, %{queue: :queue.new(), demand: 0, events_published: 0}}
    else
      :ignore
    end
  end

  @impl true
  def handle_demand(incoming_demand, state) do
    %{queue: queue, demand: pending_demand} = state
    new_demand = pending_demand + incoming_demand

    {events, new_queue, remaining_demand} = take_events(queue, new_demand, [])

    {:noreply, events, %{state | queue: new_queue, demand: remaining_demand}}
  end

  @impl true
  def handle_cast({:notify, event}, state) do
    %{queue: queue, demand: demand, events_published: count} = state

    new_queue = :queue.in(event, queue)
    new_state = %{state | queue: new_queue, events_published: count + 1}

    if demand > 0 do
      {events, final_queue, remaining_demand} = take_events(new_queue, demand, [])
      {:noreply, events, %{new_state | queue: final_queue, demand: remaining_demand}}
    else
      {:noreply, [], new_state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      enabled: true,
      queue_size: :queue.len(state.queue),
      pending_demand: state.demand,
      events_published: state.events_published
    }

    {:reply, stats, [], state}
  end

  ## Private Functions

  defp config do
    Application.get_env(:concord, :event_stream, [])
  end

  defp take_events(queue, 0, events), do: {Enum.reverse(events), queue, 0}

  defp take_events(queue, demand, events) do
    case :queue.out(queue) do
      {{:value, event}, new_queue} ->
        take_events(new_queue, demand - 1, [event | events])

      {:empty, queue} ->
        {Enum.reverse(events), queue, demand}
    end
  end

  defp spawn_consumer(opts) do
    key_pattern = Keyword.get(opts, :key_pattern)
    event_types = Keyword.get(opts, :event_types)
    max_demand = Keyword.get(opts, :max_demand, 1000)
    subscriber_pid = self()

    {:ok, pid} =
      GenStage.start_link(
        Concord.EventStream.Consumer,
        %{
          subscriber: subscriber_pid,
          key_pattern: key_pattern,
          event_types: event_types
        },
        []
      )

    {:ok, _subscription} =
      GenStage.sync_subscribe(pid,
        to: __MODULE__,
        max_demand: max_demand,
        min_demand: div(max_demand, 2)
      )

    pid
  end
end
