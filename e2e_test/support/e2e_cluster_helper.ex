defmodule Concord.E2E.ClusterHelper do
  @moduledoc """
  Helper module for managing multi-node Concord clusters in e2e tests.

  Uses manual node spawning via Port to avoid LocalCluster/OTP 28 compatibility issues.
  """

  @doc """
  Starts a multi-node Concord cluster by spawning separate Erlang VMs.

  ## Options

    * `:nodes` - Number of nodes to start (default: 3)
    * `:prefix` - Node name prefix (default: "concord_e2e")
    * `:wait_timeout` - Time to wait for cluster ready in ms (default: 30_000)

  ## Returns

    * `{:ok, nodes, ports}` - List of started node names and their Port references
    * `{:error, reason}` - If cluster failed to start

  ## Examples

      iex> {:ok, nodes, ports} = E2E.ClusterHelper.start_cluster(nodes: 3)
      iex> length(nodes)
      3
  """
  def start_cluster(opts \\ []) do
    node_count = Keyword.get(opts, :nodes, 3)
    prefix = Keyword.get(opts, :prefix, "concord_e2e")
    wait_timeout = Keyword.get(opts, :wait_timeout, 30_000)
    cookie = Keyword.get(opts, :cookie, :concord_e2e_test)

    IO.puts("Starting #{node_count}-node cluster with prefix '#{prefix}'...")

    # Ensure current node is alive (required for distributed Erlang)
    ensure_alive()

    # Set cookie for cluster communication
    Node.set_cookie(cookie)

    # Start nodes as separate OS processes
    nodes_and_ports =
      Enum.map(1..node_count, fn i ->
        node_name = :"#{prefix}#{i}@127.0.0.1"
        port = spawn_node(node_name, cookie)
        {node_name, port}
      end)

    nodes = Enum.map(nodes_and_ports, fn {node, _port} -> node end)
    ports = Enum.map(nodes_and_ports, fn {_node, port} -> port end)

    IO.puts("Started nodes: #{inspect(nodes)}")

    # Wait for nodes to be reachable
    Process.sleep(2000)

    # Connect to all nodes
    Enum.each(nodes, fn node ->
      case Node.connect(node) do
        true -> IO.puts("✓ Connected to #{node}")
        false -> IO.puts("✗ Failed to connect to #{node}")
        :ignored -> IO.puts("⚠ Already connected to #{node}")
      end
    end)

    # Wait for connections to stabilize
    Process.sleep(1000)

    # Initialize Concord on each node
    Enum.each(nodes, fn node ->
      IO.puts("Initializing Concord on #{node}...")
      :rpc.call(node, Application, :ensure_all_started, [:concord])
    end)

    # Initialize Ra cluster on all nodes with full member list
    initialize_ra_cluster(nodes)

    # Wait for cluster formation
    case wait_for_cluster_ready(nodes, wait_timeout) do
      :ok ->
        IO.puts("✓ Cluster ready with #{length(nodes)} nodes")
        {:ok, nodes, ports}

      {:error, reason} ->
        IO.puts("✗ Cluster failed to start: #{inspect(reason)}")
        stop_cluster(ports)
        {:error, reason}
    end
  end

  @doc """
  Stops a running cluster and cleans up resources.
  """
  def stop_cluster(ports) when is_list(ports) do
    IO.puts("Stopping cluster nodes...")

    # Close all ports (kills the node processes)
    Enum.each(ports, fn port ->
      Port.close(port)
    end)

    # Give time for graceful shutdown
    Process.sleep(500)

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
  def partition_network(nodes, {count_a, _count_b}) do
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

  Note: With LocalCluster 2.x, restarting individual nodes requires
  starting a new cluster. For now, this is a simplified implementation.
  """
  def restart_node(_cluster, _node_name) do
    IO.puts("Note: Node restart not fully implemented with LocalCluster 2.x")
    IO.puts("Consider restarting the entire cluster instead")
    {:error, :not_implemented}
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

  defp ensure_alive do
    case Node.alive?() do
      true ->
        :ok

      false ->
        # Current node needs to be alive for distributed Erlang
        # This should already be set by the test runner with --name flag
        raise """
        Current node is not alive! E2E tests require distributed Erlang.
        Run tests with: elixir --name test@127.0.0.1 --cookie test -S mix test e2e_test/
        """
    end
  end

  defp spawn_node(node_name, cookie) do
    # Get the current working directory and Mix environment
    cwd = File.cwd!()
    mix_env = "e2e_test"

    # Build the command to start an iex node
    # Use detached mode to run in background
    cmd = "elixir"

    args = [
      "--name",
      to_string(node_name),
      "--cookie",
      to_string(cookie),
      "--no-halt",
      "--erl",
      "-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9199",
      "-S",
      "mix",
      "run",
      "--no-start"
    ]

    # Spawn the node as a separate OS process
    port =
      Port.open(
        {:spawn_executable, System.find_executable(cmd)},
        [
          :binary,
          :exit_status,
          {:args, args},
          {:cd, cwd},
          {:env, [{~c"MIX_ENV", String.to_charlist(mix_env)}]},
          {:line, 1024}
        ]
      )

    IO.puts("Spawned node #{node_name} via Port #{inspect(port)}")
    port
  end

  defp initialize_ra_cluster(nodes) do
    cluster_name = :concord_cluster
    data_dir_base = "./data/e2e_test"

    # Build server IDs for all nodes
    server_ids = Enum.map(nodes, &{cluster_name, &1})

    IO.puts("Initializing Ra cluster with members: #{inspect(server_ids)}")

    # Initialize Ra cluster on each node
    Enum.each(nodes, fn node ->
      node_id = {cluster_name, node}
      uid = node_id |> Tuple.to_list() |> Enum.join("_") |> String.replace("@", "_")
      data_dir = "#{data_dir_base}/#{node}"

      # Stop existing Ra server if running
      case :rpc.call(node, :ra, :stop_server, [node_id]) do
        :ok ->
          IO.puts("✓ Stopped existing Ra server on #{node}")

        {:error, :not_started} ->
          IO.puts("⚠ Ra server was not started on #{node}")

        {:error, :system_not_started} ->
          IO.puts("⚠ Ra system not started on #{node}")

        {:badrpc, _} = error ->
          IO.puts("⚠ RPC error stopping Ra on #{node}: #{inspect(error)}")

        error ->
          IO.puts("⚠ Stop server on #{node} returned: #{inspect(error)}")
      end

      # Wait for shutdown
      Process.sleep(500)

      # Start Ra server with all members
      server_config = %{
        id: node_id,
        uid: uid,
        cluster_name: cluster_name,
        machine: {:module, Concord.StateMachine, %{}},
        log_init_args: %{
          uid: uid,
          data_dir: data_dir
        },
        initial_members: server_ids
      }

      case :rpc.call(node, :ra, :start_server, [server_config]) do
        :ok ->
          IO.puts("✓ Ra server started on #{node}")
          :rpc.call(node, :ra, :trigger_election, [node_id])
          :ok

        {:ok, _} ->
          IO.puts("✓ Ra server started on #{node}")
          :ok

        {:error, {:already_started, _}} ->
          IO.puts("✓ Ra server already running on #{node}")
          :ok

        {:error, reason} ->
          IO.puts("✗ Failed to start Ra server on #{node}: #{inspect(reason)}")
          {:error, reason}

        {:badrpc, reason} ->
          IO.puts("✗ RPC error starting Ra on #{node}: #{inspect(reason)}")
          {:error, {:badrpc, reason}}
      end
    end)

    # Wait for Ra cluster to initialize
    Process.sleep(3000)
    :ok
  end

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
