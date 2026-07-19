# E2E Cluster helpers for RPC-based testing against a running release cluster.
defmodule Concord.E2E.Cluster do
  @moduledoc """
  Helpers for interacting with a running Concord VSR release cluster via RPC.

  The cluster nodes are expected to be named concord_e2eN@127.0.0.1
  and already running when tests execute.
  """

  @default_nodes [
    :"concord_e2e1@127.0.0.1",
    :"concord_e2e2@127.0.0.1",
    :"concord_e2e3@127.0.0.1"
  ]

  @doc "Returns the list of cluster node names."
  def nodes, do: @default_nodes

  @doc "Returns connected cluster nodes."
  def connected_nodes do
    Enum.filter(@default_nodes, &Node.connect/1)
  end

  @doc "Finds the node running the current VSR primary replica."
  def find_primary(node_list \\ @default_nodes) do
    Enum.find(node_list, fn node ->
      case :rpc.call(node, Concord, :status, []) do
        {:ok, %{cluster: %{replica_id: replica_id, primary_id: replica_id}}} -> true
        _result -> false
      end
    end)
  end

  @doc "Waits until a VSR primary is available, up to timeout_ms."
  def wait_for_primary(timeout_ms \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_primary(deadline)
  end

  defp do_wait_primary(deadline) do
    case find_primary() do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(500)
          do_wait_primary(deadline)
        else
          {:error, :timeout}
        end

      primary ->
        {:ok, primary}
    end
  end

  @doc "Runs a Concord function on the primary node via RPC."
  def rpc_primary(mod, fun, args) do
    case find_primary() do
      nil -> {:error, :no_primary}
      primary -> :rpc.call(primary, mod, fun, args)
    end
  end

  @doc "Runs a function on all cluster nodes and returns results."
  def rpc_all(mod, fun, args, node_list \\ @default_nodes) do
    Enum.map(node_list, fn node ->
      {node, :rpc.call(node, mod, fun, args)}
    end)
  end

  @doc "Runs a replicated query through the VSR engine on a node."
  def replicated_query(node, query_term) do
    case :rpc.call(node, Concord.Engine, :query, [query_term]) do
      {:ok, result} -> result
      error -> error
    end
  end

  @doc "Submits a command through the VSR engine."
  def replicated_command(command) do
    case find_primary() do
      nil -> {:error, :no_primary}
      primary -> :rpc.call(primary, Concord.Engine, :command, [command])
    end
  end

  @doc "Wait for a value to be replicated to all nodes."
  def wait_replicated(key, expected, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_replicated(key, expected, deadline)
  end

  defp do_wait_replicated(key, expected, deadline) do
    results = rpc_all(Concord, :get, [key])
    all_match = Enum.all?(results, fn {_node, value} -> value == expected end)

    if all_match do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(200)
        do_wait_replicated(key, expected, deadline)
      else
        {:error, :replication_timeout, results}
      end
    end
  end
end
