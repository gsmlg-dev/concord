defmodule Concord.Sync.WatchHub do
  @moduledoc """
  Registry-based subscriber management for Concord's watch protocol.

  Watchers register with a selector (key, prefix, or range) and receive
  matching events pushed to their mailbox. Supports bounded delivery queues
  with backpressure.

  ## Usage

      {:ok, watch_ref} = Concord.Sync.WatchHub.subscribe({:prefix, "/tasks/"}, self())

      receive do
        {:concord_event, ^watch_ref, event} -> handle(event)
      end

      :ok = Concord.Sync.WatchHub.unsubscribe(watch_ref)
  """

  use GenServer
  require Logger

  alias Concord.KV.Selector
  alias Concord.Sync.Event

  @max_queue_size 1_000

  defstruct watchers: %{}, monitors: %{}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribes a process to events matching the given selector.

  Returns `{:ok, watch_ref}` where `watch_ref` is a unique reference.
  """
  @spec subscribe(Selector.t(), pid(), keyword()) :: {:ok, reference()} | {:error, term()}
  def subscribe(selector, subscriber_pid, opts \\ []) do
    with :ok <- Selector.validate(selector) do
      GenServer.call(__MODULE__, {:subscribe, selector, subscriber_pid, opts})
    end
  end

  @doc """
  Unsubscribes a watch by its reference.
  """
  @spec unsubscribe(reference()) :: :ok
  def unsubscribe(watch_ref) do
    GenServer.call(__MODULE__, {:unsubscribe, watch_ref})
  end

  @doc """
  Delivers matching events to all registered watchers.
  Called by the Dispatcher.
  """
  @spec notify([Event.t()]) :: :ok
  def notify(events) when is_list(events) do
    GenServer.cast(__MODULE__, {:notify, events})
  end

  @doc """
  Returns the count of active watchers.
  """
  @spec count() :: non_neg_integer()
  def count do
    GenServer.call(__MODULE__, :count)
  end

  # ──────────────────────────────────────────────
  # GenServer callbacks
  # ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:subscribe, selector, pid, opts}, _from, state) do
    watch_ref = make_ref()
    monitor_ref = Process.monitor(pid)
    max_queue = Keyword.get(opts, :max_queue, @max_queue_size)

    watcher = %{
      selector: selector,
      pid: pid,
      monitor_ref: monitor_ref,
      max_queue: max_queue,
      pending: 0
    }

    new_watchers = Map.put(state.watchers, watch_ref, watcher)
    new_monitors = Map.put(state.monitors, monitor_ref, watch_ref)

    :telemetry.execute(
      [:concord, :sync, :watch_created],
      %{count: map_size(new_watchers)},
      %{selector: selector}
    )

    {:reply, {:ok, watch_ref}, %{state | watchers: new_watchers, monitors: new_monitors}}
  end

  def handle_call({:unsubscribe, watch_ref}, _from, state) do
    case Map.get(state.watchers, watch_ref) do
      nil ->
        {:reply, :ok, state}

      watcher ->
        Process.demonitor(watcher.monitor_ref, [:flush])
        new_watchers = Map.delete(state.watchers, watch_ref)
        new_monitors = Map.delete(state.monitors, watcher.monitor_ref)

        :telemetry.execute(
          [:concord, :sync, :watch_cancelled],
          %{count: map_size(new_watchers)},
          %{}
        )

        {:reply, :ok, %{state | watchers: new_watchers, monitors: new_monitors}}
    end
  end

  def handle_call(:count, _from, state) do
    {:reply, map_size(state.watchers), state}
  end

  @impl true
  def handle_cast({:notify, events}, state) do
    new_watchers =
      Enum.reduce(state.watchers, state.watchers, fn {watch_ref, watcher}, acc ->
        matching = Enum.filter(events, &Selector.matches?(watcher.selector, &1.key))

        if matching != [] do
          if watcher.pending + length(matching) > watcher.max_queue do
            # Backpressure: warn subscriber
            send(watcher.pid, {:concord_slow_consumer, watch_ref})
            acc
          else
            Enum.each(matching, fn event ->
              send(watcher.pid, {:concord_event, watch_ref, event})
            end)

            Map.update!(acc, watch_ref, fn w ->
              %{w | pending: w.pending + length(matching)}
            end)
          end
        else
          acc
        end
      end)

    {:noreply, %{state | watchers: new_watchers}}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, monitor_ref) do
      nil ->
        {:noreply, state}

      watch_ref ->
        new_watchers = Map.delete(state.watchers, watch_ref)
        new_monitors = Map.delete(state.monitors, monitor_ref)

        Logger.debug("Watch #{inspect(watch_ref)} auto-cleaned (subscriber DOWN)")

        {:noreply, %{state | watchers: new_watchers, monitors: new_monitors}}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
