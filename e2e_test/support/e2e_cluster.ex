# E2E Cluster helpers for RPC-based testing against a running release cluster.
defmodule Concord.E2E.Cluster do
  @moduledoc """
  Helpers for interacting with a running Concord release cluster via RPC.

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

  @doc "Finds the current Raft leader node."
  def find_leader(node_list \\ @default_nodes) do
    Enum.find(node_list, fn node ->
      case :rpc.call(node, :ra, :members, [{:concord_cluster, node}]) do
        {:ok, _members, {_, leader_node}} -> leader_node == node
        _ -> false
      end
    end)
  end

  @doc "Waits until a Raft leader is available, up to timeout_ms."
  def wait_for_leader(timeout_ms \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_leader(deadline)
  end

  defp do_wait_leader(deadline) do
    case find_leader() do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(500)
          do_wait_leader(deadline)
        else
          {:error, :timeout}
        end

      leader ->
        {:ok, leader}
    end
  end

  @doc "Runs a Concord function on the leader node via RPC."
  def rpc_leader(mod, fun, args) do
    case find_leader() do
      nil -> {:error, :no_leader}
      leader -> :rpc.call(leader, mod, fun, args)
    end
  end

  @doc "Runs a function on all cluster nodes and returns results."
  def rpc_all(mod, fun, args, node_list \\ @default_nodes) do
    Enum.map(node_list, fn node ->
      {node, :rpc.call(node, mod, fun, args)}
    end)
  end

  @doc "Runs a Ra leader_query on a node using MFA format."
  def ra_query(node, query_term) do
    mfa = {Concord.StateMachine, :query, [query_term]}

    case :rpc.call(node, :ra, :leader_query, [{:concord_cluster, node}, mfa]) do
      {:ok, {{_, _}, result}, _} -> result
      {:ok, result, _} -> result
      error -> error
    end
  end

  @doc "Sends a Ra process_command on the leader."
  def ra_command(cmd) do
    case find_leader() do
      nil ->
        {:error, :no_leader}

      leader ->
        case :rpc.call(leader, :ra, :process_command, [{:concord_cluster, leader}, cmd]) do
          {:ok, result, _} -> {:ok, result}
          error -> error
        end
    end
  end

  @doc "Wait for a value to be replicated to all nodes."
  def wait_replicated(key, expected, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_replicated(key, expected, deadline)
  end

  defp do_wait_replicated(key, expected, deadline) do
    results = rpc_all(Concord, :get, [key])
    all_match = Enum.all?(results, fn {_node, val} -> val == expected end)

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
