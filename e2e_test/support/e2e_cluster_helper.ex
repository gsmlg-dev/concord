defmodule Concord.E2E.ClusterHelper do
  @moduledoc """
  Helper module for managing multi-node Concord clusters in e2e tests.

  Uses LocalCluster to spawn actual Erlang nodes with full network isolation.
  """

  @doc """
  Starts a multi-node Concord cluster using LocalCluster.

  ## Options

    * `:nodes` - Number of nodes to start (default: 3)
    * `:prefix` - Node name prefix (default: "concord_e2e")
    * `:wait_timeout` - Time to wait for cluster ready in ms (default: 30_000)

  ## Returns

    * `{:ok, nodes}` - List of started node names
    * `{:error, reason}` - If cluster failed to start

  ## Examples

      iex> {:ok, nodes} = E2E.ClusterHelper.start_cluster(nodes: 3)
      iex> length(nodes)
      3
  """
  def start_cluster(opts \\ []) do
    node_count = Keyword.get(opts, :nodes, 3)
    prefix = Keyword.get(opts, :prefix, "concord_e2e")
    wait_timeout = Keyword.get(opts, :wait_timeout, 30_000)

    IO.puts("Starting #{node_count}-node cluster with prefix '#{prefix}'...")

    # Start nodes with LocalCluster
    nodes =
      LocalCluster.start_nodes(prefix, node_count,
        files: [__ENV__.file],
        applications: [:ra, :telemetry, :concord]
      )

    IO.puts("Started nodes: #{inspect(nodes)}")

    # Initialize Concord on each node
    Enum.each(nodes, fn node ->
      IO.puts("Initializing Concord on #{node}...")
      :rpc.call(node, Application, :ensure_all_started, [:concord])
    end)

    # Wait for cluster formation
    case wait_for_cluster_ready(nodes, wait_timeout) do
      :ok ->
        IO.puts("✓ Cluster ready with #{length(nodes)} nodes")
        {:ok, nodes}

      {:error, reason} ->
        IO.puts("✗ Cluster failed to start: #{inspect(reason)}")
        stop_cluster(nodes)
        {:error, reason}
    end
  end

  @doc """
  Stops a running cluster and cleans up resources.
  """
  def stop_cluster(nodes) when is_list(nodes) do
    IO.puts("Stopping cluster nodes: #{inspect(nodes)}")

    # Stop Concord application on each node first
    Enum.each(nodes, fn node ->
      :rpc.call(node, Application, :stop, [:concord])
    end)

    # Give time for graceful shutdown
    Process.sleep(500)

    # Stop the nodes
    LocalCluster.stop_nodes(nodes)

    # Clean up data directories
    cleanup_data_dirs()

    :ok
  end

  @doc """
  Simulates a network partition by disconnecting nodes.

  ## Parameters

    * `nodes` - List of all nodes
    * `partition_spec` - Tuple like {2, 1} to create [2 nodes, 1 node] partition

  ## Returns

    * `{group_a, group_b}` - The two partitioned groups
  """
  def partition_network(nodes, {count_a, count_b}) do
    {group_a, group_b} = Enum.split(nodes, count_a)

    IO.puts("Creating network partition: #{inspect(group_a)} | #{inspect(group_b)}")

    # Disconnect nodes between groups
    for node_a <- group_a, node_b <- group_b do
      :rpc.call(node_a, Node, :disconnect, [node_b])
      :rpc.call(node_b, Node, :disconnect, [node_a])
    end

    {group_a, group_b}
  end

  @doc """
  Heals a network partition by reconnecting all nodes.
  """
  def heal_partition(nodes) do
    IO.puts("Healing network partition for nodes: #{inspect(nodes)}")

    # Reconnect all nodes
    for node_a <- nodes, node_b <- nodes, node_a != node_b do
      :rpc.call(node_a, Node, :connect, [node_b])
    end

    # Wait for cluster to stabilize
    Process.sleep(2000)
    :ok
  end

  @doc """
  Kills a specific node by stopping it abruptly.
  """
  def kill_node(node) do
    IO.puts("Killing node: #{node}")
    :rpc.call(node, System, :halt, [0])
    Process.sleep(1000)
    :ok
  end

  @doc """
  Restarts a node that was previously killed.
  """
  def restart_node(prefix, index) do
    IO.puts("Restarting node: #{prefix}_#{index}")

    [node] =
      LocalCluster.start_nodes("#{prefix}", 1,
        files: [__ENV__.file],
        applications: [:ra, :telemetry, :concord],
        boot_timeout: 30_000
      )

    :rpc.call(node, Application, :ensure_all_started, [:concord])
    Process.sleep(2000)

    {:ok, node}
  end

  @doc """
  Finds the current Raft leader node.
  """
  def find_leader(nodes) do
    Enum.find(nodes, fn node ->
      case :rpc.call(node, :ra, :members, [{:concord_cluster, node}]) do
        {:ok, _members, leader} ->
          {:concord_cluster, leader_node} = leader
          leader_node == node

        _ ->
          false
      end
    end)
  end

  @doc """
  Waits for a node to catch up with the cluster.
  """
  def wait_for_sync(node, timeout \\ 10_000) do
    start_time = System.monotonic_time(:millisecond)
    until = start_time + timeout

    wait_loop(until, fn ->
      case :rpc.call(node, :ra, :members, [{:concord_cluster, node}]) do
        {:ok, _members, _leader} -> :ready
        _ -> :not_ready
      end
    end)
  end

  # Private functions

  defp wait_for_cluster_ready(nodes, timeout) do
    start_time = System.monotonic_time(:millisecond)
    until = start_time + timeout

    # Check if all nodes can see the cluster
    wait_loop(until, fn ->
      results =
        Enum.map(nodes, fn node ->
          :rpc.call(node, :ra, :members, [{:concord_cluster, node}])
        end)

      # All nodes should return successful member lists
      if Enum.all?(results, &match?({:ok, _members, _leader}, &1)) do
        :ready
      else
        :not_ready
      end
    end)
  end

  defp wait_loop(until, check_fn) do
    case check_fn.() do
      :ready ->
        :ok

      :not_ready ->
        if System.monotonic_time(:millisecond) < until do
          Process.sleep(200)
          wait_loop(until, check_fn)
        else
          {:error, :timeout}
        end
    end
  end

  defp cleanup_data_dirs do
    # Clean up e2e test data
    File.rm_rf!("./data/e2e_test")

    # Clean up any node-specific Ra data
    case File.ls(".") do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, "concord_e2e"))
        |> Enum.each(&File.rm_rf!/1)

      _ ->
        :ok
    end
  end
end
