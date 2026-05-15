defmodule Concord.E2E.V2TxnTest do
  use ExUnit.Case, async: false
  alias Concord.E2E.Cluster

  @moduletag :e2e

  describe "transactions across cluster" do
    test "atomic create-if-absent" do
      leader = Cluster.find_leader()

      spec = %{
        compare: [{:exists, "e2e:txn:create", :==, false}],
        success: [{:put, "e2e:txn:create", "atomically_created", %{}}],
        failure: []
      }

      {:ok, result} = :rpc.call(leader, Concord.Txn, :commit, [spec])
      assert result.succeeded == true

      assert :ok = Cluster.wait_replicated("e2e:txn:create", {:ok, "atomically_created"})
      IO.puts("  ✓ Atomic create-if-absent replicated")
    end

    test "concurrent create-if-absent — exactly one wins" do
      leader = Cluster.find_leader()

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            spec = %{
              compare: [{:exists, "e2e:txn:race", :==, false}],
              success: [{:put, "e2e:txn:race", "writer_#{i}", %{}}],
              failure: []
            }

            :rpc.call(leader, Concord.Txn, :commit, [spec])
          end)
        end

      results = Task.await_many(tasks, 30_000)

      winners =
        Enum.count(results, fn
          {:ok, %{succeeded: true}} -> true
          _ -> false
        end)

      assert winners == 1, "Exactly 1 writer should win, got #{winners}"

      # All nodes see the same value
      Process.sleep(500)
      values = Cluster.rpc_all(Concord, :get, ["e2e:txn:race"])
      unique = values |> Enum.map(fn {_, v} -> v end) |> Enum.uniq()
      assert length(unique) == 1

      IO.puts("  ✓ Race: exactly 1 of 10 writers won")
    end

    test "multi-key atomic transfer" do
      leader = Cluster.find_leader()

      :rpc.call(leader, Concord, :put, ["e2e:acct:A", 1000])
      :rpc.call(leader, Concord, :put, ["e2e:acct:B", 500])
      Process.sleep(300)

      spec = %{
        compare: [
          {:exists, "e2e:acct:A", :==, true},
          {:exists, "e2e:acct:B", :==, true}
        ],
        success: [
          {:put, "e2e:acct:A", 800, %{}},
          {:put, "e2e:acct:B", 700, %{}}
        ],
        failure: []
      }

      {:ok, result} = :rpc.call(leader, Concord.Txn, :commit, [spec])
      assert result.succeeded == true

      Process.sleep(500)

      for node <- Cluster.nodes() do
        {:ok, a} = :rpc.call(node, Concord, :get, ["e2e:acct:A"])
        {:ok, b} = :rpc.call(node, Concord, :get, ["e2e:acct:B"])
        assert a == 800 and b == 700, "Transfer not atomic on #{node}: A=#{a}, B=#{b}"
      end

      IO.puts("  ✓ Multi-key transfer atomic across cluster")
    end

    test "prefix delete in transaction" do
      leader = Cluster.find_leader()

      for i <- 1..5 do
        :rpc.call(leader, Concord, :put, ["e2e:txn:batch:#{i}", "v#{i}"])
      end

      :rpc.call(leader, Concord, :put, ["e2e:txn:keep", "safe"])
      Process.sleep(300)

      spec = %{
        compare: [],
        success: [{:delete, {:prefix, "e2e:txn:batch:"}, %{}}],
        failure: []
      }

      {:ok, result} = :rpc.call(leader, Concord.Txn, :commit, [spec])
      assert result.succeeded == true

      Process.sleep(500)

      for node <- Cluster.nodes() do
        for i <- 1..5 do
          assert {:error, :not_found} = :rpc.call(node, Concord, :get, ["e2e:txn:batch:#{i}"])
        end

        assert {:ok, "safe"} = :rpc.call(node, Concord, :get, ["e2e:txn:keep"])
      end

      IO.puts("  ✓ Prefix delete via txn replicated, safe key preserved")
    end

    test "failed compare — no mutation" do
      leader = Cluster.find_leader()

      spec = %{
        compare: [{:exists, "e2e:txn:ghost", :==, true}],
        success: [{:put, "e2e:txn:ghost", "should_not_exist", %{}}],
        failure: []
      }

      {:ok, result} = :rpc.call(leader, Concord.Txn, :commit, [spec])
      assert result.succeeded == false

      Process.sleep(300)

      for node <- Cluster.nodes() do
        assert {:error, :not_found} = :rpc.call(node, Concord, :get, ["e2e:txn:ghost"])
      end

      IO.puts("  ✓ Failed compare prevented mutation")
    end
  end
end
