defmodule Concord.StateMachine do
  @moduledoc """
  Compatibility materializer for the protocol-independent Concord state-machine
  core.

  The authoritative service state is the immutable value returned by
  `Concord.StateMachine.Core`. This module maintains legacy ETS materialized
  views for callers that have not yet migrated to core queries.
  """

  alias Concord.StateMachine.Core
  alias Concord.StateMachine.Core.{Context, State}
  alias Concord.StateMachine.Observer
  alias Concord.StorageScope

  def init(_config) do
    state = Core.init()
    materialize(state)
    external(state)
  end

  def apply(meta, command, state) do
    previous_state =
      state
      |> restore!()
      |> maybe_import_legacy_data()

    context = context(meta)
    started_at = System.monotonic_time()
    {result, state} = Core.apply_compatibility(context, command, previous_state)
    materialize(state)
    Observer.committed(context, command, previous_state, state, observer_source())

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: System.monotonic_time() - started_at},
      telemetry_metadata(command, result, context)
    )

    {external(state), result, []}
  end

  @doc false
  def apply_command(meta, command, state) do
    external_input = state

    previous_state =
      state
      |> restore!()
      |> maybe_import_legacy_data()
      |> merge_legacy_index_views()

    context = context(meta)
    started_at = System.monotonic_time()
    {result, state} = Core.apply_command(context, command, previous_state)
    materialize(state)
    Observer.committed(context, command, previous_state, state, observer_source())

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: System.monotonic_time() - started_at},
      telemetry_metadata(command, result, context)
    )

    returned_state =
      if legacy_external_batch?(command), do: external_input, else: external(state)

    {returned_state, result, []}
  end

  def state_enter(status, _state) do
    :telemetry.execute(
      [:concord, :state, :change],
      %{timestamp: System.system_time()},
      %{status: status, node: node()}
    )

    []
  end

  @doc """
  Runs a read using adapter-owned wall-clock metadata.
  """
  def query(query_term, state) do
    state =
      state
      |> restore!()
      |> maybe_import_legacy_data()
      |> merge_legacy_index_views()

    Core.query(query_term, state, %{timestamp_ms: System.system_time(:millisecond)})
  end

  def snapshot_installed(snapshot, _metadata, _old_state, _aux) do
    state = restore!(snapshot)
    materialize(state)

    :telemetry.execute(
      [:concord, :snapshot, :installed],
      %{timestamp: System.system_time(), size: map_size(state.store)},
      %{node: node()}
    )

    []
  end

  defp context(meta) do
    Context.new!(
      op_number: Map.get(meta, :index, 0),
      timestamp_ms: Map.get(meta, :system_time, 0)
    )
  end

  defp observer_source do
    :compatibility
  end

  defp restore!(state) do
    case Core.restore(state) do
      {:ok, state} -> state
      {:error, reason} -> raise ArgumentError, "invalid Concord state: #{inspect(reason)}"
    end
  end

  defp external(%State{} = state), do: {:concord_kv, Map.from_struct(state)}

  defp telemetry_metadata(command, result, context) do
    %{
      operation: operation_name(command),
      index: context.op_number,
      result: result
    }
    |> maybe_put_key(command)
    |> maybe_put_batch_size(command)
  end

  defp operation_name(command) when is_tuple(command), do: elem(command, 0)
  defp operation_name(command), do: command

  defp maybe_put_key(metadata, command)
       when is_tuple(command) and tuple_size(command) >= 2 and is_binary(elem(command, 1)),
       do: Map.put(metadata, :key, elem(command, 1))

  defp maybe_put_key(metadata, _command), do: metadata

  defp maybe_put_batch_size(metadata, command)
       when is_tuple(command) and tuple_size(command) >= 2 and is_list(elem(command, 1)),
       do: Map.put(metadata, :batch_size, length(elem(command, 1)))

  defp maybe_put_batch_size(metadata, _command), do: metadata

  defp legacy_external_batch?({operation, _items})
       when operation in [:put_many, :delete_many, :touch_many, :get_many],
       do: true

  defp legacy_external_batch?(_command), do: false

  # Legacy materialized views are never consulted by Core.apply/3. They
  # preserve existing observability and transitional APIs.
  @doc false
  def materialize(%State{} = state) do
    ensure_table(table(:store), [:ordered_set, :named_table])
    ensure_table(table(:current), [:ordered_set, :named_table])
    ensure_table(table(:history), [:ordered_set, :named_table])
    ensure_table(table(:leases), [:set, :named_table])
    ensure_table(table(:index_registry), [:set, :named_table])

    replace_table(table(:store), state.store)
    replace_table(table(:current), state.current)
    replace_table(table(:history), state.history)
    replace_table(table(:leases), state.leases)

    active_index_names =
      state.indexes
      |> Map.keys()
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    prune_index_tables(active_index_names)

    Enum.each(state.indexes, fn
      {name, _extractor} when is_binary(name) ->
        index_table = ensure_index_table(name)
        replace_table(index_table, Map.get(state.index_entries, name, %{}))

      {_legacy_name, _extractor} ->
        # Pre-versioning commands accepted arbitrary index names. Core remains
        # authoritative for those historical entries, but they cannot be
        # represented by the legacy named-ETS view. Skipping them keeps the
        # node available long enough to drop them through the migration gate.
        :ok
    end)

    :ok
  end

  defp merge_legacy_index_views(%State{} = state) do
    entries =
      Enum.reduce(state.indexes, state.index_entries, fn
        {name, _extractor}, acc when is_binary(name) ->
          index_table = StorageScope.index_table_name(name)
          values = table_entries(index_table, Map.get(acc, name, %{}))

          Map.put(acc, name, values)

        {_legacy_name, _extractor}, acc ->
          acc
      end)

    %{state | index_entries: entries}
  end

  defp maybe_import_legacy_data(%State{} = state) do
    if map_size(state.store) == 0 and map_size(state.current) == 0 do
      Core.from_legacy_tables(state, %{
        store: table_entries(table(:store), state.store),
        current: table_entries(table(:current), state.current),
        history: table_entries(table(:history), state.history),
        leases: table_entries(table(:leases), state.leases)
      })
    else
      state
    end
  end

  defp table_entries(name, fallback) do
    if :ets.info(name) == :undefined, do: fallback, else: Map.new(:ets.tab2list(name))
  rescue
    ArgumentError -> fallback
  end

  defp table(name), do: StorageScope.table(name)

  defp ensure_table(name, options) do
    access = Application.get_env(:concord, :ets_access_mode, :protected)

    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [access | options])
      _table -> :ok
    end
  end

  defp ensure_index_table(name) do
    registry = table(:index_registry)

    case StorageScope.index_table_name(name) do
      :undefined ->
        access = Application.get_env(:concord, :ets_access_mode, :protected)
        index_table = :ets.new(:concord_index_view, [access, :set])
        true = :ets.insert(registry, {name, index_table})
        index_table

      index_table ->
        true = :ets.insert(registry, {name, index_table})
        index_table
    end
  end

  defp prune_index_tables(active_index_names) do
    registry = table(:index_registry)

    Enum.each(:ets.tab2list(registry), fn {name, index_table} ->
      unless MapSet.member?(active_index_names, name) do
        delete_index_table(index_table)
        :ets.delete(registry, name)
      end
    end)
  end

  defp delete_index_table(index_table) do
    if :ets.info(index_table) != :undefined, do: :ets.delete(index_table)
  rescue
    ArgumentError -> :ok
  end

  defp replace_table(name, entries) do
    :ets.delete_all_objects(name)
    Enum.each(entries, fn entry -> :ets.insert(name, entry) end)
  end
end
