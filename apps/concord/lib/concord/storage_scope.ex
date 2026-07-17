defmodule Concord.StorageScope do
  @moduledoc false

  @scope_key {__MODULE__, :scope}

  @tables %{
    cluster: %{
      store: :concord_store,
      current: :concord_current,
      history: :concord_history,
      leases: :concord_leases,
      index_prefix: "concord_index_"
    },
    local: %{
      store: :concord_local_store,
      current: :concord_local_current,
      history: :concord_local_history,
      leases: :concord_local_leases,
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
    prefix = current_scope() |> Map.fetch!(:index_prefix)
    String.to_atom(prefix <> index_name)
  end

  defp current_scope do
    Map.get(@tables, Process.get(@scope_key, :cluster), @tables.cluster)
  end

  defp restore(nil), do: Process.delete(@scope_key)
  defp restore(scope), do: Process.put(@scope_key, scope)
end
