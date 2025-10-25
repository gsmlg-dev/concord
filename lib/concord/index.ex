defmodule Concord.Index do
  @moduledoc """
  Secondary index support for efficient value-based queries.

  Secondary indexes enable fast lookups by specific value fields without
  scanning all keys. Each index maintains a mapping from indexed values
  to the keys that contain those values.

  ## Features

  - **Automatic Maintenance**: Indexes update automatically on put/delete
  - **Multiple Indexes**: Support for multiple indexes per store
  - **Custom Extractors**: Flexible field extraction via functions
  - **Efficient Lookups**: O(1) lookup by indexed value
  - **Multi-value Support**: Index multiple values per key (e.g., tags)

  ## Usage

      # Create an index on user emails
      :ok = Concord.Index.create("users_by_email", fn user -> user.email end)

      # Store some users
      :ok = Concord.put("user:1", %{name: "Alice", email: "alice@example.com"})
      :ok = Concord.put("user:2", %{name: "Bob", email: "bob@example.com"})

      # Look up by email
      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      # => {:ok, ["user:1"]}

      # Get the actual values
      {:ok, users} = Concord.get_many(keys)

  ## Index Extractors

  The extractor function receives the decompressed value and should return:
  - A single indexable term (string, number, atom)
  - A list of indexable terms (for multi-value indexes)
  - `nil` to skip indexing this value

      # Single value index
      Concord.Index.create("by_status", fn order -> order.status end)

      # Multi-value index (tags)
      Concord.Index.create("by_tag", fn post -> post.tags end)

      # Conditional indexing
      Concord.Index.create("active_users", fn user ->
        if user.active, do: user.id, else: nil
      end)

  ## Limitations

  - Indexes are stored in-memory only (ETS tables)
  - Index definitions must be recreated after cluster restart
  - Extractor functions are stored as terms (use simple functions)
  - Reindexing existing data requires calling `reindex/1`
  """

  @timeout 5_000
  @cluster_name :concord_cluster

  @typedoc "Index name (unique identifier)"
  @type index_name :: String.t()

  @typedoc "Function that extracts index value(s) from a stored value"
  @type extractor :: (term() -> index_value() | [index_value()] | nil)

  @typedoc "Value to index (must be comparable)"
  @type index_value :: term()

  @doc """
  Creates a new secondary index.

  The extractor function is called for each value to determine what to index.
  By default, existing keys are NOT automatically indexed - use the `:reindex`
  option to index existing data.

  ## Options

  - `:reindex` - If true, reindex all existing keys (default: false)
  - `:timeout` - Operation timeout in milliseconds (default: 5000)

  ## Examples

      # Simple field extraction
      :ok = Concord.Index.create("users_by_email", fn u -> u.email end)

      # Multi-value index
      :ok = Concord.Index.create("posts_by_tag", fn p -> p.tags end)

      # Reindex existing data
      :ok = Concord.Index.create("by_category", fn p -> p.category end, reindex: true)

  ## Returns

  - `:ok` - Index created successfully
  - `{:error, :index_exists}` - Index with this name already exists
  - `{:error, :invalid_name}` - Index name is invalid
  - `{:error, :invalid_extractor}` - Extractor is not a function
  - `{:error, :timeout}` - Operation timed out
  - `{:error, :cluster_not_ready}` - Cluster not initialized
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

  This removes the index definition and frees the associated ETS table.

  ## Examples

      :ok = Concord.Index.drop("users_by_email")

  ## Returns

  - `:ok` - Index dropped successfully
  - `{:error, :not_found}` - Index does not exist
  - `{:error, :timeout}` - Operation timed out
  - `{:error, :cluster_not_ready}` - Cluster not initialized
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

  Returns all keys whose indexed value matches the given lookup value.

  ## Examples

      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      # => {:ok, ["user:1", "user:42"]}

      # Get the actual values
      {:ok, users} = Concord.get_many(keys)

  ## Returns

  - `{:ok, keys}` - List of keys with matching index value (may be empty)
  - `{:error, :not_found}` - Index does not exist
  - `{:error, :cluster_not_ready}` - Cluster not initialized
  """
  @spec lookup(index_name(), index_value(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def lookup(name, value, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    server_id = {@cluster_name, node()}
    query_fun = fn state -> Concord.StateMachine.query({:index_lookup, name, value}, state) end

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

  Returns a list of index names.

  ## Examples

      {:ok, indexes} = Concord.Index.list()
      # => {:ok, ["users_by_email", "posts_by_tag"]}

  ## Returns

  - `{:ok, index_names}` - List of index names
  - `{:error, :cluster_not_ready}` - Cluster not initialized
  """
  @spec list(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    server_id = {@cluster_name, node()}
    query_fun = fn state -> Concord.StateMachine.query(:list_indexes, state) end

    case :ra.consistent_query(server_id, query_fun, timeout) do
      {:ok, {:ok, indexes}, _} when is_list(indexes) -> {:ok, indexes}
      {:timeout, _} -> {:error, :timeout}
      {:error, :noproc} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Rebuilds an index from all existing keys.

  This scans all keys in the store and reindexes them. Useful when:
  - The index was created without the `:reindex` option
  - You want to rebuild the index after data changes

  ## Examples

      :ok = Concord.Index.reindex("users_by_email")

  ## Returns

  - `:ok` - Reindexing completed
  - `{:error, :not_found}` - Index does not exist
  - `{:error, :timeout}` - Operation timed out
  - `{:error, :cluster_not_ready}` - Cluster not initialized
  """
  @spec reindex(index_name(), keyword()) :: :ok | {:error, term()}
  def reindex(name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    server_id = {@cluster_name, node()}

    # Get all keys and reindex them
    with {:ok, pairs} <- Concord.get_all(),
         {:ok, indexes} <- list(timeout: timeout) do
      if name in indexes do
        # Get the extractor for this index
        query_fun = fn state ->
          Concord.StateMachine.query({:get_index_extractor, name}, state)
        end

        case :ra.consistent_query(server_id, query_fun, timeout) do
          {:ok, {:ok, extractor}, _} when is_function(extractor) ->
            # Clear the index
            table_name = index_table_name(name)

            if :ets.whereis(table_name) != :undefined do
              :ets.delete_all_objects(table_name)
            end

            # Reindex all pairs
            Enum.each(pairs, fn {key, value} ->
              index_value(table_name, key, value, extractor)
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

  @doc false
  def index_value(table_name, key, value, extractor) do
    try do
      case extractor.(value) do
        nil ->
          :ok

        index_values when is_list(index_values) ->
          Enum.each(index_values, fn idx_val ->
            add_to_index(table_name, idx_val, key)
          end)

        index_value ->
          add_to_index(table_name, index_value, key)
      end
    rescue
      # Silently ignore extractor errors
      _ -> :ok
    end
  end

  @doc false
  def remove_from_index(table_name, key, value, extractor) do
    try do
      case extractor.(value) do
        nil ->
          :ok

        index_values when is_list(index_values) ->
          Enum.each(index_values, fn idx_val ->
            remove_key_from_index(table_name, idx_val, key)
          end)

        index_value ->
          remove_key_from_index(table_name, index_value, key)
      end
    rescue
      # Silently ignore extractor errors
      _ -> :ok
    end
  end

  defp add_to_index(table_name, index_value, key) do
    if :ets.whereis(table_name) != :undefined do
      case :ets.lookup(table_name, index_value) do
        [{^index_value, keys}] ->
          if key not in keys do
            :ets.insert(table_name, {index_value, [key | keys]})
          end

        [] ->
          :ets.insert(table_name, {index_value, [key]})
      end
    end
  end

  defp remove_key_from_index(table_name, index_value, key) do
    if :ets.whereis(table_name) != :undefined do
      case :ets.lookup(table_name, index_value) do
        [{^index_value, keys}] ->
          new_keys = List.delete(keys, key)

          if new_keys == [] do
            :ets.delete(table_name, index_value)
          else
            :ets.insert(table_name, {index_value, new_keys})
          end

        [] ->
          :ok
      end
    end
  end

  defp validate_index_name(name) when is_binary(name) and byte_size(name) > 0, do: :ok
  defp validate_index_name(_), do: {:error, :invalid_name}

  defp validate_extractor(extractor) when is_function(extractor, 1), do: :ok
  defp validate_extractor(_), do: {:error, :invalid_extractor}
end
