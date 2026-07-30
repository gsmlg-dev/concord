defmodule Concord.StateMachine.CoreConsistencyTest do
  use ExUnit.Case, async: true

  alias Concord.CommandEnvelope
  alias Concord.Engine.VSR.StateMachine, as: VSRStateMachine
  alias Concord.KV.Record
  alias Concord.StateMachine.Core
  alias Concord.StateMachine.Core.Context
  alias ViewstampedReplication.ApplyMetadata

  defp context(op_number, timestamp_ms \\ 1_000_000) do
    Context.new!(op_number: op_number, timestamp_ms: timestamp_ms)
  end

  defp metadata(op_number) do
    %ApplyMetadata{
      group_id: :core_consistency,
      view_number: 0,
      op_number: op_number,
      client_id: :client,
      request_number: op_number
    }
  end

  test "version-one conditional mutations keep legacy and MVCC views coherent" do
    {_, state} = Core.apply(context(1), {:put, "key", "a", nil}, Core.init())
    {:ok, state} = Core.apply(context(2), {:put_if, "key", "b", nil, "a"}, state)

    assert state.revision == 2
    assert state.store["key"] == %{value: "b", expires_at: nil}
    assert %Record{value: "b", mod_revision: 2, version: 2} = state.current["key"]
    assert {:ok, "b"} = Core.query({:get, "key"}, state, context(2))
    assert {:ok, %Record{value: "b"}} = Core.query({:get_record, "key"}, state, context(2))

    {:ok, state} = Core.apply(context(3), {:touch, "key", 60}, state)
    assert state.revision == 3
    assert state.store["key"].expires_at == 1_060
    assert state.current["key"].expires_at == 1_060

    {:ok, state} = Core.apply(context(4), {:delete_if, "key", "b", nil}, state)
    assert state.revision == 4
    refute Map.has_key?(state.store, "key")
    refute Map.has_key?(state.current, "key")
    assert %Record{version: 0, mod_revision: 4} = state.history[{"key", 4}]
  end

  test "version-one bulk and expiry commands use one revision and update both views" do
    assert {{:ok, _results}, state} =
             Core.apply(
               context(1),
               {:put_many, [{"a", 1, 999}, {"b", 2, nil}]},
               Core.init()
             )

    assert state.revision == 1
    assert state.current["a"].mod_revision == 1
    assert state.current["b"].mod_revision == 1
    assert_consistent(state)

    assert {{:ok, _results}, state} =
             Core.apply(context(2), {:touch_many, [{"a", 30}, {"b", 40}]}, state)

    assert state.revision == 2
    assert state.current["a"].mod_revision == 2
    assert state.current["b"].mod_revision == 2
    assert_consistent(state)

    assert {{:ok, _results}, state} = Core.apply(context(3), {:delete_many, ["b"]}, state)
    assert state.revision == 3
    refute Map.has_key?(state.current, "b")
    refute Map.has_key?(state.store, "b")

    {_, state} = Core.apply(context(4), {:put, "expired", 3, 999}, state)
    assert {{:ok, 1}, state} = Core.apply(context(5), :cleanup_expired, state)
    assert state.revision == 5
    refute Map.has_key?(state.current, "expired")
    refute Map.has_key?(state.store, "expired")
    assert_consistent(state)
  end

  test "version-one transaction range reads break revision ties by key" do
    assert {{:ok, _results}, state} =
             Core.apply(
               context(1),
               {:put_many, [{"key/z", "z"}, {"key/a", "a"}, {"key/m", "m"}]},
               Core.init()
             )

    transaction = %{
      compare: [],
      success: [{:get, {:prefix, "key/"}, %{limit: 1000}}],
      failure: []
    }

    assert {{:ok, %Concord.Txn.Result{responses: [response]}}, _state} =
             Core.apply(context(2), {:txn, transaction}, state)

    assert {:get, {:prefix, "key/"}, %{kvs: records, count: 3}} = response
    assert Enum.map(records, & &1.value) == ["a", "m", "z"]
    assert Enum.uniq(Enum.map(records, & &1.mod_revision)) == [1]
  end

  test "version-one transaction delete followed by put has one coherent final revision" do
    {_, state} = Core.apply(context(1), {:put, "key", "old", %{}}, Core.init())

    transaction = %{
      success: [
        {:delete, {:key, "key"}, %{}},
        {:put, "key", "new", %{}}
      ]
    }

    assert {{:ok, %Concord.Txn.Result{revision: 2}}, state} =
             Core.apply(context(2), {:txn, transaction}, state)

    assert %Record{value: "new", mod_revision: 2} = state.current["key"]
    assert %Record{value: "old", mod_revision: 1} = state.history[{"key", 1}]
    refute Map.has_key?(state.history, {"key", 2})
    assert {:ok, "new"} = Core.query({:get, "key", revision: 2}, state, context(3))

    assert {:ok, [%Record{value: "old"}, %Record{value: "new"}]} =
             Core.query({:history, "key", from_revision: 1}, state, context(3))
  end

  test "version-one transactional touch preserves the prior revision" do
    {_, state} = Core.apply(context(1), {:put, "key", "value", %{}}, Core.init())
    transaction = %{success: [{:touch, "key", 60, %{}}]}

    assert {{:ok, %Concord.Txn.Result{revision: 2}}, state} =
             Core.apply(context(2), {:txn, transaction}, state)

    assert %Record{mod_revision: 1, expires_at: nil} = state.history[{"key", 1}]
    assert %Record{mod_revision: 2, expires_at: 1_060} = state.current["key"]
    assert {:ok, "value"} = Core.query({:get, "key", revision: 1}, state, context(3))
  end

  test "version zero replay keeps its store-only quirks until explicit reconciliation" do
    {_, state} = Core.apply_legacy(context(1), {:put, "key", "a", nil}, Core.init())
    {:ok, state} = Core.apply_legacy(context(2), {:put_if, "key", "b", nil, "a"}, state)

    assert state.representation == :legacy
    assert state.store["key"].value == "b"
    assert state.current["key"].value == "a"

    assert {:ok,
            %{
              legacy_state_conflict_count: 1,
              legacy_state_conflicts: ["key"],
              legacy_state_reconciliation_required: true
            }} = Core.query(:stats, state, context(3))

    assert {{:error, {:legacy_state_requires_reconciliation, %{count: 1}}}, ^state} =
             Core.apply(context(3), {:put, "other", "blocked", nil}, state)

    assert {:ok, replayed} = Core.apply_legacy(context(3), :reconcile_legacy_state, state)
    assert replayed.store == state.store
    assert replayed.current == state.current
    assert replayed.representation == :legacy

    assert {{:ok, %{reconciled: 1, revision: 2}}, reconciled} =
             Core.apply(context(4), :reconcile_legacy_state, replayed)

    assert reconciled.representation == :current
    assert reconciled.store["key"].value == "b"
    assert reconciled.current["key"].value == "b"
    assert_consistent(reconciled)

    {_, upgraded} = Core.apply(context(5), {:put, "other", "accepted", nil}, reconciled)
    assert {:ok, snapshot} = Core.snapshot(upgraded)
    assert {:ok, ^upgraded} = Core.restore(snapshot)
  end

  test "versioned envelopes enforce reconciliation while version zero keeps the atom as a no-op" do
    put = CommandEnvelope.wrap(1_000, {:put, "key", "a", nil}, 0)
    put_if = CommandEnvelope.wrap(1_001, {:put_if, "key", "b", nil, "a"}, 0)

    assert {:ok, state} = VSRStateMachine.apply(metadata(1), put, Core.init())
    assert {:ok, state} = VSRStateMachine.apply(metadata(2), put_if, state)

    assert {:ok, legacy_noop} =
             VSRStateMachine.apply(
               metadata(3),
               CommandEnvelope.wrap(1_002, :reconcile_legacy_state, 0),
               state
             )

    assert legacy_noop.store == state.store
    assert legacy_noop.current == state.current

    assert {{:error, {:legacy_state_requires_reconciliation, %{count: 1}}}, blocked} =
             VSRStateMachine.apply(
               metadata(4),
               CommandEnvelope.wrap(1_003, {:put, "blocked", true, nil}, 1),
               legacy_noop
             )

    assert blocked == legacy_noop

    assert {{:ok, %{reconciled: 1}}, reconciled} =
             VSRStateMachine.apply(
               metadata(5),
               CommandEnvelope.wrap(1_004, :reconcile_legacy_state, 1),
               blocked
             )

    assert_consistent(reconciled)
  end

  test "legacy indexes must be dropped before reconciliation and recreated afterward" do
    assert {:ok, state} =
             Core.apply_legacy(
               context(1),
               {:create_index, :legacy_name, {:identity}},
               Core.init()
             )

    assert {{:error, {:legacy_indexes_require_migration, [:legacy_name]}}, ^state} =
             Core.apply(context(2), :reconcile_legacy_state, state)

    assert {:ok, state} = Core.apply(context(2), {:drop_index, :legacy_name}, state)

    assert {{:error, {:legacy_state_requires_reconciliation, _status}}, ^state} =
             Core.apply(context(3), {:create_index, "current-name", {:identity}}, state)

    assert {{:ok, %{reconciled: 0}}, state} =
             Core.apply(context(3), :reconcile_legacy_state, state)

    assert {:ok, state} =
             Core.apply(context(4), {:create_index, "current-name", {:identity}}, state)

    assert :ok = Core.snapshot(state) |> elem(0)
  end

  test "current writes detach stale lease membership before delete or reassignment" do
    {_, state} = Core.apply(context(1), {:grant_lease, 60, %{}}, Core.init())
    {_, state} = Core.apply(context(2), {:grant_lease, 60, %{}}, state)
    {_, state} = Core.apply(context(3), {:put, "leased", "first", %{lease: 1}}, state)

    {_, state} = Core.apply(context(4), {:put, "leased", "second", %{lease: 2}}, state)
    refute "leased" in state.leases[1].keys
    assert "leased" in state.leases[2].keys

    {_, state} = Core.apply(context(5), {:delete, "leased"}, state)
    refute "leased" in state.leases[2].keys

    {_, state} = Core.apply(context(6), {:put, "leased", "recreated", %{}}, state)
    {_, state} = Core.apply(context(7), {:revoke_lease, 2, %{}}, state)

    assert {:ok, "recreated"} = Core.query({:get, "leased"}, state, context(8))

    assert {:ok, %Record{lease_id: nil}} =
             Core.query({:get_record, "leased"}, state, context(8))
  end

  test "current direct and transactional writes reject missing leases atomically" do
    state = Core.init()

    assert {{:error, :lease_not_found}, direct_state} =
             Core.apply(context(1), {:put, "direct", "value", %{lease: 99}}, state)

    assert direct_state == %{state | command_count: 1}

    transaction = %{
      success: [
        {:put, "first", "value", %{}},
        {:put, "missing-lease", "value", %{lease: 99}}
      ]
    }

    assert {{:error, :lease_not_found}, transaction_state} =
             Core.apply(context(2), {:txn, transaction}, state)

    assert transaction_state == %{state | command_count: 1}
  end

  test "reconciliation repairs stale lease membership and deterministically rebuilds indexes" do
    {_, state} = Core.apply_legacy(context(1), {:grant_lease, 60, %{}}, Core.init())
    {_, state} = Core.apply_legacy(context(2), {:put, "key", "old", %{lease: 1}}, state)
    {_, state} = Core.apply_legacy(context(3), {:delete, "key"}, state)
    {_, state} = Core.apply_legacy(context(4), {:put, "key", "new", %{}}, state)

    assert state.store["key"].value == "new"
    assert state.current["key"].lease_id == nil
    assert "key" in state.leases[1].keys

    assert {{:ok, %{reconciled: 1}}, state} =
             Core.apply(context(5), :reconcile_legacy_state, state)

    assert state.leases[1].keys == []
    assert state.representation == :current
    assert {:ok, snapshot} = Core.snapshot(state)
    assert {:ok, ^state} = Core.restore(snapshot)
  end

  test "zero-conflict reconciliation still rebuilds derived indexes" do
    {_, state} = Core.apply_legacy(context(1), {:put, "key", "value", nil}, Core.init())

    state = %{
      state
      | indexes: %{"by-value" => {:identity}},
        index_entries: %{"by-value" => %{"stale" => ["key"]}}
    }

    assert {:ok, %{legacy_state_conflict_count: 0}} = Core.query(:stats, state, context(2))

    assert {{:ok, %{reconciled: 0, revision: 1}}, state} =
             Core.apply(context(2), :reconcile_legacy_state, state)

    assert state.index_entries == %{"by-value" => %{"value" => ["key"]}}
    assert state.representation == :current
  end

  test "importing legacy ETS data marks the resulting representation for reconciliation" do
    state =
      Core.from_legacy_tables(Core.init(), %{
        store: [{"legacy", %{value: "value", expires_at: nil}}]
      })

    assert state.representation == :legacy

    assert {:ok, %{legacy_state_reconciliation_required: true}} =
             Core.query(:stats, state, context(1))
  end

  test "version-four states without a representation marker restore as legacy" do
    assert {:ok, snapshot} = Core.snapshot(Core.init())
    historical_state = Map.delete(snapshot.state, :representation)
    historical_snapshot = %{snapshot | state: historical_state}

    assert {:ok, restored} = Core.restore(historical_snapshot)
    assert restored.representation == :legacy
  end

  test "status bounds and deterministically orders the representation conflict sample" do
    keys = Enum.map(1..105, &"key-#{String.pad_leading(Integer.to_string(&1), 3, "0")}")

    state = %{
      Core.init()
      | representation: :legacy,
        store: Map.new(keys, &{&1, %{value: &1, expires_at: nil}})
    }

    assert {:ok,
            %{
              legacy_state_conflict_count: 105,
              legacy_state_conflicts: sample
            }} = Core.query(:stats, state, context(1))

    assert length(sample) == 100
    assert sample == Enum.take(keys, 100)
  end

  test "backup restore creates a coherent current revision that remains readable" do
    {_, state} = Core.apply(context(1), {:put, "old", "value", nil}, Core.init())

    backup = %{
      version: 2,
      kv_data: [{"new", %{value: "restored", expires_at: nil}}],
      indexes: %{}
    }

    assert {:ok, restored} = Core.apply_command(context(2), {:restore_backup, backup}, state)
    assert restored.revision == 2
    assert restored.compact_revision == 1
    assert {:ok, "restored"} = Core.query({:get, "new", revision: 2}, restored, context(3))

    assert {:error, {:compacted, 1}} =
             Core.query({:get, "new", revision: 1}, restored, context(3))

    assert_consistent(restored)
  end

  defp assert_consistent(state) do
    assert Map.keys(state.store) |> Enum.sort() == Map.keys(state.current) |> Enum.sort()

    Enum.each(state.current, fn {key, record} ->
      assert state.store[key] == %{value: record.value, expires_at: record.expires_at}
    end)
  end
end
