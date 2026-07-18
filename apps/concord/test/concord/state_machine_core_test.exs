defmodule Concord.StateMachineCoreTest do
  use ExUnit.Case, async: true

  alias Concord.StateMachine.Core
  alias Concord.StateMachine.Core.{Context, State}

  defp context(op_number, timestamp_ms \\ 1_000_000) do
    Context.new!(op_number: op_number, timestamp_ms: timestamp_ms)
  end

  test "independent states do not share key, lease, or index data" do
    {_, first} =
      Core.apply(context(1), {:create_index, "by_kind", {:map_get, :kind}}, Core.init())

    {_, first} = Core.apply(context(2), {:grant_lease, 60, %{}}, first)

    {_, first} =
      Core.apply(
        context(3),
        {:put, "shared", %{kind: :first}, %{lease: 1}},
        first
      )

    {_, second} =
      Core.apply(context(1), {:put, "shared", %{kind: :second}, %{}}, Core.init())

    assert Core.query({:get, "shared"}, first, context(4)) ==
             {:ok, %{kind: :first}}

    assert Core.query({:get, "shared"}, second, context(4)) ==
             {:ok, %{kind: :second}}

    assert Core.query({:index_lookup, "by_kind", :first}, first, context(4)) ==
             {:ok, ["shared"]}

    assert Core.query(:list_indexes, second, context(4)) == {:ok, []}
    assert Core.query(:list_leases, second, context(4)) == {:ok, []}
  end

  test "identical operation sequences produce identical complete states" do
    operations = [
      {:put, "a", "one", %{ttl: 30}},
      {:put_many, [{"b", "two"}, {"c", "three", nil}]},
      {:create_index, "by_value", {:identity}},
      {:reindex, "by_value"},
      {:touch_many, [{"b", 20}]},
      {:delete, "c", %{}}
    ]

    replay = fn ->
      operations
      |> Enum.with_index(1)
      |> Enum.reduce(Core.init(), fn {operation, op_number}, state ->
        {_result, state} = Core.apply(context(op_number), operation, state)
        state
      end)
    end

    assert replay.() == replay.()
  end

  test "transaction reads and TTL decisions use only the replicated timestamp" do
    {_, state} =
      Core.apply(
        context(1, 1_000_000),
        {:put, "ttl", "value", %{ttl: 10}},
        Core.init()
      )

    transaction = %{
      compare: [{:exists, "ttl", :==, true}],
      success: [{:get, {:key, "ttl"}, %{}}],
      failure: []
    }

    {first_result, first_state} =
      Core.apply(context(2, 1_005_000), {:txn, transaction}, state)

    {replayed_result, replayed_state} =
      Core.apply(context(2, 1_005_000), {:txn, transaction}, state)

    assert first_result == replayed_result
    assert first_state == replayed_state

    {expired_result, _state} =
      Core.apply(context(2, 1_011_000), {:txn, transaction}, state)

    assert {:ok, %{succeeded: false}} = expired_result
  end

  test "snapshot round-trip owns all state categories" do
    {_, state} = Core.apply(context(1), {:create_index, "by_value", {:identity}}, Core.init())
    {_, state} = Core.apply(context(2), {:grant_lease, 60, %{}}, state)
    {_, state} = Core.apply(context(3), {:put, "a", "one", %{lease: 1}}, state)
    {_, state} = Core.apply(context(4), {:put, "a", "two", %{}}, state)

    assert {:ok, snapshot} = Core.snapshot(state)
    assert {:ok, restored} = Core.restore(snapshot)
    assert restored == state
    assert map_size(restored.store) == 1
    assert map_size(restored.current) == 1
    assert map_size(restored.history) == 1
    assert map_size(restored.leases) == 1
    assert Map.has_key?(restored.index_entries, "by_value")
  end

  test "restores the complete current v3 snapshot representation" do
    record = %Concord.KV.Record{
      value: "value",
      create_revision: 1,
      mod_revision: 1,
      version: 1
    }

    snapshot =
      {:concord_kv,
       %{
         __snapshot_version__: 3,
         __kv_data__: [{"key", %{value: "value", expires_at: nil}}],
         __current_data__: [{"key", record}],
         __history_data__: [{{"key", 1}, record}],
         __lease_data__: [{7, %{id: 7, ttl: 30, expires_at: 1_030, keys: ["key"]}}],
         __index_ets__: %{"by_value" => [{"value", ["key"]}]},
         indexes: %{"by_value" => {:identity}},
         command_count: 9,
         revision: 1,
         compact_revision: 0,
         next_lease_id: 8
       }}

    assert {:ok, %State{} = restored} = Core.restore(snapshot)
    assert restored.store["key"] == %{value: "value", expires_at: nil}
    assert restored.current["key"] == record
    assert restored.history[{"key", 1}] == record
    assert restored.leases[7].keys == ["key"]
    assert restored.index_entries["by_value"]["value"] == ["key"]
  end

  test "query accepts the timestamp integer used by protocol adapters" do
    {_, state} =
      Core.apply(context(1, 1_000_000), {:put, "key", "value", %{ttl: 10}}, Core.init())

    assert Core.query({:get, "key"}, state, 1_005_000) == {:ok, "value"}
    assert Core.query({:get, "key"}, state, 1_011_000) == {:error, :not_found}
  end
end
