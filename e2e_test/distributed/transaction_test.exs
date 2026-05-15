defmodule Concord.E2E.TransactionTest do
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

  describe "Transaction Consistency" do
    test "atomic create-if-absent across cluster", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)
      assert leader != nil

      # Transaction: create key only if it doesn't exist
      spec = %{
        compare: [{:exists, "txn:create", :==, false}],
        success: [{:put, "txn:create", "created_atomically", %{}}],
        failure: [{:get, {:key, "txn:create"}, %{}}]
      }

      {:ok, result} = :rpc.call(leader, Concord.Txn, :commit, [spec])
      assert result.succeeded == true

      # Give time for replication
      Process.sleep(500)

      # Verify on all nodes
      results =
        Enum.map(nodes, fn node ->
          :rpc.call(node, Concord, :get, ["txn:create"])
        end)

      assert Enum.all?(results, &(&1 == {:ok, "created_atomically"})),
             "Txn result should replicate to all nodes"

      IO.puts("✓ Atomic create-if-absent replicated to all #{length(nodes)} nodes")
    end

    test "concurrent create-if-absent — only one wins", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)

      # Launch concurrent create attempts
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            spec = %{
              compare: [{:exists, "txn:race", :==, false}],
              success: [{:put, "txn:race", "writer_#{i}", %{}}],
              failure: [{:get, {:key, "txn:race"}, %{}}]
            }

            :rpc.call(leader, Concord.Txn, :commit, [spec])
          end)
        end

      results = Task.await_many(tasks, 30_000)

      # Exactly one should succeed
      succeeded_count =
        Enum.count(results, fn
          {:ok, %{succeeded: true}} -> true
          _ -> false
        end)

      assert succeeded_count == 1, "Exactly one create-if-absent should win the race"

      # All nodes should see the same final value
      Process.sleep(500)

      final_values =
        Enum.map(nodes, fn node ->
          :rpc.call(node, Concord, :get, ["txn:race"])
        end)

      unique = Enum.uniq(final_values)
      assert length(unique) == 1, "All nodes should agree on the value"

      IO.puts("✓ Concurrent create-if-absent: exactly 1 of 10 writers won")
    end

    test "multi-key transaction atomicity", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)

      # Setup: create initial keys
      :rpc.call(leader, Concord, :put, ["account:A", 1000])
      :rpc.call(leader, Concord, :put, ["account:B", 500])
      Process.sleep(300)

      # Transaction: transfer 200 from A to B (read-modify-write)
      spec = %{
        compare: [{:exists, "account:A", :==, true}, {:exists, "account:B", :==, true}],
        success: [
          {:put, "account:A", 800, %{}},
          {:put, "account:B", 700, %{}}
        ],
        failure: []
      }

      {:ok, result} = :rpc.call(leader, Concord.Txn, :commit, [spec])
      assert result.succeeded == true

      Process.sleep(500)

      # Verify both accounts updated atomically on all nodes
      for node <- nodes do
        {:ok, a_val} = :rpc.call(node, Concord, :get, ["account:A"])
        {:ok, b_val} = :rpc.call(node, Concord, :get, ["account:B"])

        assert a_val == 800 and b_val == 700,
               "Transfer should be atomic on #{node}: A=#{a_val}, B=#{b_val}"
      end

      IO.puts("✓ Multi-key transaction (transfer) replicated atomically")
    end

    test "transaction with prefix delete", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)

      # Create several keys under a prefix
      for i <- 1..5 do
        :rpc.call(leader, Concord, :put, ["txn:batch:#{i}", "v#{i}"])
      end

      :rpc.call(leader, Concord, :put, ["txn:keep", "safe"])
      Process.sleep(300)

      # Delete all keys under prefix in one transaction
      spec = %{
        compare: [],
        success: [{:delete, {:prefix, "txn:batch:"}, %{}}],
        failure: []
      }

      {:ok, result} = :rpc.call(leader, Concord.Txn, :commit, [spec])
      assert result.succeeded == true

      [{:delete, {:prefix, "txn:batch:"}, %{deleted: deleted}}] = result.responses
      assert deleted == 5

      Process.sleep(500)

      # Verify all batch keys gone, keep key preserved
      for node <- nodes do
        for i <- 1..5 do
          assert {:error, :not_found} = :rpc.call(node, Concord, :get, ["txn:batch:#{i}"])
        end

        assert {:ok, "safe"} = :rpc.call(node, Concord, :get, ["txn:keep"])
      end

      IO.puts("✓ Prefix delete via transaction replicated to all nodes")
    end

    test "failed compare runs failure branch — no mutation", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)

      # Try to update a key that doesn't exist
      spec = %{
        compare: [{:exists, "txn:phantom", :==, true}],
        success: [{:put, "txn:phantom", "should_not_exist", %{}}],
        failure: []
      }

      {:ok, result} = :rpc.call(leader, Concord.Txn, :commit, [spec])
      assert result.succeeded == false

      Process.sleep(300)

      # Key should not exist on any node
      for node <- nodes do
        assert {:error, :not_found} = :rpc.call(node, Concord, :get, ["txn:phantom"])
      end

      IO.puts("✓ Failed compare correctly prevented mutation")
    end
  end
end
