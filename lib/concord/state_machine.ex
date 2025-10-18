defmodule Concord.StateMachine do
  @moduledoc """
  The Raft state machine for Concord.
  Implements the :ra_machine behavior to provide a replicated key-value store.
  """

  @behaviour :ra_machine

  @impl :ra_machine
  def init(_config) do
    # Create the ETS table with a known name
    _table = :ets.new(:concord_store, [:set, :public, :named_table])
    # Return simple state similar to ra_machine_simple
    {:concord_kv, %{}}
  end

  @impl :ra_machine
  def apply(meta, {:put, key, value}, {:concord_kv, data}) do
    start_time = System.monotonic_time()
    :ets.insert(:concord_store, {key, value})

    # Emit telemetry
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :put, key: key, index: Map.get(meta, :index)}
    )

    {{:concord_kv, data}, :ok, []}
  end

  def apply(meta, {:delete, key}, {:concord_kv, data}) do
    start_time = System.monotonic_time()
    :ets.delete(:concord_store, key)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :delete, key: key, index: Map.get(meta, :index)}
    )

    {{:concord_kv, data}, :ok, []}
  end

  # Catch-all for unknown commands (e.g., internal ra commands)
  def apply(meta, command, {:concord_kv, data}) do
    # Log the unknown command for debugging
    :telemetry.execute(
      [:concord, :operation, :unknown_command],
      %{command: inspect(command)},
      %{index: Map.get(meta, :index)}
    )

    {{:concord_kv, data}, :ok, []}
  end

  @impl :ra_machine
  def state_enter(status, {:concord_kv, _data}) do
    :telemetry.execute(
      [:concord, :state, :change],
      %{timestamp: System.system_time()},
      %{status: status, node: node()}
    )

    []
  end

  def query({:get, key}, {:concord_kv, _data}) do
    case :ets.lookup(:concord_store, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  def query(:get_all, {:concord_kv, _data}) do
    all = :ets.tab2list(:concord_store)
    {:ok, Map.new(all)}
  end

  def query(:stats, {:concord_kv, _data}) do
    info = :ets.info(:concord_store)

    {:ok,
     %{
       size: Keyword.get(info, :size, 0),
       memory: Keyword.get(info, :memory, 0)
     }}
  end

  @impl :ra_machine
  def snapshot_installed(snapshot, _metadata, {:concord_kv, _data}, _aux) do
    :ets.delete_all_objects(:concord_store)

    Enum.each(snapshot, fn {k, v} ->
      :ets.insert(:concord_store, {k, v})
    end)

    :telemetry.execute(
      [:concord, :snapshot, :installed],
      %{size: length(snapshot)},
      %{node: node()}
    )

    []
  end

  def snapshot({:concord_kv, _data}) do
    data = :ets.tab2list(:concord_store)

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
