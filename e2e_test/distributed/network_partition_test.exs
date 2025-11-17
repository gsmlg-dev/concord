defmodule Concord.E2E.NetworkPartitionTest do
  use ExUnit.Case, async: false
  alias Concord.E2E.ClusterHelper

  @moduletag :e2e
  @moduletag :distributed

  setup do
    {:ok, nodes} = ClusterHelper.start_cluster(nodes: 5)

    on_exit(fn ->
      ClusterHelper.stop_cluster(nodes)
    end)

    %{nodes: nodes}
  end

  describe "Network Partition" do
    test "majority partition continues to serve requests", %{nodes: nodes} do
      # Create 3-2 partition (majority has 3 nodes)
      {majority, minority} = ClusterHelper.partition_network(nodes, {3, 2})

      IO.puts("Majority partition: #{inspect(majority)}")
      IO.puts("Minority partition: #{inspect(minority)}")

      # Wait for partition to stabilize
      Process.sleep(3000)

      # Majority should still have a leader
      majority_leader = ClusterHelper.find_leader(majority)
      assert majority_leader != nil, "Majority partition should elect a leader"

      # Majority should accept writes
      result = :rpc.call(majority_leader, Concord, :put, ["partition:test", "majority_value"])
      assert result == :ok, "Majority partition should accept writes"

      IO.puts("✓ Majority partition (#{length(majority)} nodes) continues to serve requests")
    end

    test "minority partition cannot serve writes during partition", %{nodes: nodes} do
      # Create 3-2 partition
      {majority, minority} = ClusterHelper.partition_network(nodes, {3, 2})

      Process.sleep(3000)

      # Try to write to minority partition
      minority_node = List.first(minority)

      # Minority should not accept writes (no quorum)
      result = :rpc.call(minority_node, Concord, :put, ["minority:test", "value"])

      # This should timeout or fail due to lack of quorum
      assert result != :ok, "Minority partition should not accept writes without quorum"

      IO.puts("✓ Minority partition correctly rejects writes (no quorum)")
    end

    test "cluster recovers after partition heals", %{nodes: nodes} do
      # Create partition
      {majority, _minority} = ClusterHelper.partition_network(nodes, {3, 2})

      Process.sleep(2000)

      # Write to majority
      majority_leader = ClusterHelper.find_leader(majority)
      :ok = :rpc.call(majority_leader, Concord, :put, ["heal:test", "partition_value"])

      # Heal the partition
      ClusterHelper.heal_partition(nodes)
      Process.sleep(3000)

      # All nodes should now see the data
      results =
        Enum.map(nodes, fn node ->
          :rpc.call(node, Concord, :get, ["heal:test"])
        end)

      # All nodes should have the same value
      assert Enum.all?(results, &(&1 == {:ok, "partition_value"})),
             "All nodes should converge to same value after partition heals"

      IO.puts("✓ Cluster recovered and data converged after partition healed")
    end

    test "no split-brain after partition heals", %{nodes: nodes} do
      # Create partition
      {majority, _minority} = ClusterHelper.partition_network(nodes, {3, 2})

      Process.sleep(2000)

      # Write different values to majority
      majority_leader = ClusterHelper.find_leader(majority)
      :ok = :rpc.call(majority_leader, Concord, :put, ["conflict:key", "majority_wins"])

      # Heal partition
      ClusterHelper.heal_partition(nodes)
      Process.sleep(3000)

      # Check that all nodes have consistent view
      values =
        Enum.map(nodes, fn node ->
          :rpc.call(node, Concord, :get, ["conflict:key"])
        end)

      unique_values = Enum.uniq(values)

      assert length(unique_values) == 1,
             "All nodes should have the same value (no split-brain)"

      IO.puts("✓ No split-brain: all nodes have consistent value")
    end
  end
end
