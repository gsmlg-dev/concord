defmodule Concord.Index do
  @moduledoc """
  Secondary index support for efficient value-based queries.

  Secondary indexes enable fast lookups by specific value fields without
  scanning all keys. Each index maintains a mapping from indexed values
  to the keys that contain those values.

  ## Features

  - **Automatic Maintenance**: Indexes update automatically on put/delete
  - **Multiple Indexes**: Support for multiple indexes per store
  - **Declarative Extractors**: Define indexes with data specs (safe for replication)
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

      # Still works but stores anonymous functions in the replicated log — unsafe across upgrades
      :ok = Concord.Index.create("by_email", fn u -> u.email end)
  """

  alias Concord.{Engine, StorageScope}
  alias Concord.Index.Extractor

  @timeout 5_000

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

      engine_opts = Keyword.take(opts, [:engine])

      case Engine.command(command, Keyword.put(engine_opts, :timeout, timeout)) do
        {:ok, :ok} ->
          if reindex do
            reindex(name, Keyword.merge(engine_opts, timeout: timeout))
          end

          :ok

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:error, :timeout} ->
          {:error, :timeout}

        {:error, :cluster_not_ready} ->
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

    engine_opts = Keyword.take(opts, [:engine])

    case Engine.command(command, Keyword.put(engine_opts, :timeout, timeout)) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :timeout} -> {:error, :timeout}
      {:error, :cluster_not_ready} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Looks up keys by indexed value.
  """
  @spec lookup(index_name(), index_value(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def lookup(name, value, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    engine_opts = Keyword.take(opts, [:engine])

    case Engine.query(
           {:index_lookup, name, value},
           Keyword.merge(engine_opts, timeout: timeout, consistency: :strong)
         ) do
      {:ok, {:ok, keys}} when is_list(keys) -> {:ok, keys}
      {:ok, {:ok, {:error, reason}}} -> {:error, reason}
      {:error, :timeout} -> {:error, :timeout}
      {:error, :cluster_not_ready} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists all secondary indexes.
  """
  @spec list(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    engine_opts = Keyword.take(opts, [:engine])

    case Engine.query(
           :list_indexes,
           Keyword.merge(engine_opts, timeout: timeout, consistency: :strong)
         ) do
      {:ok, {:ok, indexes}} when is_list(indexes) -> {:ok, indexes}
      {:error, :timeout} -> {:error, :timeout}
      {:error, :cluster_not_ready} -> {:error, :cluster_not_ready}
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
    engine_opts = Keyword.take(opts, [:engine])

    case Engine.command({:reindex, name}, Keyword.put(engine_opts, :timeout, timeout)) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :timeout} -> {:error, :timeout}
      {:error, :cluster_not_ready} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Helper Functions

  @doc false
  def index_table_name(index_name) do
    StorageScope.index_table_name(index_name)
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
