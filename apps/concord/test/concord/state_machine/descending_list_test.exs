defmodule Concord.StateMachine.DescendingListTest do
  use ExUnit.Case, async: true

  alias Concord.KV.Record
  alias Concord.StateMachine.Core
  alias Concord.StateMachine.Core.{Context, State}

  for count <- [10_000, 100_000] do
    @tag timeout: 60_000
    test "descending seeks skip #{count} older matching current and historical keys" do
      state = inventory(unquote(count))

      costs =
        for revision <- [nil, 1],
            selector <- [{:prefix, "page/"}, {:range, "page/", "page/z-c"}] do
          {result, cost} =
            measured(fn -> page(state, selector, %{limit: 1, revision: revision}) end)

          expected = if elem(selector, 0) == :prefix, do: "page/z-c", else: "page/z-b"

          assert {:ok, [%{key: ^expected, value: value}], %{has_more: true, last_key: ^expected}} =
                   result

          assert value == if(revision, do: "old", else: "current")
          cost
        end

      IO.inspect(costs, label: "descending reductions with #{unquote(count)} older matching keys")
      assert Enum.all?(costs, &(&1 < 50_000))
    end
  end

  test "sparse and NUL keys retain exclusive upper bounds and exact lookahead" do
    keys = ["page/a", "page/a" <> <<0>>, "page/m", "page/z"]
    state = apply_commands(Enum.map(["page0", "page", "outside" | keys], &{:put, &1, &1, %{}}))

    assert_page(state, {:prefix, "page/"}, %{limit: 2}, ["page/z", "page/m"], true)

    assert_page(
      state,
      {:range, "page/a", "page/m"},
      %{limit: 2},
      ["page/a" <> <<0>>, "page/a"],
      false
    )

    assert_page(state, {:prefix, "page/"}, %{limit: 4}, Enum.reverse(keys), false)
    assert_page(state, {:range, "page/b", "page/y"}, %{limit: 1}, ["page/m"], false)
    assert_page(state, {:range, "page/m", "page/m"}, %{}, [], false)
    assert_page(state, {:range, "page/z", "page/a"}, %{}, [], false)
    assert_page(state, {:range, "page/b", "page/c"}, %{}, [], false)
    assert_page(state, {:prefix, "missing/"}, %{}, [], false)
    assert_page(state, {:key, "page/m"}, %{}, ["page/m"], false)
    assert_page(state, {:key, "page/n"}, %{}, [], false)

    assert {:ok, ascending, _} = Core.query({:list, {:prefix, "page/"}, %{}}, state, now())
    assert Enum.map(ascending, & &1.key) == keys
  end

  test "binary prefix successors include trailing FF and prefixes with no finite successor" do
    keys = [
      <<254>>,
      <<254, 255>>,
      <<254, 255, 0>>,
      <<255>>,
      <<255, 0>>,
      <<255, 255>>,
      <<255, 255, 0>>
    ]

    state = apply_commands(Enum.map(keys, &{:put, &1, &1, %{}}))

    for prefix <- [<<>>, <<254, 255>>, <<255>>, <<255, 255>>, <<255, 255, 255>>] do
      expected = keys |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort(:desc)
      assert_page(state, {:prefix, prefix}, %{}, expected, false)
    end
  end

  test "descending current and snapshot pages select latest revisions before expiry and tombstones" do
    original =
      apply_commands([
        {:put, "page/a", "a", %{metadata: %{source: "original"}}},
        {:put, "page/a" <> <<0>>, "zero", %{}},
        {:put, "page/m", "middle", %{}},
        {:put, "page/z", "expires", %{ttl: 1}}
      ])

    state =
      Enum.reduce(
        [
          {5, {:delete, "page/m", %{}}},
          {6, {:put, "page/a", "updated", %{}}},
          {7, {:delete, "page/z", %{}}},
          {8, {:put, "page/zz", "current expiry", %{ttl: 1}}}
        ],
        original,
        fn {number, command}, state -> elem(Core.apply(context(number), command, state), 1) end
      )

    assert_page(state, {:prefix, "page/"}, %{limit: 1, revision: 4}, ["page/z"], true)

    assert {:ok, records, %{has_more: false, last_key: "page/a"}} =
             page(state, {:range, "page/", "page/z"}, %{limit: 3, revision: 4, keys_only: true})

    assert Enum.map(records, & &1.key) == ["page/m", "page/a" <> <<0>>, "page/a"]
    assert Enum.all?(records, &is_nil(&1.value))
    assert List.last(records).metadata == %{source: "original"}
    assert List.last(records).mod_revision == 1
    assert_page(state, {:prefix, "page/"}, %{}, ["page/zz", "page/a" <> <<0>>, "page/a"], false)

    assert_page(
      state,
      {:prefix, "page/"},
      %{revision: 5},
      ["page/z", "page/a" <> <<0>>, "page/a"],
      false
    )

    assert {:ok, expired_snapshot, _} =
             Core.query({:list, {:prefix, "page/"}, %{revision: 4, order: :desc}}, state, %{
               timestamp_ms: 1_002_000
             })

    assert Enum.map(expired_snapshot, & &1.key) == ["page/m", "page/a" <> <<0>>, "page/a"]

    assert {:ok, expired_current, _} =
             Core.query({:list, {:prefix, "page/"}, %{order: :desc}}, state, %{
               timestamp_ms: 1_002_000
             })

    assert Enum.map(expired_current, & &1.key) == ["page/a" <> <<0>>, "page/a"]
  end

  test "merging history-only keys deduplicates ties and chooses the newest eligible record" do
    record = %Record{value: "current", create_revision: 1, mod_revision: 1, version: 1}

    assert {:ok, state} =
             Core.restore(%State{
               current: %{"m" => record},
               store: %{"m" => %{value: "current", expires_at: nil}},
               history: %{
                 {"a", 1} => %{record | value: "history a"},
                 {"m", 1} => %{record | value: "historical tie"},
                 {"m", 2} => %{record | value: "newer history", mod_revision: 2, version: 2},
                 {"z", 1} => %{record | value: "history z"}
               },
               revision: 2
             })

    assert {:ok, records, _} = page(state, {:prefix, ""}, %{revision: 1})

    assert Enum.map(records, &{&1.key, &1.value}) == [
             {"z", "history z"},
             {"m", "current"},
             {"a", "history a"}
           ]

    assert {:ok, [%{value: "newer history"}], _} = page(state, {:key, "m"}, %{revision: 2})
    assert_page(state, {:prefix, ""}, %{}, ["m"], false)
  end

  test "unsupported orders are rejected at the schema and Core boundaries" do
    for order <- [:reverse, nil, "desc", 1] do
      query = {:list, {:prefix, ""}, %{order: order}}
      assert {:error, :unsupported_query} = Concord.QuerySchema.validate(query)
      assert {:error, :invalid_order} = Core.query(query, Core.init(), now())
    end

    for order <- [:asc, :desc] do
      assert :ok = Concord.QuerySchema.validate({:list, {:prefix, ""}, %{order: order}})
    end
  end

  defp assert_page(state, selector, opts, expected, more) do
    assert {:ok, records, cursor} = page(state, selector, opts)
    assert Enum.map(records, & &1.key) == expected
    assert cursor == %{has_more: more, last_key: List.last(expected)}
  end

  defp page(state, selector, opts),
    do: Core.query({:list, selector, Map.put(opts, :order, :desc)}, state, now())

  defp apply_commands(commands) do
    Enum.reduce(Enum.with_index(commands, 1), Core.init(), fn {command, number}, state ->
      {result, state} = Core.apply(context(number), command, state)
      refute match?({:error, _}, result)
      state
    end)
  end

  defp inventory(count) do
    keys =
      Enum.map(1..count, &("page/" <> String.pad_leading(Integer.to_string(&1), 6, "0"))) ++
        ["page/z-a", "page/z-b", "page/z-c"]

    current_record = %Record{value: "current", create_revision: 1, mod_revision: 2, version: 2}
    historical_record = %Record{value: "old", create_revision: 1, mod_revision: 1, version: 1}

    assert {:ok, state} =
             Core.restore(%State{
               current: Map.new(keys, &{&1, current_record}),
               store: Map.new(keys, &{&1, %{value: "current", expires_at: nil}}),
               history: Map.new(keys, &{{&1, 1}, historical_record}),
               revision: 2
             })

    state
  end

  defp measured(fun) do
    {:reductions, before_count} = Process.info(self(), :reductions)
    result = fun.()
    {:reductions, after_count} = Process.info(self(), :reductions)
    {result, after_count - before_count}
  end

  defp context(number), do: %Context{op_number: number, timestamp_ms: 1_000_000}
  defp now, do: %{timestamp_ms: 1_000_000}
end
