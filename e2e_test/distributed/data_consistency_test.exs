defmodule Concord.E2E.DataConsistencyTest do
  use ExUnit.Case, async: false
  alias Concord.E2E.ClusterHelper

  @moduletag :e2e
  @moduletag :distributed

  setup do
    {:ok, nodes, cluster} = ClusterHelper.start_cluster(nodes: 3)

    on_exit(fn ->
      ClusterHelper.stop_cluster(cluster)
    end)

    %{nodes: nodes, cluster: cluster}
  end

  describe "Data Consistency" do
    test "writes are replicated to all nodes", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)
      assert leader != nil

      # Write to leader
      :ok = :rpc.call(leader, Concord, :put, ["replicated:key", "test_value"])

      # Give time for replication
      Process.sleep(500)

      # Read from all nodes
      results =
        Enum.map(nodes, fn node ->
          :rpc.call(node, Concord, :get, ["replicated:key"])
        end)

      # All nodes should have the value
      assert Enum.all?(results, &(&1 == {:ok, "test_value"})),
             "All nodes should have replicated data"

      IO.puts("✓ Data replicated to all #{length(nodes)} nodes")
    end

    test "concurrent writes maintain consistency", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)

      # Perform concurrent writes
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            :rpc.call(leader, Concord, :put, ["concurrent:#{i}", "value_#{i}"])
          end)
        end

      # Wait for all writes to complete
      Task.await_many(tasks, 30_000)

      # Give time for replication
      Process.sleep(1000)

      # Verify all writes succeeded and are consistent across nodes
      for i <- 1..100 do
        results =
          Enum.map(nodes, fn node ->
            :rpc.call(node, Concord, :get, ["concurrent:#{i}"])
          end)

        unique_results = Enum.uniq(results)

        assert length(unique_results) == 1,
               "All nodes should have same value for key concurrent:#{i}"

        assert hd(unique_results) == {:ok, "value_#{i}"}
      end

      IO.puts("✓ 100 concurrent writes maintained consistency across cluster")
    end

    test "bulk operations maintain consistency", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)

      # Create bulk data
      bulk_data =
        for i <- 1..50 do
          {"bulk:key#{i}", %{index: i, data: "bulk_value_#{i}"}}
        end

      # Perform bulk put
      :ok = :rpc.call(leader, Concord, :put_many, [bulk_data])

      # Give time for replication
      Process.sleep(1000)

      # Verify all keys exist on all nodes
      sample_keys = ["bulk:key1", "bulk:key25", "bulk:key50"]

      for key <- sample_keys do
        results =
          Enum.map(nodes, fn node ->
            :rpc.call(node, Concord, :get, [key])
          end)

        assert Enum.all?(results, &match?({:ok, _}, &1)),
               "All nodes should have bulk data for #{key}"

        # Verify consistency
        unique_values = Enum.uniq(results)
        assert length(unique_values) == 1, "All nodes should have same value for #{key}"
      end

      IO.puts("✓ Bulk put of 50 items maintained consistency")
    end

    test "TTL expiration is consistent across nodes", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)

      # Put with 2 second TTL
      :ok = :rpc.call(leader, Concord, :put_with_ttl, ["ttl:key", "expires_soon", 2])

      # Verify it exists on all nodes
      results_before =
        Enum.map(nodes, fn node ->
          :rpc.call(node, Concord, :get, ["ttl:key"])
        end)

      assert Enum.all?(results_before, &(&1 == {:ok, "expires_soon"}))

      # Wait for expiration
      Process.sleep(3000)

      # Verify it's gone from all nodes
      results_after =
        Enum.map(nodes, fn node ->
          :rpc.call(node, Concord, :get, ["ttl:key"])
        end)

      assert Enum.all?(results_after, &(&1 == {:error, :not_found})),
             "TTL key should expire on all nodes"

      IO.puts("✓ TTL expiration consistent across all nodes")
    end

    test "delete operations are replicated", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)

      # Create key
      :ok = :rpc.call(leader, Concord, :put, ["delete:key", "to_be_deleted"])

      # Verify it exists
      Process.sleep(500)

      assert :rpc.call(leader, Concord, :get, ["delete:key"]) == {:ok, "to_be_deleted"}

      # Delete the key
      :ok = :rpc.call(leader, Concord, :delete, ["delete:key"])

      # Verify deletion is replicated to all nodes
      Process.sleep(500)

      results =
        Enum.map(nodes, fn node ->
          :rpc.call(node, Concord, :get, ["delete:key"])
        end)

      assert Enum.all?(results, &(&1 == {:error, :not_found})),
             "Delete should be replicated to all nodes"

      IO.puts("✓ Delete operation replicated to all nodes")
    end
  end
end
