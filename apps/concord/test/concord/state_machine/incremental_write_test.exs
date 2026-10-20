defmodule Concord.StateMachine.IncrementalWriteTest do
  use ExUnit.Case, async: false

  alias Concord.{CommandEnvelope, StateMachine, StorageScope}
  alias Concord.Engine.VSR.StateMachine, as: Adapter
  alias Concord.StateMachine.{Core, Observer}
  alias Concord.StateMachine.Core.Context
  alias Concord.Sync.Dispatcher
  alias ViewstampedReplication.ApplyMetadata

  for version <- [0, 1], active <- [false, true] do
    test "version #{version} preserves full views and events with dispatcher #{active}" do
      version = unquote(version)
      active = unquote(active)
      if active, do: Process.register(self(), Dispatcher)

      for size <- [16, 128] do
        initial = fixture(size)

        commands = [
          {:put, "new", %{tag: ["a", "b"]}},
          {:put, "fixture-1", %{tag: "changed"}, %{lease: 1, prev_kv: true}},
          {:put, "fixture-1", %{tag: "unleased"}, nil},
          {:delete, "fixture-2", %{prev_kv: true}},
          {:delete, "missing"},
          {:put_if, "fixture-1", %{tag: "conditional"}, nil, %{tag: "tag-1"}},
          {:put_if, "fixture-1", "no change", nil, :wrong},
          {:delete_if, "fixture-1", %{tag: "tag-1"}, nil},
          {:touch, "fixture-1", 10},
          {:touch, "missing", 10}
        ]

        for {command, op} <- Enum.with_index(commands, size + 10) do
          expected = apply_core(version, context(op), command, initial)
          {_, next} = expected
          :ok = StateMachine.materialize(initial)

          assert ^expected =
                   Adapter.apply(
                     metadata(op),
                     CommandEnvelope.wrap(1_000, command, version),
                     initial
                   )

          refute Map.has_key?(next, :__concord_changes__)
          assert_views(next)

          if active do
            actual_events = take_events()
            Observer.committed(context(op), command, initial, next, {:vsr, :incremental_test})
            assert actual_events == take_events()
          else
            assert Process.whereis(Dispatcher) == nil
          end
        end
      end
    end
  end

  test "bulk fallback retains lexical event order and snapshot bootstrap" do
    Process.register(self(), Dispatcher)
    initial = fixture(8)
    :ok = StateMachine.materialize(initial)
    command = {:delete_many, ["fixture-8", "fixture-2", "fixture-1"]}
    {_, next} = Adapter.apply(metadata(30), CommandEnvelope.wrap(1_000, command, 1), initial)

    assert [first, second, third] = take_events()
    assert {first.key, second.key, third.key} == {"fixture-1", "fixture-2", "fixture-8"}

    assert Enum.map([first, second, third], & &1.id) ==
             Enum.map(0..2, &{{:vsr, :incremental_test}, 30, &1})

    assert_views(next)

    assert {:ok, snapshot} = Adapter.snapshot(next)
    refute Map.has_key?(snapshot.state, :__concord_changes__)
    :ok = StateMachine.materialize(Core.init())
    assert {:ok, restored} = Adapter.restore(snapshot)
    # Restore rebuilds derived listing trees; their balancing is not snapshot state.
    assert {:ok, ^snapshot} = Adapter.snapshot(restored)

    for revision <- [nil, 2, initial.revision, next.revision],
        selector <- [{:prefix, "fixture-"}, {:range, "fixture-2", "fixture-8"}],
        limit <- [2, 20] do
      query = {:list, selector, %{revision: revision, limit: limit}}
      assert {:ok, _records, _page} = expected = Core.query(query, next, context(30))
      assert Core.query(query, restored, context(30)) == expected
    end

    for query <- [
          {:get, "fixture-3"},
          {:get, "fixture-1", revision: 2},
          {:history, "fixture-1", from_revision: 1},
          {:index_lookup, "tags", "tag-3"}
        ] do
      assert {:ok, _value} = expected = Core.query(query, next, context(30))
      assert Core.query(query, restored, context(30)) == expected
    end

    assert_views(next)
  end

  test "missing compatibility and index tables bootstrap from authoritative state" do
    initial = fixture(8)
    :ok = StateMachine.materialize(initial)
    :ets.delete(StorageScope.table(:history))

    {_, next} =
      Adapter.apply(
        metadata(30),
        CommandEnvelope.wrap(1_000, {:put, "new", %{tag: "new"}}, 1),
        initial
      )

    assert_views(next)

    :ets.delete(StorageScope.index_table_name("tags"))

    {_, next} =
      Adapter.apply(
        metadata(31),
        CommandEnvelope.wrap(1_000, {:put, "new", %{tag: "other"}}, 1),
        next
      )

    assert_views(next)
  end

  test "rejected current writes retain conflict refusal without transient metadata" do
    initial = fixture(8)

    {:ok, legacy} =
      Core.apply_legacy(
        context(20),
        {:put_if, "fixture-1", "legacy", nil, %{tag: "tag-1"}},
        initial
      )

    :ok = StateMachine.materialize(legacy)
    command = {:put, "other", "blocked"}

    assert {{:error, {:legacy_state_requires_reconciliation, %{count: 1}}}, ^legacy} =
             Adapter.apply(metadata(30), CommandEnvelope.wrap(1_000, command, 1), legacy)

    assert_views(legacy)
  end

  test "fixed writes avoid growing adapter overhead with absent and active dispatcher" do
    # Complete v1 reductions include the deliberately retained global admission
    # validation. Measure Core separately rather than claiming bounded v1 work.
    for active <- [false, true] do
      if active, do: Process.register(self(), Dispatcher)

      rows =
        for size <- [128, 2_048],
            version <- [0, 1],
            command <- [
              {:put, "new", "tiny"},
              {:put, "fixture-1", "tiny"},
              {:delete, "fixture-1"},
              {:delete, "missing"}
            ] do
          state = fixture(size)
          :ok = StateMachine.materialize(state)
          expected = apply_core(version, context(size + 1), command, state)
          envelope = CommandEnvelope.wrap(1_000, command, version)
          adapter = fn -> Adapter.apply(metadata(size + 1), envelope, state) end
          core = fn -> apply_core(version, context(size + 1), command, state) end
          adapter_reductions = measure(adapter, expected)
          core_reductions = measure(core, expected)
          {size, version, command, adapter_reductions, core_reductions}
        end

      for version <- [0, 1],
          command <- [
            {:put, "new", "tiny"},
            {:put, "fixture-1", "tiny"},
            {:delete, "fixture-1"},
            {:delete, "missing"}
          ] do
        [{_, _, _, small, small_core}, {_, _, _, large, large_core}] =
          Enum.filter(rows, fn {_, v, c, _, _} -> v == version and c == command end)

        assert large - large_core < (small - small_core) * 4 + 1_000,
               "growing adapter overhead: #{inspect({active, version, command, rows})}"

        if version == 0, do: assert(large < small * 4 + 1_000)
      end

      if active, do: Process.unregister(Dispatcher)
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

    state =
      Enum.reduce(1..size, state, fn number, acc ->
        key = "fixture-#{number}"
        {:ok, acc} = Core.apply_legacy(context(number), {:put, key, %{tag: "old-#{number}"}}, acc)
        {:ok, acc} = Core.apply_legacy(context(number), {:put, key, %{tag: "tag-#{number}"}}, acc)
        acc
      end)

    {{:ok, _}, state} = Core.apply(context(size + 1), :reconcile_legacy_state, state)
    state
  end

  defp assert_views(state) do
    for name <- [:store, :current, :history, :leases] do
      assert Map.new(:ets.tab2list(StorageScope.table(name))) == Map.fetch!(state, name)
    end

    for {name, entries} <- state.index_entries, is_binary(name) do
      table = StorageScope.index_table_name(name)
      assert is_reference(table)
      assert Map.new(:ets.tab2list(table)) == entries
    end
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
  defp context(op), do: %Context{op_number: op, timestamp_ms: 1_000}

  defp metadata(op),
    do: %ApplyMetadata{
      group_id: :incremental_test,
      view_number: 0,
      op_number: op,
      client_id: :test,
      request_number: op
    }
end
