defmodule Concord.StateMachine.BoundedListTest do
  use ExUnit.Case, async: true

  alias Concord.KV.Record
  alias Concord.StateMachine.Core
  alias Concord.StateMachine.Core.{Context, State}

  for count <- [10_000, 100_000] do
    @tag timeout: 60_000
    test "small and empty pages skip #{count} unrelated current and historical keys" do
      state = inventory(unquote(count))

      measurements =
        for revision <- [nil, 1],
            selector <- [
              {:prefix, "m/page/"},
              {:range, "m/page/", "m/page0"},
              {:prefix, "m/missing/"},
              {:range, "m/missing/", "m/missing0"}
            ] do
          {result, cost} =
            measured(fn ->
              Core.query({:list, selector, %{limit: 1, revision: revision}}, state, now())
            end)

          if elem(selector, 1) == "m/page/" do
            assert {:ok, [%{key: "m/page/a", value: value}],
                    %{has_more: true, last_key: "m/page/a"}} = result

            assert value == if(revision, do: "old", else: "current")
          else
            assert result == {:ok, [], %{has_more: false, last_key: nil}}
          end

          {revision, selector, cost}
        end

      IO.inspect(measurements,
        label: "list query reductions with #{unquote(count)} unrelated keys"
      )

      assert Enum.all?(measurements, fn {_revision, _selector, reductions} ->
               reductions < 50_000
             end)
    end
  end

  test "pages preserve lexical ordering, keys-only records, and fixed-revision continuation" do
    state =
      apply_commands([
        {:put, "page/z", "z", %{}},
        {:put, "page/a", "a", %{metadata: %{author: "fixture"}}},
        {:put, "page/a" <> <<0>>, "zero", %{}},
        {:put, "page/b", "b", %{}}
      ])

    revision = state.revision

    assert {:ok, [first], %{has_more: true, last_key: "page/a"}} =
             page(state, {:prefix, "page/"}, %{limit: 1, keys_only: true, revision: revision})

    assert first.value == nil
    assert first.metadata == %{author: "fixture"}

    {_, changed} = Core.apply(context(5), {:delete, "page/b", %{}}, state)

    assert {:ok, records, %{has_more: false, last_key: "page/z"}} =
             page(changed, {:range, first.key <> <<0>>, "page0"}, %{limit: 3, revision: revision})

    assert Enum.map(records, &{&1.key, &1.value}) == [
             {"page/a" <> <<0>>, "zero"},
             {"page/b", "b"},
             {"page/z", "z"}
           ]

    assert {:ok, _, %{has_more: false}} = page(state, {:prefix, "page/"}, %{limit: 4})
    assert {:ok, [], %{has_more: false, last_key: nil}} = page(state, {:prefix, "missing"})
  end

  test "latest eligible revision is selected before tombstone and read-time expiry filtering" do
    state =
      apply_commands([
        {:put, "key", "old", %{}},
        {:delete, "key", %{}},
        {:put, "key", "recreated", %{ttl: 1}}
      ])

    assert {:ok, [%{value: "old"}], _} = page(state, {:key, "key"}, %{revision: 1})
    assert {:ok, [], _} = page(state, {:key, "key"}, %{revision: 2})

    assert {:ok, [%{value: "recreated", version: 1}], _} =
             page(state, {:key, "key"}, %{revision: 3})

    assert {:ok, [_], _} =
             Core.query({:list, {:key, "key"}, %{revision: 3}}, state, %{timestamp_ms: 1_001_000})

    assert {:ok, [], _} =
             Core.query({:list, {:key, "key"}, %{revision: 3}}, state, %{timestamp_ms: 1_002_000})
  end

  test "history-only records and history newer than current retain snapshot semantics" do
    current = %Record{value: "current", create_revision: 1, mod_revision: 1, version: 1}
    historical = %{current | value: "newer history", mod_revision: 2, version: 2}
    only_history = %{current | value: "only history"}

    source = %State{
      current: %{"key" => current},
      store: %{"key" => %{value: "current", expires_at: nil}},
      history: %{
        {"key", 1} => %{current | value: "historical tie"},
        {"key", 2} => historical,
        {"only", 1} => only_history
      },
      revision: 2
    }

    assert {:ok, state} = Core.restore(source)
    assert {:ok, [%{value: "current"}], _} = page(state, {:key, "key"}, %{revision: 1})
    assert {:ok, [%{value: "newer history"}], _} = page(state, {:key, "key"}, %{revision: 2})
    assert {:ok, [%{value: "only history"}], _} = page(state, {:key, "only"}, %{revision: 2})
    assert {:ok, [], _} = page(state, {:key, "only"})
    assert {:ok, "only history"} = Core.query({:get, "only", revision: 1}, state, now())
  end

  test "index maintenance follows batch, transaction, TTL, and lease mutations" do
    commands = [
      {:put_many, [{"a", "first", nil}, {"b", "second", nil}]},
      {:put, "a", "updated", %{}},
      {:touch, "a", 10},
      {:put_many, [{"expired", "old", 999}]},
      :cleanup_expired,
      {:grant_lease, 10, %{}},
      {:put, "leased", "leased", %{lease: 1}},
      {:revoke_lease, 1, %{}},
      {:txn,
       %{
         compare: [],
         success: [
           {:put, "fresh", "temporary", %{}},
           {:delete, {:key, "fresh"}, %{}},
           {:put, "fresh", "final", %{}},
           {:touch, "b", 10, %{}}
         ],
         failure: []
       }},
      {:delete_many, ["a", "b"]}
    ]

    Enum.reduce(Enum.with_index(commands, 1), Core.init(), fn {command, number}, state ->
      {result, state} = Core.apply(context(number), command, state)
      refute match?({:error, _}, result)
      assert_indexed_lists_match_authoritative_maps(state)
      assert :gb_trees.lookup("fresh", state.history_keys) == :none
      state
    end)
  end

  test "snapshots preserve v4 authoritative fields and rebuild all untrusted derived caches" do
    state =
      apply_commands([
        {:put, "z", "old", %{}},
        {:put, "a", "a", %{}},
        {:put, "z", "new", %{}},
        {:delete, "a", %{}}
      ])

    assert {:ok, snapshot} = Core.snapshot(state)
    assert snapshot.__concord_snapshot_version__ == 4
    refute Map.has_key?(snapshot.state, :current_keys)
    refute Map.has_key?(snapshot.state, :history_keys)
    assert snapshot.state == Map.drop(state, [:current_keys, :history_keys])

    poisoned = %{state | current_keys: :untrusted, history_keys: :untrusted}
    plain = Map.from_struct(snapshot.state)

    for source <- [
          snapshot,
          poisoned,
          plain,
          Map.from_struct(poisoned),
          {:concord_kv, Map.put(plain, :__snapshot_version__, 3)}
        ] do
      assert {:ok, restored} = Core.restore(source)
      assert {:ok, ^snapshot} = Core.snapshot(restored)
      assert_indexed_lists_match_authoritative_maps(restored)
    end

    assert {:ok, restored} = Core.restore(Map.delete(plain, :representation))
    assert restored.representation == :legacy
    assert_indexed_lists_match_authoritative_maps(restored)
    assert {:error, :invalid_snapshot} = Core.restore(Map.put(plain, :unknown, :field))
  end

  test "backup replacement, rollback, compaction, and legacy ingestion rebuild indexes" do
    state = apply_commands([{:put, "gone", "old", %{}}, {:put, "gone", "new", %{}}])
    assert {:ok, snapshot} = Core.snapshot(state)
    {_, changed} = Core.apply(context(3), {:put, "later", "value", %{}}, state)
    assert {:ok, rolled_back} = Core.restore(snapshot)
    assert {:ok, [], _} = page(rolled_back, {:key, "later"})
    assert {:ok, [_], _} = page(changed, {:key, "later"})

    backup = %{
      version: 2,
      kv_data: [{"restored", %{value: "value", expires_at: nil}}],
      indexes: %{}
    }

    assert {:ok, replacement} = Core.apply_command(context(4), {:restore_backup, backup}, changed)
    assert :gb_trees.is_empty(replacement.history_keys)
    assert_indexed_lists_match_authoritative_maps(replacement)

    assert {:error, {:compacted, compacted}} =
             page(replacement, {:prefix, ""}, %{revision: replacement.compact_revision})

    assert compacted == replacement.compact_revision

    legacy = Core.from_legacy_tables(Core.init(), Map.take(state, [:current, :store, :history]))
    assert_indexed_lists_match_authoritative_maps(%{legacy | revision: 2})

    legacy = %{
      legacy
      | revision: 2,
        store: Map.put(legacy.store, "imported", %{value: "legacy", expires_at: nil})
    }

    assert {{:ok, _}, reconciled} = Core.apply(context(5), :reconcile_legacy_state, legacy)
    assert {:ok, [%{value: "legacy"}], _} = page(reconciled, {:key, "imported"})
    assert_indexed_lists_match_authoritative_maps(reconciled)
  end

  test "binary prefix bounds include zero and 255 bytes without UTF-8 assumptions" do
    keys = [<<255>>, <<255, 0>>, <<255, 255>>, <<254, 255>>]
    state = apply_commands(Enum.map(keys, &{:put, &1, &1, %{}}))
    assert {:ok, records, %{has_more: false}} = page(state, {:prefix, <<255>>})
    assert Enum.map(records, & &1.key) == [<<255>>, <<255, 0>>, <<255, 255>>]
  end

  defp assert_indexed_lists_match_authoritative_maps(state) do
    for revision <- [nil | Enum.to_list(1..max(1, state.revision))],
        selector <- [{:prefix, ""}, {:prefix, "a"}, {:range, "a", "m"}, {:key, "gone"}],
        limit <- [1, 2, 100] do
      if is_nil(revision) or revision > state.compact_revision do
        opts = %{revision: revision, limit: limit}
        assert page(state, selector, opts) == reference_page(state, selector, opts)
      end
    end
  end

  defp reference_page(state, selector, opts) do
    revision = opts.revision
    entries = Map.to_list(state.current)

    entries =
      if revision,
        do: entries ++ Enum.map(state.history, fn {{key, _}, record} -> {key, record} end),
        else: entries

    entries =
      entries
      |> Enum.filter(fn {_key, record} -> is_nil(revision) or record.mod_revision <= revision end)
      |> Enum.reduce(%{}, fn {key, record}, records ->
        Map.update(records, key, record, fn previous ->
          if record.mod_revision > previous.mod_revision, do: record, else: previous
        end)
      end)
      |> Enum.filter(fn {key, record} ->
        matches?(selector, key) and not Record.tombstone?(record) and
          not Record.expired?(record, 1000)
      end)
      |> Enum.sort_by(&elem(&1, 0))

    selected = Enum.take(entries, opts.limit)

    last_key =
      case List.last(selected) do
        nil -> nil
        {key, _} -> key
      end

    {:ok, Enum.map(selected, fn {key, record} -> Map.put(record, :key, key) end),
     %{has_more: length(entries) > opts.limit, last_key: last_key}}
  end

  defp matches?({:prefix, prefix}, key), do: String.starts_with?(key, prefix)
  defp matches?({:range, first, last}, key), do: key >= first and key < last
  defp matches?({:key, expected}, key), do: key == expected

  defp page(state, selector, opts \\ %{}), do: Core.query({:list, selector, opts}, state, now())

  defp apply_commands(commands) do
    Enum.reduce(Enum.with_index(commands, 1), Core.init(), fn {command, number}, state ->
      {result, state} = Core.apply(context(number), command, state)
      refute match?({:error, _}, result)
      state
    end)
  end

  defp context(number), do: %Context{op_number: number, timestamp_ms: 1_000_000}

  defp inventory(count) do
    keys =
      Enum.map(1..count, fn number ->
        prefix = if rem(number, 2) == 0, do: "a/unrelated/", else: "z/unrelated/"
        prefix <> String.pad_leading(Integer.to_string(number), 6, "0")
      end) ++ ["m/page/a", "m/page/b", "m/page/c"]

    current_record = %Record{value: "current", create_revision: 1, mod_revision: 2, version: 2}
    historical_record = %Record{value: "old", create_revision: 1, mod_revision: 1, version: 1}
    current = Map.new(keys, &{&1, current_record})

    state = %State{
      current: current,
      store: Map.new(keys, &{&1, %{value: "current", expires_at: nil}}),
      history: Map.new(keys, &{{&1, 1}, historical_record}),
      revision: 2
    }

    {:ok, state} = Core.restore(state)
    state
  end

  defp measured(fun) do
    {:reductions, before_count} = Process.info(self(), :reductions)
    result = fun.()
    {:reductions, after_count} = Process.info(self(), :reductions)
    {result, after_count - before_count}
  end

  defp now, do: %Context{op_number: 1, timestamp_ms: 1_000_000}
end
