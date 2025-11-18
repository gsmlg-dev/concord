defmodule Concord.E2E.LeaderElectionTest do
  use ExUnit.Case, async: false
  alias Concord.E2E.ClusterHelper

  @moduletag :e2e
  @moduletag :distributed

  setup do
    # Start a fresh cluster for each test
    {:ok, nodes, cluster} = ClusterHelper.start_cluster(nodes: 3)

    on_exit(fn ->
      ClusterHelper.stop_cluster(cluster)
    end)

    %{nodes: nodes, cluster: cluster}
  end

  describe "Leader Election" do
    test "cluster elects a leader on startup", %{nodes: nodes} do
      # Find the current leader
      leader = ClusterHelper.find_leader(nodes)

      assert leader != nil, "Cluster should have elected a leader"
      assert leader in nodes, "Leader should be one of the cluster nodes"

      IO.puts("✓ Leader elected: #{leader}")
    end

    test "new leader elected after current leader dies", %{nodes: nodes} do
      # Find initial leader
      initial_leader = ClusterHelper.find_leader(nodes)
      assert initial_leader != nil

      IO.puts("Initial leader: #{initial_leader}")

      # Kill the leader
      ClusterHelper.kill_node(initial_leader)

      # Wait for new leader election
      Process.sleep(5000)

      # Find new leader among remaining nodes
      remaining_nodes = Enum.filter(nodes, &(&1 != initial_leader))
      new_leader = ClusterHelper.find_leader(remaining_nodes)

      assert new_leader != nil, "New leader should be elected"
      assert new_leader != initial_leader, "New leader should be different from old leader"
      assert new_leader in remaining_nodes, "New leader should be from remaining nodes"

      IO.puts("✓ New leader elected: #{new_leader}")
    end

    test "data remains consistent after leader change", %{nodes: nodes} do
      # Write data to current leader
      initial_leader = ClusterHelper.find_leader(nodes)

      # Perform write via RPC to leader
      :ok = :rpc.call(initial_leader, Concord, :put, ["test:key", "initial_value"])

      # Verify data is replicated
      {:ok, value} = :rpc.call(initial_leader, Concord, :get, ["test:key"])
      assert value == "initial_value"

      # Kill the leader
      ClusterHelper.kill_node(initial_leader)
      Process.sleep(5000)

      # Find new leader
      remaining_nodes = Enum.filter(nodes, &(&1 != initial_leader))
      new_leader = ClusterHelper.find_leader(remaining_nodes)

      # Verify data is still accessible from new leader
      {:ok, value_after_failover} = :rpc.call(new_leader, Concord, :get, ["test:key"])
      assert value_after_failover == "initial_value"

      IO.puts("✓ Data remained consistent across leader change")
    end
  end
end
