defmodule Concord.Index do
  @moduledoc """
  Secondary index support for efficient value-based queries.

  Secondary indexes enable fast lookups by specific value fields without
  scanning all keys. Each index maintains a mapping from indexed values
  to the keys that contain those values.

  ## Features

  - **Automatic Maintenance**: Indexes update automatically on put/delete
  - **Multiple Indexes**: Support for multiple indexes per store
  - **Declarative Extractors**: Define indexes with data specs (safe for Raft replication)
  - **Backward Compatible**: Anonymous functions still accepted during migration
  - **Efficient Lookups**: O(1) lookup by indexed value
  - **Multi-value Support**: Index multiple values per key (e.g., tags)

  ## Declarative Extractor Specs (Recommended)

      # Index on a map key
      :ok = Concord.Index.create("users_by_email", {:map_get, :email})

      # Index on a nested path
      :ok = Concord.Index.create("by_city", {:nested, [:address, :city]})

      # Index on the raw value
      :ok = Concord.Index.create("by_value", {:identity})

  ## Legacy Function Extractors (Deprecated)

      # Still works but stores anonymous functions in Raft log — unsafe across upgrades
      :ok = Concord.Index.create("by_email", fn u -> u.email end)
  """

  alias Concord.Index.Extractor
  alias Concord.StateMachine

  @timeout 5_000
  @cluster_name :concord_cluster

  @typedoc "Index name (unique identifier)"
  @type index_name :: String.t()

  @typedoc "Extractor: declarative spec or legacy function"
  @type extractor :: Extractor.spec() | (term() -> term())

  @typedoc "Value to index (must be comparable)"
  @type index_value :: term()

  @doc """
  Creates a new secondary index.

  Accepts either a declarative extractor spec (recommended) or a legacy
  anonymous function (deprecated — unsafe across code upgrades).

  ## Declarative Specs (Recommended)

      :ok = Concord.Index.create("by_email", {:map_get, :email})
      :ok = Concord.Index.create("by_city", {:nested, [:address, :city]})
      :ok = Concord.Index.create("by_value", {:identity})
      :ok = Concord.Index.create("by_first", {:element, 0})

  ## Options

  - `:reindex` - If true, reindex all existing keys (default: false)
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  """
  @spec create(index_name(), extractor(), keyword()) :: :ok | {:error, term()}
  def create(name, extractor, opts \\ []) do
    with :ok <- validate_index_name(name),
         :ok <- validate_extractor(extractor) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      reindex = Keyword.get(opts, :reindex, false)

      command = {:create_index, name, extractor}
      server_id = {@cluster_name, node()}

      case :ra.process_command(server_id, command, timeout) do
        {:ok, :ok, _} ->
          if reindex do
            reindex(name, timeout: timeout)
          end

          :ok

        {:ok, {:error, reason}, _} ->
          {:error, reason}

        {:timeout, _} ->
          {:error, :timeout}

        {:error, :noproc} ->
          {:error, :cluster_not_ready}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Drops an existing secondary index.
  """
  @spec drop(index_name(), keyword()) :: :ok | {:error, term()}
  def drop(name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    command = {:drop_index, name}
    server_id = {@cluster_name, node()}

    case :ra.process_command(server_id, command, timeout) do
      {:ok, :ok, _} -> :ok
      {:ok, {:error, reason}, _} -> {:error, reason}
      {:timeout, _} -> {:error, :timeout}
      {:error, :noproc} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Looks up keys by indexed value.
  """
  @spec lookup(index_name(), index_value(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def lookup(name, value, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    server_id = {@cluster_name, node()}
    query_fun = fn state -> StateMachine.query({:index_lookup, name, value}, state) end

    case :ra.consistent_query(server_id, query_fun, timeout) do
      {:ok, {:ok, keys}, _} when is_list(keys) -> {:ok, keys}
      {:ok, {:ok, {:error, reason}}, _} -> {:error, reason}
      {:timeout, _} -> {:error, :timeout}
      {:error, :noproc} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists all secondary indexes.
  """
  @spec list(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    server_id = {@cluster_name, node()}
    query_fun = fn state -> StateMachine.query(:list_indexes, state) end

    case :ra.consistent_query(server_id, query_fun, timeout) do
      {:ok, {:ok, indexes}, _} when is_list(indexes) -> {:ok, indexes}
      {:timeout, _} -> {:error, :timeout}
      {:error, :noproc} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Rebuilds an index from all existing keys.
  Uses the declarative extractor spec stored in the state machine.
  """
  @spec reindex(index_name(), keyword()) :: :ok | {:error, term()}
  def reindex(name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    server_id = {@cluster_name, node()}

    with {:ok, pairs} <- Concord.get_all(),
         {:ok, indexes} <- list(timeout: timeout) do
      if name in indexes do
        query_fun = fn state ->
          StateMachine.query({:get_index_extractor, name}, state)
        end

        case :ra.consistent_query(server_id, query_fun, timeout) do
          {:ok, {:ok, extractor}, _} ->
            table_name = index_table_name(name)

            if :ets.whereis(table_name) != :undefined do
              :ets.delete_all_objects(table_name)
            end

            Enum.each(pairs, fn {key, value} ->
              Extractor.index_value(table_name, key, value, extractor)
            end)

            :ok

          _ ->
            {:error, :not_found}
        end
      else
        {:error, :not_found}
      end
    end
  end

  ## Helper Functions

  @doc false
  def index_table_name(index_name) do
    String.to_atom("concord_index_#{index_name}")
  end

  # Delegate to Extractor module for index operations
  @doc false
  def index_value(table_name, key, value, extractor) do
    Extractor.index_value(table_name, key, value, extractor)
  end

  @doc false
  def remove_from_index(table_name, key, value, extractor) do
    Extractor.remove_from_index(table_name, key, value, extractor)
  end

  defp validate_index_name(name) when is_binary(name) and byte_size(name) > 0, do: :ok
  defp validate_index_name(_), do: {:error, :invalid_name}

  defp validate_extractor(extractor) when is_function(extractor, 1), do: :ok

  defp validate_extractor(extractor) do
    if Extractor.valid?(extractor), do: :ok, else: {:error, :invalid_extractor}
  end
end
