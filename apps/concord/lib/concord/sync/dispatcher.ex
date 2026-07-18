defmodule Concord.Sync.Dispatcher do
  @moduledoc """
  Receives change events from the Raft state machine via Ra `:send_msg` effects
  and forwards them to the Watch Hub and Change Log.

  Only the leader node emits `:send_msg` effects, so the Dispatcher only
  processes events on the current leader. On follower nodes, it idles.
  """

  use GenServer
  require Logger

  alias Concord.Sync.{ChangeLog, Event, WatchHub}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Dispatch events directly (called from state machine or tests).
  """
  @spec dispatch([Event.t()]) :: :ok
  def dispatch(events) when is_list(events) do
    GenServer.cast(__MODULE__, {:dispatch, events})
  end

  # ──────────────────────────────────────────────
  # GenServer callbacks
  # ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    ChangeLog.ensure_table()
    {:ok, %{events_dispatched: 0}}
  end

  @impl true
  def handle_cast({:dispatch, events}, state) do
    events = ChangeLog.append_new(events)
    WatchHub.notify(events)

    :telemetry.execute(
      [:concord, :sync, :event_dispatched],
      %{count: length(events)},
      %{node: node()}
    )

    {:noreply, %{state | events_dispatched: state.events_dispatched + length(events)}}
  end

  # Handle Ra :send_msg effects
  @impl true
  def handle_info({:changes, events}, state) when is_list(events) do
    handle_cast({:dispatch, events}, state)
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
