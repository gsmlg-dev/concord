defmodule Concord.E2E.ClusterBasicsTest do
  use ExUnit.Case, async: false
  alias Concord.E2E.Cluster

  @moduletag :e2e

  describe "cluster formation" do
    test "all nodes are connected" do
      connected = Cluster.connected_nodes()
      assert length(connected) == 3, "Expected 3 nodes, got #{length(connected)}: #{inspect(connected)}"
    end

    test "raft leader is elected" do
      leader = Cluster.find_leader()
      assert leader != nil, "No Raft leader found"
      assert leader in Cluster.nodes()
      IO.puts("  ✓ Leader: #{leader}")
    end
  end

  describe "data replication" do
    test "writes replicate to all nodes" do
      leader = Cluster.find_leader()
      :ok = :rpc.call(leader, Concord, :put, ["e2e:repl:1", "hello"])

      assert :ok = Cluster.wait_replicated("e2e:repl:1", {:ok, "hello"})
      IO.puts("  ✓ Write replicated to all 3 nodes")
    end

    test "concurrent writes maintain consistency" do
      leader = Cluster.find_leader()

      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            :rpc.call(leader, Concord, :put, ["e2e:conc:#{i}", "v#{i}"])
          end)
        end

      Task.await_many(tasks, 30_000)
      Process.sleep(1000)

      for i <- 1..50 do
        results = Cluster.rpc_all(Concord, :get, ["e2e:conc:#{i}"])
        values = Enum.map(results, fn {_, v} -> v end) |> Enum.uniq()
        assert length(values) == 1, "Key e2e:conc:#{i} inconsistent: #{inspect(results)}"
      end

      IO.puts("  ✓ 50 concurrent writes consistent across cluster")
    end

    test "deletes replicate to all nodes" do
      leader = Cluster.find_leader()
      :ok = :rpc.call(leader, Concord, :put, ["e2e:del:1", "doomed"])
      Cluster.wait_replicated("e2e:del:1", {:ok, "doomed"})

      :ok = :rpc.call(leader, Concord, :delete, ["e2e:del:1"])
      assert :ok = Cluster.wait_replicated("e2e:del:1", {:error, :not_found})
      IO.puts("  ✓ Delete replicated to all nodes")
    end

    test "bulk put_many replicates" do
      leader = Cluster.find_leader()
      data = for i <- 1..20, do: {"e2e:bulk:#{i}", %{index: i}}
      {:ok, _} = :rpc.call(leader, Concord, :put_many, [data])

      Process.sleep(1000)

      for key <- ["e2e:bulk:1", "e2e:bulk:10", "e2e:bulk:20"] do
        results = Cluster.rpc_all(Concord, :get, [key])
        assert Enum.all?(results, fn {_, v} -> match?({:ok, _}, v) end),
               "#{key} missing on some nodes: #{inspect(results)}"
      end

      IO.puts("  ✓ Bulk put of 20 items replicated")
    end
  end
end
