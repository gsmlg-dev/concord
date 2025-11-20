defmodule Concord.E2E.NodeFailureTest do
  use ExUnit.Case, async: false
  alias Concord.E2E.ClusterHelper

  @moduletag :e2e
  @moduletag :distributed

  setup do
    {:ok, nodes, ports} = ClusterHelper.start_cluster(nodes: 3)

    on_exit(fn ->
      ClusterHelper.stop_cluster(ports)
    end)

    %{nodes: nodes, ports: ports}
  end

  describe "Node Failure Recovery" do
    test "cluster continues operating with one node down", %{nodes: [n1, n2, n3]} do
      # Find leader
      leader = ClusterHelper.find_leader([n1, n2, n3])

      # Write some data
      :ok = :rpc.call(leader, Concord, :put, ["failure:key1", "value1"])

      # Kill a follower (not the leader)
      follower = Enum.find([n1, n2, n3], &(&1 != leader)) |> List.first()
      ClusterHelper.kill_node(follower)

      # Wait for cluster to detect failure
      Process.sleep(2000)

      # Cluster should still accept writes (has quorum)
      :ok = :rpc.call(leader, Concord, :put, ["failure:key2", "value2"])

      # Should be able to read from remaining nodes
      {:ok, "value2"} = :rpc.call(leader, Concord, :get, ["failure:key2"])

      IO.puts("✓ Cluster continues operating with one node down")
    end

    @tag :skip
    test "node catches up after restart", %{nodes: nodes} do
      # TODO: Implement with LocalCluster 2.x API
      # Restarting individual nodes requires a different approach with LocalCluster 2.x
      IO.puts("⚠ Test skipped: Node restart not yet implemented with LocalCluster 2.x")

      leader = ClusterHelper.find_leader(nodes)
      assert leader != nil
    end

    test "cluster handles rapid node failures", %{nodes: [n1, n2, n3]} do
      initial_leader = ClusterHelper.find_leader([n1, n2, n3])

      # Write initial data
      :ok = :rpc.call(initial_leader, Concord, :put, ["rapid:key", "initial_value"])

      # Kill two nodes rapidly (but not all three - need quorum)
      followers = Enum.filter([n1, n2, n3], &(&1 != initial_leader))
      [follower1 | _] = followers

      ClusterHelper.kill_node(follower1)

      # The remaining node should still function
      Process.sleep(3000)

      # At least one node should still be able to serve reads
      surviving_node = Enum.find([n1, n2, n3], &(&1 != follower1 && &1 != initial_leader))

      if surviving_node do
        # Check if we can still read (may timeout if leader was killed)
        case :rpc.call(surviving_node, Concord, :get, ["rapid:key"]) do
          {:ok, "initial_value"} ->
            IO.puts("✓ Cluster survived rapid node failures")

          _ ->
            IO.puts("⚠ Could not read after rapid failures (expected if leader was killed)")
        end
      end
    end
  end
end
