defmodule Concord.StateMachine do
  @moduledoc """
  The Raft state machine for Concord.
  Implements the :ra_machine behavior to provide a replicated key-value store.
  """

  @behaviour :ra_machine

  @impl :ra_machine
  def init(_config) do
    table = :ets.new(:concord_store, [:set, :public, :named_table])
    %{table: table}
  end

  @impl :ra_machine
  def apply(meta, {:put, key, value}, state) do
    start_time = System.monotonic_time()
    :ets.insert(state.table, {key, value})

    # Emit telemetry
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :put, key: key, index: Map.get(meta, :index)}
    )

    {state, :ok, []}
  end

  def apply(meta, {:delete, key}, state) do
    start_time = System.monotonic_time()
    :ets.delete(state.table, key)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :delete, key: key, index: Map.get(meta, :index)}
    )

    {state, :ok, []}
  end

  @impl :ra_machine
  def state_enter(status, state) do
    :telemetry.execute(
      [:concord, :state, :change],
      %{timestamp: System.system_time()},
      %{status: status, node: node()}
    )

    state
  end

  def query({:get, key}, state) do
    case :ets.lookup(state.table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  def query(:get_all, state) do
    all = :ets.tab2list(state.table)
    {:ok, Map.new(all)}
  end

  def query(:stats, state) do
    info = :ets.info(state.table)

    {:ok,
     %{
       size: Keyword.get(info, :size, 0),
       memory: Keyword.get(info, :memory, 0)
     }}
  end

  @impl :ra_machine
  def snapshot_installed(snapshot, state) do
    :ets.delete_all_objects(state.table)

    Enum.each(snapshot, fn {k, v} ->
      :ets.insert(state.table, {k, v})
    end)

    :telemetry.execute(
      [:concord, :snapshot, :installed],
      %{size: length(snapshot)},
      %{node: node()}
    )

    {state, []}
  end

  def snapshot(state) do
    data = :ets.tab2list(state.table)

    :telemetry.execute(
      [:concord, :snapshot, :created],
      %{size: length(data)},
      %{node: node()}
    )

    data
  end

  @impl :ra_machine
  def version, do: 1
end
