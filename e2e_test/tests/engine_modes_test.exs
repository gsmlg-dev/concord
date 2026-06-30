defmodule Concord.E2E.EngineModesTest do
  use ExUnit.Case, async: false
  alias Concord.E2E.Cluster

  @moduletag :e2e

  describe "engine API selection" do
    test "explicit cluster API writes through Raft and replicates" do
      leader = Cluster.find_leader()
      key = unique_key("cluster")

      :ok = :rpc.call(leader, Concord.Cluster, :put, [key, "cluster-value"])

      assert :ok = Cluster.wait_replicated(key, {:ok, "cluster-value"})

      assert_all_nodes(Concord.Cluster, :get, [key], {:ok, "cluster-value"})
      assert {:ok, "cluster-value"} = :rpc.call(leader, Concord, :get, [key])

      IO.puts("  ✓ Concord.Cluster writes replicate and remain visible via Concord")
    end

    test "local API writes stay on the target node only" do
      [local_node | other_nodes] = Cluster.nodes()
      key = unique_key("local")

      :ok = :rpc.call(local_node, Concord.Local, :put, [key, "node-local-value"])

      assert {:ok, "node-local-value"} = :rpc.call(local_node, Concord.Local, :get, [key])

      for node <- other_nodes do
        assert {:error, :not_found} = :rpc.call(node, Concord.Local, :get, [key])
      end

      assert_all_nodes(Concord, :get, [key], {:error, :not_found})
      assert_all_nodes(Concord.Cluster, :get, [key], {:error, :not_found})

      IO.puts("  ✓ Concord.Local writes do not replicate or enter the Raft store")
    end

    test "local and cluster APIs keep same key isolated" do
      leader = Cluster.find_leader()
      [local_node | other_nodes] = Cluster.nodes()
      key = unique_key("same-key")

      {:ok, _} = :rpc.call(leader, Concord.Cluster.KV, :put, [key, "cluster-kv"])
      assert :ok = Cluster.wait_replicated(key, {:ok, "cluster-kv"})

      {:ok, _} = :rpc.call(local_node, Concord.Local.KV, :put, [key, "local-kv"])

      assert {:ok, "local-kv"} = :rpc.call(local_node, Concord.Local.KV, :get, [key])
      assert_all_nodes(Concord.Cluster.KV, :get, [key], {:ok, "cluster-kv"})

      for node <- other_nodes do
        assert {:error, :not_found} = :rpc.call(node, Concord.Local.KV, :get, [key])
      end

      IO.puts("  ✓ Same key can hold independent values in local and cluster engines")
    end

    test "turso API persists node-local data without entering Raft" do
      leader = Cluster.find_leader()
      other_nodes = Cluster.nodes() -- [leader]
      key = unique_key("turso")

      assert :ok = :rpc.call(leader, Concord.Turso, :put, [key, "turso-value"])
      assert {:ok, "turso-value"} = :rpc.call(leader, Concord.Turso, :get, [key])

      assert {:ok, %{engine: :turso, storage: %{size: size}}} =
               :rpc.call(leader, Concord.Turso, :status, [])

      assert size >= 1

      assert {:error, :not_found} = :rpc.call(leader, Concord, :get, [key])
      assert {:error, :not_found} = :rpc.call(leader, Concord.Local, :get, [key])

      for node <- other_nodes do
        assert {:error, :not_found} = :rpc.call(node, Concord.Turso, :get, [key])
      end

      assert :ok = restart_turso_pool(leader)
      assert {:ok, "turso-value"} = :rpc.call(leader, Concord.Turso, :get, [key])

      IO.puts("  ✓ Concord.Turso persists local data outside Raft")
    end
  end

  defp assert_all_nodes(module, function, args, expected) do
    results = Cluster.rpc_all(module, function, args)

    assert [
             {_, ^expected},
             {_, ^expected},
             {_, ^expected}
           ] = results
  end

  defp unique_key(prefix) do
    "e2e:engine:#{prefix}:#{System.unique_integer([:positive, :monotonic])}"
  end

  defp restart_turso_pool(node) do
    case :rpc.call(node, Process, :whereis, [Concord.Turso.DB]) do
      pid when is_pid(pid) ->
        :rpc.call(node, Process, :exit, [pid, :kill])
        wait_for_turso_pool(node)

      nil ->
        {:error, :not_started}
    end
  end

  defp wait_for_turso_pool(node, attempts \\ 20)
  defp wait_for_turso_pool(_node, 0), do: {:error, :restart_timeout}

  defp wait_for_turso_pool(node, attempts) do
    case :rpc.call(node, Process, :whereis, [Concord.Turso.DB]) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        Process.sleep(250)
        wait_for_turso_pool(node, attempts - 1)
    end
  end
end
