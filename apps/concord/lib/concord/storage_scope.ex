defmodule Concord.StorageScope do
  @moduledoc false

  @scope_key {__MODULE__, :scope}

  @tables %{
    cluster: %{
      store: :concord_store,
      current: :concord_current,
      history: :concord_history,
      leases: :concord_leases,
      index_registry: :concord_index_registry,
      index_prefix: "concord_index_"
    },
    local: %{
      store: :concord_local_store,
      current: :concord_local_current,
      history: :concord_local_history,
      leases: :concord_local_leases,
      index_registry: :concord_local_index_registry,
      index_prefix: "concord_local_index_"
    }
  }

  def with_scope(scope, fun) when is_function(fun, 0) do
    previous = Process.get(@scope_key)
    Process.put(@scope_key, scope)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  def table(name), do: current_scope() |> Map.fetch!(name)

  def index_table_name(index_name) do
    case registered_index_table(index_name) do
      :undefined -> legacy_index_table_name(index_name)
      table -> table
    end
  end

  defp registered_index_table(index_name) do
    registry = table(:index_registry)

    case :ets.info(registry) do
      :undefined ->
        :undefined

      _info ->
        case :ets.lookup(registry, index_name) do
          [{^index_name, index_table}] ->
            if :ets.info(index_table) == :undefined, do: :undefined, else: index_table

          [] ->
            :undefined
        end
    end
  rescue
    ArgumentError -> :undefined
  end

  # Upgrade compatibility only: use an old named table if its atom already
  # exists, but never intern a replicated index name as a new VM atom.
  defp legacy_index_table_name(index_name) when is_binary(index_name) do
    prefix = current_scope() |> Map.fetch!(:index_prefix)
    table = String.to_existing_atom(prefix <> index_name)

    if :ets.info(table) == :undefined, do: :undefined, else: table
  rescue
    ArgumentError -> :undefined
  end

  defp legacy_index_table_name(_index_name), do: :undefined

  defp current_scope do
    Map.get(@tables, Process.get(@scope_key, :cluster), @tables.cluster)
  end

  defp restore(nil), do: Process.delete(@scope_key)
  defp restore(scope), do: Process.put(@scope_key, scope)
end
