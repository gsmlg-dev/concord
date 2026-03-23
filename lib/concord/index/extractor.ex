defmodule Concord.Index.Extractor do
  @moduledoc """
  Declarative index extractor specifications.

  All specs are plain data (tuples of atoms/binaries/integers) — no anonymous
  functions. This makes them safe to serialize in the Raft log and snapshots
  across code versions without risk of `:badfun` errors.

  ## Supported Specs

    * `{:map_get, key}` — Extract a single map key
    * `{:nested, [key1, key2, ...]}` — Extract a nested value via `get_in/2`
    * `{:identity}` — Index the entire value as-is
    * `{:element, n}` — Extract the nth element from a tuple

  ## Examples

      # Index on user email field
      {:map_get, :email}

      # Index on nested field
      {:nested, [:address, :city]}

      # Index on the raw value
      {:identity}
  """

  @type spec ::
          {:map_get, atom() | binary()}
          | {:nested, [atom() | binary()]}
          | {:identity}
          | {:element, non_neg_integer()}

  @doc """
  Validates that a given term is a supported extractor spec.
  """
  @spec valid?(term()) :: boolean()
  def valid?({:map_get, key}) when is_atom(key) or is_binary(key), do: true
  def valid?({:nested, [_ | _]}), do: true
  def valid?({:identity}), do: true
  def valid?({:element, n}) when is_integer(n) and n >= 0, do: true
  # Backward compatibility: accept anonymous functions during migration
  def valid?(f) when is_function(f, 1), do: true
  def valid?(_), do: false

  @doc """
  Extracts an index value from a stored value using the given spec.

  Returns `nil` if extraction fails or the field doesn't exist.
  """
  @spec extract(spec(), term()) :: term() | nil
  def extract({:map_get, key}, value) when is_map(value), do: Map.get(value, key)
  def extract({:nested, keys}, value) when is_map(value), do: get_in(value, keys)
  def extract({:identity}, value), do: value

  def extract({:element, n}, value) when is_tuple(value) and tuple_size(value) > n,
    do: elem(value, n)

  # Backward compatibility: evaluate anonymous functions during migration
  def extract(extractor, value) when is_function(extractor, 1) do
    extractor.(value)
  rescue
    _ -> nil
  end

  def extract(_, _), do: nil

  @doc """
  Indexes a value in the given ETS table using the extractor spec.
  Handles single values and lists of values.
  """
  @spec index_value(atom(), binary(), term(), spec()) :: :ok
  def index_value(table, key, value, spec) do
    case extract(spec, value) do
      nil ->
        :ok

      index_values when is_list(index_values) ->
        Enum.each(index_values, fn idx_val ->
          add_to_index(table, idx_val, key)
        end)

      index_val ->
        add_to_index(table, index_val, key)
    end
  rescue
    _ -> :ok
  end

  @doc """
  Removes a value from the index ETS table using the extractor spec.
  """
  @spec remove_from_index(atom(), binary(), term(), spec()) :: :ok
  def remove_from_index(table, key, old_value, spec) do
    case extract(spec, old_value) do
      nil ->
        :ok

      index_values when is_list(index_values) ->
        Enum.each(index_values, fn idx_val ->
          remove_key_from_index(table, idx_val, key)
        end)

      index_val ->
        remove_key_from_index(table, index_val, key)
    end
  rescue
    _ -> :ok
  end

  defp add_to_index(table, index_value, key) do
    if :ets.whereis(table) != :undefined do
      case :ets.lookup(table, index_value) do
        [{^index_value, keys}] ->
          unless key in keys do
            :ets.insert(table, {index_value, [key | keys]})
          end

        [] ->
          :ets.insert(table, {index_value, [key]})
      end
    end
  end

  defp remove_key_from_index(table, index_value, key) do
    if :ets.whereis(table) != :undefined do
      case :ets.lookup(table, index_value) do
        [{^index_value, keys}] ->
          new_keys = List.delete(keys, key)

          if new_keys == [] do
            :ets.delete(table, index_value)
          else
            :ets.insert(table, {index_value, new_keys})
          end

        [] ->
          :ok
      end
    end
  end
end
