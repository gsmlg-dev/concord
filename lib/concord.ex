defmodule Concord do
  @moduledoc """
  Public API for the Concord distributed key-value store.

  Concord is a CP (Consistent + Partition-tolerant) distributed KV store
  built on the Raft consensus algorithm via the `ra` library.

  ## Examples

      iex> Concord.put("user:123", %{name: "Alice"}, token: "secret-token")
      :ok

      iex> Concord.get("user:123", token: "secret-token")
      {:ok, %{name: "Alice"}}

      iex> Concord.delete("user:123", token: "secret-token")
      :ok
  """

  require Logger

  alias Concord.{Auth, StateMachine, TTL}

  @timeout 5_000
  @cluster_name :concord_cluster

  @doc """
  Stores a key-value pair in the cluster.

  ## Options
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  - `:token` - Authentication token (required if auth is enabled)
  - `:ttl` - Time-to-live in seconds (default: nil for no expiration)
  """
  def put(key, value, opts \\ []) do
    with :ok <- check_auth(opts),
         :ok <- validate_key(key),
         :ok <- validate_ttl_option(opts) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      ttl_option = Keyword.get(opts, :ttl)
      expires_at = calculate_expires_at(ttl_option)
      start_time = System.monotonic_time()

      result =
        case command({:put, key, value, expires_at}, timeout) do
          {:ok, :ok, _} -> :ok
          {:ok, result, _} -> {:ok, result}
          {:timeout, _} -> {:error, :timeout}
          {:error, :noproc} -> {:error, :cluster_not_ready}
          {:error, reason} -> {:error, reason}
        end

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:concord, :api, :put],
        %{duration: duration},
        %{result: result, has_ttl: ttl_option != nil}
      )

      result
    end
  end

  @doc """
  Retrieves a value by key from the cluster.

  ## Options
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  - `:token` - Authentication token (required if auth is enabled)
  """
  def get(key, opts \\ []) do
    with :ok <- check_auth(opts),
         :ok <- validate_key(key) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      start_time = System.monotonic_time()

      result =
        case query({:get, key}, timeout) do
          {:ok, {{_index, _term}, query_result}, _} ->
            query_result

          {:timeout, _} ->
            {:error, :timeout}

          {:error, :noproc} ->
            {:error, :cluster_not_ready}

          {:error, reason} ->
            {:error, reason}
        end

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:concord, :api, :get],
        %{duration: duration},
        %{result: result}
      )

      result
    end
  end

  @doc """
  Deletes a key from the cluster.

  ## Options
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  - `:token` - Authentication token (required if auth is enabled)
  """
  def delete(key, opts \\ []) do
    with :ok <- check_auth(opts),
         :ok <- validate_key(key) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      start_time = System.monotonic_time()

      result =
        case command({:delete, key}, timeout) do
          {:ok, :ok, _} -> :ok
          {:ok, result, _} -> {:ok, result}
          {:timeout, _} -> {:error, :timeout}
          {:error, :noproc} -> {:error, :cluster_not_ready}
          {:error, reason} -> {:error, reason}
        end

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:concord, :api, :delete],
        %{duration: duration},
        %{result: result}
      )

      result
    end
  end

  @doc """
  Returns all key-value pairs in the store.
  Use sparingly on large datasets.

  ## Options
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  - `:token` - Authentication token (required if auth is enabled)
  """
  def get_all(opts \\ []) do
    with :ok <- check_auth(opts) do
      timeout = Keyword.get(opts, :timeout, @timeout)

      case query(:get_all, timeout) do
        {:ok, {{_index, _term}, query_result}, _} -> query_result
        {:timeout, _} -> {:error, :timeout}
        {:error, :noproc} -> {:error, :cluster_not_ready}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Returns cluster status information.
  """
  def status(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    server_id = server_id()

    with {:ok, overview, _} <- :ra.member_overview(server_id, timeout),
         {:ok, {{_index, _term}, query_result}, _} <- query(:stats, timeout) do
      {:ok,
       %{
         cluster: overview,
         storage: query_result,
         node: node()
       }}
    else
      {:error, reason} -> {:error, reason}
      {:timeout, _} -> {:error, :timeout}
    end
  end

  @doc """
  Returns cluster members information.
  """
  def members do
    server_id = server_id()

    case :ra.members(server_id) do
      {:ok, members, _leader} -> {:ok, members}
      {:error, reason} -> {:error, reason}
      {:timeout, _} -> {:error, :timeout}
    end
  end

  @doc """
  Stores a key-value pair with an explicit TTL in seconds.

  ## Options
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  - `:token` - Authentication token (required if auth is enabled)

  ## Examples
      iex> Concord.put_with_ttl("cache:user:123", %{data: "value"}, 3600, token: "token")
      :ok
  """
  def put_with_ttl(key, value, ttl_seconds, opts \\ []) when is_integer(ttl_seconds) and ttl_seconds > 0 do
    put(key, value, Keyword.put(opts, :ttl, ttl_seconds))
  end

  @doc """
  Extends the TTL of an existing key by the specified number of seconds.

  ## Options
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  - `:token` - Authentication token (required if auth is enabled)

  ## Examples
      iex> Concord.touch("cache:user:123", 1800, token: "token")
      :ok
  """
  def touch(key, additional_ttl_seconds, opts \\ []) when is_integer(additional_ttl_seconds) and additional_ttl_seconds > 0 do
    with :ok <- check_auth(opts),
         :ok <- validate_key(key) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      start_time = System.monotonic_time()

      result =
        case command({:touch, key, additional_ttl_seconds}, timeout) do
          {:ok, :ok, _} -> :ok
          {:ok, result, _} -> result
          {:timeout, _} -> {:error, :timeout}
          {:error, :noproc} -> {:error, :cluster_not_ready}
          {:error, reason} -> {:error, reason}
        end

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:concord, :api, :touch],
        %{duration: duration},
        %{result: result, key: key}
      )

      result
    end
  end

  @doc """
  Gets the remaining TTL for a key in seconds.

  Returns nil if the key has no expiration.
  Returns {:error, :not_found} if the key doesn't exist or has expired.

  ## Options
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  - `:token` - Authentication token (required if auth is enabled)

  ## Examples
      iex> Concord.ttl("cache:user:123", token: "token")
      {:ok, 1800}
  """
  def ttl(key, opts \\ []) do
    with :ok <- check_auth(opts),
         :ok <- validate_key(key) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      start_time = System.monotonic_time()

      result =
        case query({:ttl, key}, timeout) do
          {:ok, {{_index, _term}, query_result}, _} ->
            query_result

          {:timeout, _} ->
            {:error, :timeout}

          {:error, :noproc} ->
            {:error, :cluster_not_ready}

          {:error, reason} ->
            {:error, reason}
        end

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:concord, :api, :ttl],
        %{duration: duration},
        %{result: result, key: key}
      )

      result
    end
  end

  @doc """
  Gets a value along with its remaining TTL.

  ## Options
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  - `:token` - Authentication token (required if auth is enabled)

  ## Examples
      iex> Concord.get_with_ttl("cache:user:123", token: "token")
      {:ok, {%{data: "value"}, 1800}}
  """
  def get_with_ttl(key, opts \\ []) do
    with :ok <- check_auth(opts),
         :ok <- validate_key(key) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      start_time = System.monotonic_time()

      result =
        case query({:get_with_ttl, key}, timeout) do
          {:ok, {{_index, _term}, query_result}, _} ->
            query_result

          {:timeout, _} ->
            {:error, :timeout}

          {:error, :noproc} ->
            {:error, :cluster_not_ready}

          {:error, reason} ->
            {:error, reason}
        end

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:concord, :api, :get_with_ttl],
        %{duration: duration},
        %{result: result, key: key}
      )

      result
    end
  end

  @doc """
  Returns all key-value pairs with their TTL information.
  Use sparingly on large datasets.

  ## Options
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  - `:token` - Authentication token (required if auth is enabled)

  ## Examples
      iex> Concord.get_all_with_ttl(token: "token")
      {:ok, %{"key1" => %{value: "val1", ttl: 3600}, "key2" => %{value: "val2", ttl: nil}}}
  """
  def get_all_with_ttl(opts \\ []) do
    with :ok <- check_auth(opts) do
      timeout = Keyword.get(opts, :timeout, @timeout)

      case query(:get_all_with_ttl, timeout) do
        {:ok, {{_index, _term}, query_result}, _} -> query_result
        {:timeout, _} -> {:error, :timeout}
        {:error, :noproc} -> {:error, :cluster_not_ready}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Stores multiple key-value pairs in the cluster atomically.

  Either all operations succeed or all fail together.

  ## Options
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  - `:token` - Authentication token (required if auth is enabled)

  ## Examples
      iex> Concord.put_many([{"key1", "value1"}, {"key2", "value2"}], token: "token")
      {:ok, %{"key1" => :ok, "key2" => :ok}}
  """
  def put_many(operations, opts \\ []) when is_list(operations) do
    with :ok <- check_auth(opts),
         :ok <- validate_batch_size(operations),
         :ok <- validate_put_operations(operations) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      start_time = System.monotonic_time()

      # Convert operations to expected format for StateMachine
      formatted_operations = Enum.map(operations, fn
        {key, value} -> {key, value, nil}
        {key, value, ttl} when is_integer(ttl) -> {key, value, calculate_expires_at(ttl)}
        {key, value, expires_at} -> {key, value, expires_at}
      end)

      result =
        case command({:put_many, formatted_operations}, timeout) do
          {:ok, {:ok, results}, _} ->
            # Convert StateMachine results to map format
            success_map = Map.new(results, fn {key, :ok} -> {key, :ok} end)
            {:ok, success_map}

          {:ok, {:error, reason}, _} ->
            {:error, reason}

          {:timeout, _} ->
            {:error, :timeout}

          {:error, :noproc} ->
            {:error, :cluster_not_ready}

          {:error, reason} ->
            {:error, reason}
        end

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:concord, :api, :put_many],
        %{duration: duration},
        %{result: result, batch_size: length(operations)}
      )

      result
    end
  end

  @doc """
  Stores multiple key-value pairs with a TTL atomically.

  ## Options
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  - `:token` - Authentication token (required if auth is enabled)

  ## Examples
      iex> Concord.put_many_with_ttl([{"key1", "value1"}, {"key2", "value2"}], 3600, token: "token")
      {:ok, %{"key1" => :ok, "key2" => :ok}}
  """
  def put_many_with_ttl(operations, ttl_seconds, opts \\ []) when is_list(operations) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    # Add TTL to each operation
    operations_with_ttl = Enum.map(operations, fn {key, value} ->
      {key, value, ttl_seconds}
    end)

    put_many(operations_with_ttl, opts)
  end

  @doc """
  Retrieves multiple values by key from the cluster.

  ## Options
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  - `:token` - Authentication token (required if auth is enabled)

  ## Examples
      iex> Concord.get_many(["key1", "key2"], token: "token")
      {:ok, %{"key1" => {:ok, "value1"}, "key2" => {:error, :not_found}}}
  """
  def get_many(keys, opts \\ []) when is_list(keys) do
    with :ok <- check_auth(opts),
         :ok <- validate_batch_size(keys),
         :ok <- validate_keys(keys) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      start_time = System.monotonic_time()

      result =
        case query({:get_many, keys}, timeout) do
          {:ok, {{_index, _term}, query_result}, _} ->
            query_result

          {:timeout, _} ->
            {:error, :timeout}

          {:error, :noproc} ->
            {:error, :cluster_not_ready}

          {:error, reason} ->
            {:error, reason}
        end

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:concord, :api, :get_many],
        %{duration: duration},
        %{result: result, batch_size: length(keys)}
      )

      result
    end
  end

  @doc """
  Deletes multiple keys from the cluster atomically.

  Either all operations succeed or all fail together.

  ## Options
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  - `:token` - Authentication token (required if auth is enabled)

  ## Examples
      iex> Concord.delete_many(["key1", "key2"], token: "token")
      {:ok, %{"key1" => :ok, "key2" => :ok}}
  """
  def delete_many(keys, opts \\ []) when is_list(keys) do
    with :ok <- check_auth(opts),
         :ok <- validate_batch_size(keys),
         :ok <- validate_keys(keys) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      start_time = System.monotonic_time()

      result =
        case command({:delete_many, keys}, timeout) do
          {:ok, {:ok, results}, _} ->
            # Convert StateMachine results to map format
            success_map = Map.new(results, fn {key, :ok} -> {key, :ok} end)
            {:ok, success_map}

          {:ok, {:error, reason}, _} ->
            {:error, reason}

          {:timeout, _} ->
            {:error, :timeout}

          {:error, :noproc} ->
            {:error, :cluster_not_ready}

          {:error, reason} ->
            {:error, reason}
        end

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:concord, :api, :delete_many],
        %{duration: duration},
        %{result: result, batch_size: length(keys)}
      )

      result
    end
  end

  @doc """
  Extends the TTL of multiple keys atomically.

  Either all operations succeed or all fail together.

  ## Options
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  - `:token` - Authentication token (required if auth is enabled)

  ## Examples
      iex> Concord.touch_many([{"key1", 1800}, {"key2", 3600}], token: "token")
      {:ok, %{"key1" => :ok, "key2" => :ok}}
  """
  def touch_many(operations, opts \\ []) when is_list(operations) do
    with :ok <- check_auth(opts),
         :ok <- validate_batch_size(operations),
         :ok <- validate_touch_operations(operations) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      start_time = System.monotonic_time()

      result =
        case command({:touch_many, operations}, timeout) do
          {:ok, {:ok, results}, _} ->
            # Convert StateMachine results to map format
            result_map = Map.new(results)
            {:ok, result_map}

          {:ok, {:error, reason}, _} ->
            {:error, reason}

          {:timeout, _} ->
            {:error, :timeout}

          {:error, :noproc} ->
            {:error, :cluster_not_ready}

          {:error, reason} ->
            {:error, reason}
        end

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:concord, :api, :touch_many],
        %{duration: duration},
        %{result: result, batch_size: length(operations)}
      )

      result
    end
  end

  # Private helpers

  defp command(cmd, timeout) do
    :ra.process_command(server_id(), cmd, timeout)
  end

  defp query(query, timeout) do
    :ra.local_query(server_id(), fun(query), timeout)
  end

  defp fun(query) do
    fn state ->
      StateMachine.query(query, state)
    end
  end

  defp server_id do
    {@cluster_name, node()}
  end

  defp check_auth(opts) do
    if Application.get_env(:concord, :auth_enabled, false) do
      token = Keyword.get(opts, :token)
      Auth.verify_token(token)
    else
      :ok
    end
  end

  defp validate_key(key) when is_binary(key) and byte_size(key) > 0 and byte_size(key) <= 1024 do
    :ok
  end

  defp validate_key(_), do: {:error, :invalid_key}

  defp validate_ttl_option(opts) do
    case Keyword.get(opts, :ttl) do
      nil -> :ok
      ttl -> TTL.validate_ttl(ttl)
    end
  end

  defp calculate_expires_at(nil), do: nil
  defp calculate_expires_at(:infinity), do: nil
  defp calculate_expires_at(ttl_seconds) when is_integer(ttl_seconds) and ttl_seconds > 0 do
    TTL.calculate_expiration(ttl_seconds)
  end

  # Batch operation validation helpers

  defp validate_batch_size(items) when is_list(items) do
    max_batch_size = Application.get_env(:concord, :max_batch_size, 500)
    if length(items) > max_batch_size do
      {:error, :batch_too_large}
    else
      :ok
    end
  end

  defp validate_batch_size(_), do: {:error, :invalid_batch_format}

  defp validate_put_operations(operations) when is_list(operations) do
    case Enum.find_value(operations, :ok, fn operation ->
      validate_put_operation(operation)
    end) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_put_operation({key, _value}) when is_binary(key) and byte_size(key) > 0 do
    validate_key(key)
  end

  defp validate_put_operation({key, _value, ttl}) when is_binary(key) and byte_size(key) > 0 do
    with :ok <- validate_key(key),
         :ok <- TTL.validate_ttl(ttl) do
      :ok
    end
  end

  defp validate_put_operation({key, _value, expires_at}) when is_binary(key) and byte_size(key) > 0 do
    if expires_at == nil or is_integer(expires_at) do
      validate_key(key)
    else
      {:error, :invalid_expires_at}
    end
  end

  defp validate_put_operation(_), do: {:error, :invalid_operation_format}

  defp validate_keys(keys) when is_list(keys) do
    case Enum.find_value(keys, :ok, fn key ->
      validate_key(key)
    end) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_keys(_), do: {:error, :invalid_keys_format}

  defp validate_touch_operations(operations) when is_list(operations) do
    case Enum.find_value(operations, :ok, fn operation ->
      validate_touch_operation(operation)
    end) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_touch_operation({key, ttl_seconds}) when is_binary(key) and byte_size(key) > 0 and is_integer(ttl_seconds) and ttl_seconds > 0 do
    :ok
  end

  defp validate_touch_operation(_), do: {:error, :invalid_touch_operation}
end
