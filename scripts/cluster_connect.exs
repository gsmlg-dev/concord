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

    # Wait for Raft cluster to initialize
    IO.puts("\nWaiting for Raft cluster to initialize...")
    Process.sleep(2000)

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

# Auto-connect when script is loaded
IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("Concord Cluster Helper Loaded")
IO.puts(String.duplicate("=", 60))
IO.puts("\nAvailable commands:")
IO.puts("  ClusterHelper.connect_all()  - Connect to all nodes")
IO.puts("  ClusterHelper.status()       - Check cluster status")
IO.puts("  ClusterHelper.test_put_get() - Test basic operations")
IO.puts("\nConnecting to cluster nodes...")
IO.puts(String.duplicate("=", 60) <> "\n")

ClusterHelper.connect_all()
