defmodule Concord.StateMachine.StatisticsTest do
  use ExUnit.Case, async: false

  alias Concord.KV.Record
  alias Concord.StateMachine.Core
  alias Concord.StateMachine.Core.{Context, State}

  @store_walks [
    {Core, :representation_conflict_status, 1},
    {Core, :representation_key_consistent?, 2},
    {:erlang, :term_to_binary, 1},
    {:erlang, :term_to_binary, 2},
    {:erlang, :external_size, 1}
  ]

  for count <- [10_000, 100_000] do
    @tag timeout: 60_000
    test "statistics skip #{count} records and their values in current and version-zero states" do
      value = :binary.copy(<<0, 255, 1, 128>>, 128)
      record = %Record{value: value, create_revision: 1, mod_revision: 1, version: 1}
      keys = Enum.map(1..unquote(count), &"fixture/#{&1}")

      assert {:ok, state} =
               Core.restore(%State{
                 store: Map.new(keys, &{&1, %{value: value, expires_at: nil}}),
                 current: Map.new(keys, &{&1, record}),
                 revision: 1
               })

      assert {:ok, conflicts} = Core.restore(Map.to_list(state.store))

      for state <- [
            state,
            elem(Core.apply_legacy(context(2), :reconcile_legacy_state, state), 1),
            conflicts
          ] do
        expected = assert_memory(state)

        {results, calls} =
          profile(fn -> Enum.map(1..20, fn _ -> Core.query(:stats, state, context(3)) end) end)

        assert Enum.all?(results, &(&1 == {:ok, expected}))
        assert Enum.all?(calls, fn {_mfa, count} -> count == 0 end), inspect(calls)
      end
    end
  end

  test "exact ETF memory accounting follows current writes, deletes, transactions, expiry and backup replacement" do
    commands = [
      {:put, "key", :binary.copy(<<0, 255>>, 10_000), %{}},
      {:put, "key", %{number: 1.5, nested: {[:one, 2], <<1::3>>}}, %{}},
      {:touch, "key", 60},
      {:put_many, [{"a", [1 | 2], nil}, {"expired", "old", 999}]},
      {:touch_many, [{"a", 30}]},
      :cleanup_expired,
      {:grant_lease, 60, %{}},
      {:put, "leased", "value", %{lease: 1}},
      {:revoke_lease, 1, %{}},
      {:txn,
       %{
         success: [
           {:put, "transient", "first", %{}},
           {:delete, {:key, "transient"}, %{}},
           {:put, "transient", "last", %{}}
         ]
       }},
      {:put_if, "key", "conditional", nil, %{number: 1.5, nested: {[:one, 2], <<1::3>>}}},
      {:delete_if, "key", "conditional", nil},
      {:delete_many, ["a", "transient", "missing"]},
      {:restore_backup, %{version: 2, kv_data: [{"restored", {"tuple", 500}}], indexes: %{}}},
      {:delete, "restored"}
    ]

    Enum.reduce(Enum.with_index(commands, 1), Core.init(), fn {command, number}, state ->
      {result, state} = Core.apply(context(number), command, state)
      refute match?({:error, _}, result), inspect({command, result})
      assert %{legacy_state_conflict_count: 0} = assert_memory(state)
      assert state.statistics.changes == %{}
      state
    end)
  end

  test "version-zero conditional, batch and expiry quirks retain accurate memory and conflict diagnostics" do
    commands = [
      {{:put, "key", "old", nil}, 0},
      {{:put_if, "key", "new", nil, "old"}, 1},
      {{:touch, "key", 60}, 1},
      {{:delete_if, "key", "new", nil}, 1},
      {{:put_many, [{"key", "batch", nil}, {"new", "new", nil}, {"expired", true, 999}]}, 3},
      {:cleanup_expired, 2},
      {{:delete_many, ["key", "new", "missing"]}, 1},
      {{:restore_backup, [{"raw", {"tuple", 500}}, {"map", %{value: "map", expires_at: nil}}]},
       3},
      {{:delete, "raw"}, 2}
    ]

    Enum.reduce(Enum.with_index(commands, 1), Core.init(), fn {{command, conflicts}, number},
                                                              state ->
      {result, state} = Core.apply_legacy(context(number), command, state)
      refute match?({:error, _}, result), inspect({command, result})
      assert %{legacy_state_conflict_count: ^conflicts} = assert_memory(state)
      assert state.statistics.changes == %{}
      state
    end)
  end

  test "conflict samples advance after deletions and orphan lease removal" do
    keys = Enum.map(1..105, &"key-#{String.pad_leading(Integer.to_string(&1), 3, "0")}")
    assert {:ok, state} = Core.restore(Enum.map(keys, &{&1, &1}))

    assert %{legacy_state_conflict_count: 105, legacy_state_conflicts: sample} =
             assert_memory(state)

    assert sample == Enum.take(keys, 100)

    {_, state} = Core.apply_legacy(context(1), {:delete_many, Enum.take(keys, 10)}, state)

    assert %{legacy_state_conflict_count: 95, legacy_state_conflicts: sample} =
             assert_memory(state)

    assert sample == Enum.drop(keys, 10)

    {_, state} = Core.apply_legacy(context(2), {:grant_lease, 60, %{}}, Core.init())
    {_, state} = Core.apply_legacy(context(3), {:put, "leased", "value", %{lease: 1}}, state)
    {_, state} = Core.apply_legacy(context(4), {:delete, "leased"}, state)

    assert %{legacy_state_conflict_count: 1, legacy_state_conflicts: ["leased"]} =
             assert_memory(state)

    {_, state} = Core.apply_legacy(context(5), {:revoke_lease, 1, %{}}, state)
    assert %{legacy_state_conflict_count: 0, legacy_state_conflicts: []} = assert_memory(state)
  end

  test "every recovery form rebuilds untrusted statistics without persisting derived fields" do
    {_, state} = Core.apply(context(1), {:put, "key", "value", %{}}, Core.init())
    expected = assert_memory(state)
    poisoned = %{state | statistics: %{memory: -1, conflicts: :untrusted, changes: :untrusted}}
    assert {:ok, snapshot} = Core.snapshot(poisoned)
    refute Map.has_key?(snapshot.state, :statistics)

    for source <- [snapshot, poisoned, Map.from_struct(poisoned), Map.from_struct(snapshot.state)] do
      assert {:ok, recovered} = Core.restore(source)
      assert assert_memory(recovered) == expected
      assert recovered.statistics.changes == %{}
      assert {:ok, ^snapshot} = Core.snapshot(recovered)
    end

    assert {:ok, legacy} = Core.restore({:concord_kv, %{store: state.store}})
    assert %{legacy_state_conflict_count: 1} = assert_memory(legacy)

    assert %{legacy_state_conflict_count: 1} =
             assert_memory(Core.from_legacy_tables(Core.init(), %{store: state.store}))
  end

  test "cached healthy statistics never bypass snapshot, restore, command admission or reconciliation validation" do
    {_, state} = Core.apply(context(1), {:put, "key", "original", %{}}, Core.init())

    corrupt = %{
      state
      | store: Map.put(state.store, "key", %{value: "different", expires_at: nil})
    }

    assert {:error, {:invalid_snapshot, {:store_current_mismatch, "key"}}} =
             Core.snapshot(corrupt)

    assert {:error, {:invalid_snapshot, {:store_current_mismatch, "key"}}} =
             Core.restore(%{__concord_snapshot_version__: 4, state: corrupt})

    assert {{:error, {:legacy_state_requires_reconciliation, %{count: 1, sample: ["key"]}}},
            ^corrupt} =
             Core.apply(context(2), {:put, "other", "blocked", %{}}, corrupt)

    assert {{:ok, %{reconciled: 1}}, reconciled} =
             Core.apply(context(2), :reconcile_legacy_state, corrupt)

    assert %{legacy_state_conflict_count: 0, legacy_state_reconciliation_required: false} =
             assert_memory(reconciled)

    assert {:ok, _snapshot} = Core.snapshot(reconciled)
  end

  test "direct command compatibility entry point finalizes derived statistics" do
    {:ok, state} = Core.apply_command(context(1), {:put, "key", "value", nil}, Core.init())
    assert %{legacy_state_conflict_count: 0} = assert_memory(state)
    assert state.statistics.changes == %{}
    {:ok, state} = Core.apply_command(context(2), {:delete, "key"}, state)
    assert %{size: 0, memory: 6, legacy_state_conflict_count: 0} = assert_memory(state)
  end

  defp assert_memory(state) do
    assert {:ok, statistics} = Core.query(:stats, state, context(1))
    assert statistics.memory == byte_size(:erlang.term_to_binary(state.store))
    assert statistics.size == map_size(state.store)
    statistics
  end

  defp profile(operation) do
    session = :trace.session_create(:core_statistics, self(), [])

    try do
      for mfa <- @store_walks, do: 1 = :trace.function(session, mfa, true, [:local, :call_count])
      1 = :trace.process(session, self(), true, [:call, :silent])
      result = operation.()
      1 = :trace.process(session, self(), false, [:call, :silent])

      counts =
        Map.new(@store_walks, fn mfa ->
          {:call_count, count} = :trace.info(session, mfa, :call_count)
          {mfa, count}
        end)

      {result, counts}
    after
      :trace.session_destroy(session)
    end
  end

  defp context(number), do: %Context{op_number: number, timestamp_ms: 1_000_000}
end
