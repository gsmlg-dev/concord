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

  @timeout 5_000
  @cluster_name :concord_cluster

  @doc """
  Stores a key-value pair in the cluster.

  ## Options
  - `:timeout` - Operation timeout in milliseconds (default: 5000)
  - `:token` - Authentication token (required if auth is enabled)
  """
  def put(key, value, opts \\ []) do
    with :ok <- check_auth(opts),
         :ok <- validate_key(key) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      start_time = System.monotonic_time()

      result =
        case command({:put, key, value}, timeout) do
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
        %{result: result}
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

  # Private helpers

  defp command(cmd, timeout) do
    :ra.process_command(server_id(), cmd, timeout)
  end

  defp query(query, timeout) do
    :ra.local_query(server_id(), fun(query), timeout)
  end

  defp fun(query) do
    fn state ->
      Concord.StateMachine.query(query, state)
    end
  end

  defp server_id do
    {@cluster_name, node()}
  end

  defp check_auth(opts) do
    if Application.get_env(:concord, :auth_enabled, false) do
      token = Keyword.get(opts, :token)
      Concord.Auth.verify_token(token)
    else
      :ok
    end
  end

  defp validate_key(key) when is_binary(key) and byte_size(key) > 0 and byte_size(key) <= 1024 do
    :ok
  end

  defp validate_key(_), do: {:error, :invalid_key}
end
