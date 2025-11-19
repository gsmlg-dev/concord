# Helper script to connect nodes in a manual test cluster
#
# Usage:
#   # Start nodes in separate terminals:
#   iex --name n1@127.0.0.1 --cookie concord_test -S mix
#   iex --name n2@127.0.0.1 --cookie concord_test -S mix
#   iex --name n3@127.0.0.1 --cookie concord_test -S mix
#
#   # In the first node (n1), run:
#   import_file("scripts/cluster_connect.exs")

defmodule ClusterHelper do
  @moduledoc """
  Helper functions for manual cluster testing.
  """

  defp restart_cluster_all_nodes do
    all_nodes = [Node.self() | Node.list()]

    # First, load this module on all remote nodes
    IO.puts("Loading ClusterHelper on all nodes...")

    script_path = Path.expand("scripts/cluster_connect.exs")
    script_content = File.read!(script_path)

    Enum.each(all_nodes, fn node ->
      unless node == Node.self() do
        # Load the module on remote node
        :rpc.call(node, Code, :eval_string, [script_content])
        IO.puts("✓ Loaded on #{node}")
      end
    end)

    Process.sleep(500)

    # Now restart on all nodes
    Enum.each(all_nodes, fn node ->
      IO.puts("\nRestarting cluster on #{node}...")

      if node == Node.self() do
        restart_cluster()
      else
        # Use RPC to restart on remote node
        :rpc.call(node, ClusterHelper, :restart_cluster_remote, [])
      end
    end)
  end

  def restart_cluster_remote do
    restart_cluster()
  end

  defp restart_cluster do
    cluster_name = :concord_cluster
    node_id = {cluster_name, node()}

    # Stop existing Ra server
    case :ra.stop_server(node_id) do
      :ok ->
        IO.puts("✓ Stopped existing Ra server")

      {:error, :not_started} ->
        IO.puts("⚠ Ra server was not started")

      {:error, :system_not_started} ->
        IO.puts("⚠ Ra system not started yet, skipping stop")

      error ->
        IO.puts("⚠ Stop server returned: #{inspect(error)}")
    end

    # Wait for shutdown
    Process.sleep(500)

    # Delete server data to force fresh start
    data_dir = Application.get_env(:concord, :data_dir, "./data/#{node()}")
    uid = node_id |> Tuple.to_list() |> Enum.join("_") |> String.replace("@", "_")

    # Get all connected nodes including self
    nodes = [Node.self() | Node.list()]
    server_ids = Enum.map(nodes, &{cluster_name, &1})

    IO.puts("Starting Ra cluster with members: #{inspect(server_ids)}")

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

    case :ra.start_server(server_config) do
      :ok ->
        IO.puts("✓ Ra server started successfully")
        :ra.trigger_election(node_id)
        :ok

      {:ok, _} ->
        IO.puts("✓ Ra server started successfully")
        :ok

      {:error, {:already_started, _}} ->
        IO.puts("✓ Ra server already running")
        :ok

      {:error, reason} ->
        IO.puts("✗ Failed to start Ra server: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def connect_all do
    IO.puts("\n=== Connecting Cluster Nodes ===\n")

    nodes = [
      :"n1@127.0.0.1",
      :"n2@127.0.0.1",
      :"n3@127.0.0.1"
    ]

    # Connect to all other nodes
    Enum.each(nodes, fn node ->
      if node != Node.self() do
        case Node.connect(node) do
          true ->
            IO.puts("✓ Connected to #{node}")
          false ->
            IO.puts("✗ Failed to connect to #{node}")
          :ignored ->
            IO.puts("⚠ Already connected to #{node}")
        end
      end
    end)

    # Wait for connections to stabilize
    Process.sleep(1000)

    IO.puts("\n=== Cluster Status ===\n")
    IO.puts("Current node: #{node()}")
    IO.puts("Connected nodes: #{inspect(Node.list())}")

    # Restart the Raft cluster on ALL nodes with all members
    IO.puts("\nRestarting Raft cluster on all nodes...")
    restart_cluster_all_nodes()

    # Wait for Raft cluster to initialize
    IO.puts("Waiting for Raft cluster to initialize...")
    Process.sleep(3000)

    case :ra.members({:concord_cluster, node()}) do
      {:ok, members, {:concord_cluster, leader}} ->
        IO.puts("\n✓ Raft cluster ready!")
        IO.puts("Leader: #{leader}")
        IO.puts("Members: #{inspect(members)}")
        IO.puts("\nYou can now use Concord.put/2 and Concord.get/1")

      {:error, reason} ->
        IO.puts("\n✗ Raft cluster not ready: #{inspect(reason)}")
        IO.puts("Wait a few more seconds and try: :ra.members({:concord_cluster, node()})")

      {:timeout, _} ->
        IO.puts("\n⚠ Raft cluster is still initializing...")
        IO.puts("Wait a few more seconds and try: :ra.members({:concord_cluster, node()})")
    end

    :ok
  end

  def status do
    IO.puts("\n=== Cluster Status ===\n")
    IO.puts("Current node: #{node()}")
    IO.puts("Connected nodes: #{inspect(Node.list())}")

    case :ra.members({:concord_cluster, node()}) do
      {:ok, members, {:concord_cluster, leader}} ->
        IO.puts("\nRaft cluster status: READY")
        IO.puts("Leader: #{leader}")
        IO.puts("Members: #{inspect(members)}")

      error ->
        IO.puts("\nRaft cluster status: NOT READY")
        IO.puts("Error: #{inspect(error)}")
    end

    :ok
  end

  def test_put_get do
    IO.puts("\n=== Testing Concord Operations ===\n")

    key = "test_key_#{System.system_time(:second)}"
    value = "test_value_#{:rand.uniform(1000)}"

    IO.puts("Putting: #{key} = #{value}")

    case Concord.put(key, value) do
      :ok ->
        IO.puts("✓ Put successful")

        IO.puts("Getting: #{key}")

        case Concord.get(key) do
          {:ok, ^value} ->
            IO.puts("✓ Get successful: #{inspect(value)}")
            IO.puts("\n✓✓✓ Concord cluster is working! ✓✓✓")

          {:ok, other} ->
            IO.puts("✗ Got unexpected value: #{inspect(other)}")

          error ->
            IO.puts("✗ Get failed: #{inspect(error)}")
        end

      error ->
        IO.puts("✗ Put failed: #{inspect(error)}")
        IO.puts("The cluster may not be ready yet. Wait a few seconds and try: ClusterHelper.status()")
    end

    :ok
  end
end

# Only auto-run if AUTO_CONNECT environment variable is set
if System.get_env("AUTO_CONNECT") do
  IO.puts("\n" <> String.duplicate("=", 60))
  IO.puts("Auto-connecting cluster nodes...")
  IO.puts(String.duplicate("=", 60) <> "\n")

  ClusterHelper.connect_all()
else
  IO.puts("\n" <> String.duplicate("=", 60))
  IO.puts("Concord Cluster Helper Loaded")
  IO.puts(String.duplicate("=", 60))
  IO.puts("\nAvailable commands:")
  IO.puts("  ClusterHelper.connect_all()  - Connect and restart cluster on all nodes")
  IO.puts("  ClusterHelper.status()       - Check cluster status")
  IO.puts("  ClusterHelper.test_put_get() - Test basic operations")
  IO.puts("\nTo connect the cluster, run:")
  IO.puts("  ClusterHelper.connect_all()")
  IO.puts(String.duplicate("=", 60) <> "\n")
end
