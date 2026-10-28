defmodule Concord.E2E.RevisionCASClusterTest do
  use ExUnit.Case, async: false

  alias Concord.E2E.Cluster

  @moduletag :e2e
  @moduletag timeout: 120_000

  test "large CAS survives primary failover and a durable three-node restart" do
    nodes = Cluster.nodes()
    assert {:ok, primary} = wait_for_primary(nodes)
    key = "e2e:cas:durable"
    original = String.duplicate("screenshot-history", 120_000)
    updated = original <> "after failover"

    assert {:ok, %{succeeded: true, revision: first}} =
             :rpc.call(primary, Concord, :compare_and_swap, [
               key,
               original,
               [mod_revision: 0, compress: false]
             ])

    assert :ok = Cluster.wait_replicated(key, {:ok, original})

    :erpc.cast(primary, System, :stop, [0])
    assert :ok = eventually(fn -> Node.ping(primary) == :pang end)
    remaining = nodes -- [primary]
    assert {:ok, replacement} = wait_for_primary(remaining)
    refute replacement == primary

    assert {:ok, %{succeeded: true, revision: committed}} =
             :rpc.call(
               replacement,
               Concord,
               :compare_and_swap,
               [key, updated, [mod_revision: first]],
               30_000
             )

    restart(primary)
    assert :ok = Cluster.wait_replicated(key, {:ok, updated}, 30_000)

    for node <- nodes, do: :erpc.cast(node, System, :stop, [0])
    assert :ok = eventually(fn -> Enum.all?(nodes, &(Node.ping(&1) == :pang)) end)
    Enum.each(nodes, &restart/1)
    assert {:ok, replay_primary} = wait_for_primary(nodes)
    assert :ok = Cluster.wait_replicated(key, {:ok, updated}, 30_000)

    for node <- nodes do
      assert {:ok, %{command_version: 2}} = :rpc.call(node, Concord, :status, [])

      assert {:ok, %{mod_revision: ^committed}} =
               :rpc.call(node, Concord.KV, :get, [key, [metadata: true]])

      assert {:ok, ^original} = :rpc.call(node, Concord.KV, :get, [key, [revision: first]])
    end

    assert {:ok, %{succeeded: false, revision: ^committed, current_kv: %{value: nil}}} =
             :rpc.call(replay_primary, Concord, :compare_and_swap, [
               key,
               :stale,
               [mod_revision: first]
             ])
  end

  defp restart(node) do
    {output, status} =
      System.cmd(
        "bash",
        [
          Path.expand("../scripts/restart_node.sh", __DIR__),
          System.fetch_env!("E2E_RELEASE_BIN"),
          System.fetch_env!("E2E_DATA_BASE"),
          System.fetch_env!("E2E_COOKIE"),
          Atom.to_string(node)
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp wait_for_primary(nodes) do
    deadline = System.monotonic_time(:millisecond) + 30_000
    wait_for_primary(nodes, deadline)
  end

  defp wait_for_primary(nodes, deadline) do
    Enum.each(nodes, &Node.connect/1)

    case Cluster.find_primary(nodes) do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(200)
          wait_for_primary(nodes, deadline)
        else
          {:error, :timeout}
        end

      primary ->
        {:ok, primary}
    end
  end

  defp eventually(function) do
    deadline = System.monotonic_time(:millisecond) + 30_000
    eventually(function, deadline)
  end

  defp eventually(function, deadline) do
    cond do
      function.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(200)
        eventually(function, deadline)
    end
  end
end
