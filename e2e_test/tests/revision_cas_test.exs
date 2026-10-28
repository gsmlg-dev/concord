defmodule Concord.E2E.RevisionCASTest do
  use ExUnit.Case, async: false

  alias Concord.E2E.Cluster

  @moduletag :e2e

  test "writer2 CAS admits large histories and exactly one competing revision" do
    primary = Cluster.find_primary()
    assert {:ok, %{command_version: 2}} = :rpc.call(primary, Concord, :status, [])
    key = "e2e:cas:history"
    value = String.duplicate("large history你好", 130_000)

    assert {:ok, %{succeeded: true, revision: revision, current_kv: %{value: nil}}} =
             :rpc.call(primary, Concord, :compare_and_swap, [
               key,
               value,
               [mod_revision: 0, compress: false]
             ])

    assert :ok = Cluster.wait_replicated(key, {:ok, value})

    results =
      1..8
      |> Enum.map(fn i ->
        Task.async(fn ->
          :rpc.call(
            primary,
            Concord,
            :compare_and_swap,
            [key, {i, value}, [mod_revision: revision]],
            30_000
          )
        end)
      end)
      |> Task.await_many(30_000)

    assert [{:ok, %{succeeded: true, revision: next_revision}}] =
             Enum.filter(results, &match?({:ok, %{succeeded: true}}, &1))

    assert next_revision == revision + 1

    assert Enum.count(results, &match?({:ok, %{succeeded: false, current_kv: %{value: nil}}}, &1)) ==
             7

    assert {:ok, {winner, ^value}} = :rpc.call(primary, Concord, :get, [key])
    assert winner in 1..8
    assert :ok = Cluster.wait_replicated(key, {:ok, {winner, value}})
    assert {:ok, ^value} = :rpc.call(primary, Concord.KV, :get, [key, [revision: revision]])

    assert {:error, {:invalid_txn, :spec_too_large}} =
             :rpc.call(primary, Concord.KV, :update_if, [
               key,
               value,
               [mod_revision: next_revision]
             ])
  end
end
