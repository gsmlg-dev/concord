defmodule Concord.StateMachine.IncrementalTransactionTest do
  use ExUnit.Case, async: false

  alias Concord.{CommandEnvelope, StateMachine, StorageScope}
  alias Concord.Engine.VSR.StateMachine, as: Adapter
  alias Concord.StateMachine.{Core, Observer}
  alias Concord.StateMachine.Core.Context
  alias Concord.Sync.Dispatcher
  alias Concord.Txn.Result
  alias ViewstampedReplication.ApplyMetadata

  setup do
    owner = self()

    on_exit(fn ->
      reference = Process.monitor(owner)

      receive do
        {:DOWN, ^reference, :process, ^owner, _reason} -> :ok
      end
    end)

    :ok
  end

  for version <- [0, 1] do
    test "version #{version} returns only affected rows for an atomic put" do
      spec = %{compare: [], success: [{:put, "target", "value", %{}}], failure: []}

      assert {{:ok, %Result{succeeded: true}}, next, changes} =
               Core.apply_with_changes(unquote(version), context(1), {:txn, spec}, Core.init())

      assert Enum.sort(changes) == [current: "target", store: "target"]
      assert next.store["target"].value == "value"
      refute Map.has_key?(next, :__concord_changes__)
    end

    for active <- [false, true] do
      test "version #{version} transaction views and events match full reconstruction with dispatcher #{active}" do
        version = unquote(version)
        active = unquote(active)
        if active, do: Process.register(self(), Dispatcher)

        for size <- [16, 128] do
          initial = fixture(size)

          for {spec, operation} <- Enum.with_index(specifications(), size + 10) do
            assert_adapter(version, {:txn, spec}, initial, operation, active)
          end
        end
      end
    end

    test "version #{version} caches atomic outcomes and retries without new row changes" do
      version = unquote(version)
      initial = fixture(8)

      spec = %{
        idempotency_key: "request",
        compare: [{:exists, "outcome", :==, false}],
        success: [
          {:put, "head", %{tag: "published"}, %{lease: 1}},
          {:put, "outcome", "committed", %{}}
        ],
        failure: [{:put, "failed", "unexpected", %{}}]
      }

      command = {:txn, spec}
      {result, next} = assert_adapter(version, command, initial, 30, false)
      assert {:ok, %Result{succeeded: true} = outcome} = result
      assert %{result: ^outcome, cached_at: 30} = next.requests["request"]
      assert Core.query({:txn_result, "request"}, next, context(31)) == result

      assert {^result, retried, []} = Core.apply_with_changes(version, context(31), command, next)
      assert retried == %{next | command_count: next.command_count + 1}
      assert {^result, ^retried} = assert_adapter(version, command, next, 31, false)

      conflicting = {:txn, put_in(spec, [:success], [{:put, "head", "conflict", %{}}])}

      assert {{:error, :idempotency_conflict}, conflicted, []} =
               Core.apply_with_changes(version, context(32), conflicting, next)

      assert conflicted == %{next | command_count: next.command_count + 1}
      assert_adapter(version, conflicting, next, 32, false)

      assert {:ok, snapshot} = Adapter.snapshot(retried)
      refute Map.has_key?(snapshot.state, :__concord_changes__)
      assert {:ok, restored} = Adapter.restore(snapshot)
      assert {:ok, ^snapshot} = Adapter.snapshot(restored)
      assert Core.query({:txn_result, "request"}, restored, context(33)) == result
      assert_views(restored)
    end
  end

  test "current transaction admission and missing leases preserve atomic refusal" do
    initial = fixture(8)

    spec = %{
      idempotency_key: "refused",
      success: [
        {:put, "first", "must not commit", %{}},
        {:put, "second", "must not commit", %{lease: 99}}
      ]
    }

    assert {{:error, :lease_not_found}, refused, []} =
             Core.apply_with_changes(1, context(30), {:txn, spec}, initial)

    assert refused == %{initial | command_count: initial.command_count + 1}
    assert_adapter(1, {:txn, spec}, initial, 30, false)

    invalid = {:txn, %{success: [{:put, "first", "value", %{}}, :unsupported]}}

    assert {{:error, :unsupported_command}, ^initial, []} =
             Core.apply_with_changes(1, context(31), invalid, initial)

    assert_adapter(1, invalid, initial, 31, false)

    {:ok, legacy} =
      Core.apply_legacy(
        context(32),
        {:put_if, "fixture-1", "legacy", nil, %{tag: "tag-1"}},
        initial
      )

    assert {{:error, {:legacy_state_requires_reconciliation, %{count: 1}}}, ^legacy, []} =
             Core.apply_with_changes(1, context(33), {:txn, spec}, legacy)

    assert_adapter(1, {:txn, spec}, legacy, 33, false)
  end

  test "legacy transactions retain frozen unsupported-operation and lease behavior" do
    initial = fixture(8)

    spec = %{
      success: [
        {:put, "first", "committed", %{lease: 99}},
        :unsupported,
        {:put, "outcome", "committed", %{}}
      ]
    }

    assert {{:ok, %Result{responses: [_, {:error, :unsupported_op}, _]}}, next} =
             assert_adapter(0, {:txn, spec}, initial, 30, false)

    assert next.store["first"].value == "committed"
    assert next.store["outcome"].value == "committed"
  end

  test "legacy numeric key selectors retain equality and delete every matching key" do
    {:ok, initial} = Core.apply_legacy(context(1), {:put, 1, "integer"}, Core.init())
    {:ok, initial} = Core.apply_legacy(context(2), {:put, 1.0, "float"}, initial)
    command = {:txn, %{success: [{:delete, {:key, 1}, %{}}]}}
    expected = Core.apply_legacy(context(3), command, initial)

    assert {result, next, changes} = Core.apply_with_changes(0, context(3), command, initial)
    assert {result, next} == expected
    assert {:ok, %Result{responses: [{:delete, {:key, 1}, %{deleted: 2}}]}} = result
    assert next.current == %{}
    assert next.store == %{}
    assert {:current, 1} in changes
    assert {:current, 1.0} in changes
  end

  test "transactions bootstrap missing compatibility and untouched index views" do
    initial = fixture(8)
    command = {:txn, %{success: [{:get, {:key, "fixture-1"}, %{}}]}}

    for version <- [0, 1] do
      :ok = StateMachine.materialize(initial)
      :ets.delete(StorageScope.table(:history))
      expected = apply_core(version, context(30), command, initial)

      assert ^expected =
               Adapter.apply(metadata(30), CommandEnvelope.wrap(1_000, command, version), initial)

      {_, next} = expected
      assert_views(next)
      :ok = StateMachine.materialize(initial)
      :ets.delete(StorageScope.index_table_name("tags"))

      assert ^expected =
               Adapter.apply(metadata(30), CommandEnvelope.wrap(1_000, command, version), initial)

      assert_views(next)
    end
  end

  test "fixed atomic writes avoid growing complete adapter overhead" do
    command =
      {:txn,
       %{
         compare: [{:exists, "outcome", :==, false}],
         success: [
           {:put, "head", "tiny", %{}},
           {:delete, {:key, "fixture-1"}, %{}},
           {:put, "outcome", "committed", %{}}
         ],
         failure: []
       }}

    for active <- [false, true] do
      if active, do: Process.register(self(), Dispatcher)

      rows =
        for size <- [128, 2_048], version <- [0, 1] do
          initial = fixture(size)
          :ok = StateMachine.materialize(initial)
          expected = apply_core(version, context(size + 1), command, initial)
          envelope = CommandEnvelope.wrap(1_000, command, version)
          adapter = fn -> Adapter.apply(metadata(size + 1), envelope, initial) end
          core = fn -> apply_core(version, context(size + 1), command, initial) end
          {size, version, measure(adapter, expected), measure(core, expected)}
        end

      for version <- [0, 1] do
        [{_, _, small, small_core}, {_, _, large, large_core}] =
          Enum.filter(rows, fn {_, candidate, _, _} -> candidate == version end)

        assert large - large_core < (small - small_core) * 4 + 1_500,
               "growing atomic adapter overhead: #{inspect({active, rows})}"

        if version == 0 do
          assert large < small * 4 + 1_500,
                 "growing complete legacy transaction cost: #{inspect({active, rows})}"
        end
      end

      if active, do: Process.unregister(Dispatcher)
    end
  end

  defp specifications do
    [
      %{
        compare: [{:exists, "fixture-1", :==, true}],
        success: [
          {:put, "new", %{tag: ["a", "b"]}, %{lease: 1, prev_kv: true}},
          {:put, "fixture-1", %{tag: "changed"}, %{lease: 2, prev_kv: true}},
          {:delete, {:key, "fixture-2"}, %{prev_kv: true}},
          {:touch, "fixture-3", 10, %{}},
          {:put, "outcome", "committed", %{}}
        ],
        failure: [{:put, "wrong-branch", "must not commit", %{}}]
      },
      %{
        compare: [{:exists, "missing", :==, true}],
        success: [{:put, "wrong-branch", "must not commit", %{}}],
        failure: [
          {:put, "failure", %{tag: "failure"}, %{}},
          {:delete, {:range, "fixture-2", "fixture-4"}, %{prev_kv: true}}
        ]
      },
      %{
        success: [
          {:delete, {:key, "fixture-1"}, %{}},
          {:put, "fixture-1", %{tag: "restored"}, %{}},
          {:put, "fixture-1", %{tag: "final"}, %{prev_kv: true}},
          {:get, {:key, "fixture-1"}, %{}}
        ]
      },
      %{
        success: [
          {:put, "temporary", %{tag: "temporary"}, %{}},
          {:delete, {:key, "temporary"}, %{}}
        ]
      },
      %{success: [{:delete, {:prefix, "fixture-1"}, %{prev_kv: true}}]},
      %{success: [{:get, {:key, "fixture-1"}, %{}}, {:get, {:prefix, "fixture-"}, %{limit: 2}}]},
      %{success: [{:delete, {:key, "missing"}, %{}}, {:touch, "missing", 10, %{}}]},
      %{compare: [{:exists, "missing", :==, true}], success: [], failure: []},
      %{compare: [], success: [], failure: []}
    ]
  end

  defp assert_adapter(version, command, initial, operation, active) do
    expected = apply_core(version, context(operation), command, initial)
    {result, next} = expected

    assert {^result, ^next, changes} =
             Core.apply_with_changes(version, context(operation), command, initial)

    assert is_list(changes)
    refute Map.has_key?(next, :__concord_changes__)
    assert_changed_rows(initial, next, changes)
    :ok = StateMachine.materialize(initial)

    assert ^expected =
             Adapter.apply(
               metadata(operation),
               CommandEnvelope.wrap(1_000, command, version),
               initial
             )

    assert_views(next)

    if active do
      events = take_events()

      Observer.committed(
        context(operation),
        command,
        initial,
        next,
        {:vsr, :transaction_delta_test}
      )

      assert events == take_events()
    else
      assert Process.whereis(Dispatcher) == nil
    end

    expected
  end

  defp assert_changed_rows(previous, current, changes) do
    tables = [:store, :current, :history, :leases]

    for table <- tables do
      assert_changed_entries(
        Map.fetch!(previous, table),
        Map.fetch!(current, table),
        table,
        changes
      )
    end

    for {name, entries} <- current.index_entries do
      assert_changed_entries(
        Map.get(previous.index_entries, name, %{}),
        entries,
        {:index, name},
        changes
      )
    end
  end

  defp assert_changed_entries(previous, current, table, changes) do
    for key <- Enum.uniq(Map.keys(previous) ++ Map.keys(current)),
        Map.fetch(previous, key) != Map.fetch(current, key) do
      assert {table, key} in changes
    end
  end

  defp assert_views(state) do
    for name <- [:store, :current, :history, :leases] do
      assert Map.new(:ets.tab2list(StorageScope.table(name))) == Map.fetch!(state, name)
    end

    for {name, entries} <- state.index_entries do
      assert Map.new(:ets.tab2list(StorageScope.index_table_name(name))) == entries
    end
  end

  defp measure(operation, expected) do
    samples =
      for _ <- 1..5 do
        :erlang.garbage_collect(self())
        {:reductions, before_count} = Process.info(self(), :reductions)
        result = operation.()
        {:reductions, after_count} = Process.info(self(), :reductions)
        assert result == expected
        take_events()
        after_count - before_count
      end

    samples |> Enum.sort() |> Enum.at(2)
  end

  defp fixture(size) do
    {:ok, state} =
      Core.apply_legacy(context(0), {:create_index, "tags", {:map_get, :tag}}, Core.init())

    {{:ok, _}, state} = Core.apply_legacy(context(0), {:grant_lease, 100, %{}}, state)
    {{:ok, _}, state} = Core.apply_legacy(context(0), {:grant_lease, 100, %{}}, state)

    state =
      Enum.reduce(1..size, state, fn number, acc ->
        {:ok, acc} =
          Core.apply_legacy(
            context(number),
            {:put, "fixture-#{number}", %{tag: "tag-#{number}"}},
            acc
          )

        acc
      end)

    {%{revision: _revision}, state} =
      Core.apply_legacy(
        context(size + 1),
        {:put, "fixture-1", %{tag: "tag-1"}, %{lease: 1}},
        state
      )

    {{:ok, _}, state} = Core.apply(context(size + 2), :reconcile_legacy_state, state)
    state
  end

  defp take_events do
    receive do
      {:"$gen_cast", {:dispatch, events}} -> events
    after
      0 -> []
    end
  end

  defp apply_core(0, context, command, state), do: Core.apply_legacy(context, command, state)
  defp apply_core(1, context, command, state), do: Core.apply(context, command, state)
  defp context(operation), do: %Context{op_number: operation, timestamp_ms: 1_000}

  defp metadata(operation),
    do: %ApplyMetadata{
      group_id: :transaction_delta_test,
      view_number: 0,
      op_number: operation,
      client_id: :test,
      request_number: operation
    }
end
