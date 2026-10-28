defmodule Concord.TursoDescendingListTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Concord.Turso.{Codec, Migrations}

  @moduletag :tmp_dir
  @db Concord.Turso.DB
  @traced_functions [{Codec, :decode_record, 1}, {Elixir.Turso, :query, 4}]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ex_turso)
    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    stop_pool()

    start_supervised!(
      {Elixir.Turso, database: Path.join(tmp_dir, "descending.db"), name: @db, pool_size: 1}
    )

    on_exit(&stop_pool/0)
    :ok
  end

  test "descending key-only pages use the covering index without fetching two-megabyte values" do
    value = :binary.copy("large uncompressed value", 100_000)
    assert byte_size(value) > 2_000_000

    for key <- ["desc/a", "desc/a" <> <<0>>, "desc/m", "desc/z", "desc0", "unrelated"] do
      assert {:ok, _} =
               KV.put(key, value,
                 engine: :turso,
                 compress: false,
                 metadata: %{nested: %{source: "fixture"}, binary: <<0, 255>>},
                 content_type: "application/octet-stream",
                 ttl: 3_600
               )
    end

    assert_projected_page([prefix: "desc/", limit: 2], ["desc/z", "desc/m"], true)

    assert_projected_page(
      [range: {"desc/", "desc/m"}, limit: 2],
      ["desc/a" <> <<0>>, "desc/a"],
      false
    )

    assert_projected_page(
      [prefix: "desc/", limit: 4],
      ["desc/z", "desc/m", "desc/a" <> <<0>>, "desc/a"],
      false
    )

    assert_projected_page([range: {"desc/b", "desc/y"}, limit: 1], ["desc/m"], false)
    assert_projected_page([prefix: "missing/", limit: 1], [], false)
    assert_projected_page([range: {"desc/a", "desc/a"}, limit: 1], [], false)
    assert_projected_page([range: {"desc/z", "desc/a"}, limit: 1], [], false)
    assert {:error, :invalid_order} = Concord.Turso.list(prefix: "desc/", order: :reverse)

    assert {:error, :invalid_order} =
             Concord.Engine.Turso.query({:list, {:prefix, "desc/"}, %{order: :reverse}}, [])
  end

  test "expired and deleted keys do not consume descending page limits or lookahead" do
    for key <- ["visible/a", "visible/c", "visible/e"] do
      assert {:ok, _} = KV.put(key, key, engine: :turso)
    end

    for key <- ["visible/z-expired", "visible/d-expired", "visible/b-expired"] do
      assert {:ok, :ok} =
               Concord.Engine.command({:put, key, "expired", System.system_time(:second) - 60},
                 engine: :turso
               )
    end

    for key <- ["visible/y-deleted", "visible/f-deleted", "visible/b-deleted"] do
      assert {:ok, _} = KV.put(key, "deleted", engine: :turso)
      assert {:ok, _} = KV.delete(key, engine: :turso)
    end

    assert_projected_page([prefix: "visible/", limit: 2], ["visible/e", "visible/c"], true)
    assert_projected_page([range: {"visible/", "visible/c"}, limit: 2], ["visible/a"], false)
    assert_projected_page([range: {"visible/", "visible/a"}, limit: 2], [], false)
  end

  defp assert_projected_page(opts, keys, has_more) do
    opts = Keyword.put(opts, :order, :desc)
    assert {:ok, full_records, cursor} = Concord.Turso.list(opts)
    assert Enum.map(full_records, & &1.key) == keys
    assert cursor == %{has_more: has_more, last_key: List.last(keys)}

    {result, calls} = traced(fn -> Concord.Turso.list(Keyword.put(opts, :keys_only, true)) end)
    assert result == {:ok, Enum.map(full_records, &Map.put(&1, :value, nil)), cursor}
    refute :decode_record in calls

    assert [{:sql, sql, params}] =
             Enum.filter(calls, fn
               {:sql, sql, _params} -> Regex.match?(~r/ORDER BY\s+key\s+DESC\s+LIMIT\s+\?/i, sql)
               _ -> false
             end)

    assert List.last(params) == Keyword.fetch!(opts, :limit) + 1
    assert String.contains?(sql, "INDEXED BY concord_turso_current_metadata")
    assert String.contains?(sql, "SELECT key, record_metadata")

    assert {:ok, %{rows: plan}} = Elixir.Turso.query(@db, "EXPLAIN QUERY PLAN " <> sql, params)
    assert Enum.any?(plan, &Regex.match?(~r/COVERING INDEX/i, &1["detail"]))
    refute Enum.any?(plan, &String.contains?(&1["detail"], "TEMP B-TREE"))

    for {:sql, sql, _params} <- calls,
        [_, columns] <-
          Regex.scan(~r/SELECT\s+(.*?)\s+FROM\s+concord_turso_(?:current|history)\b/is, sql) do
      refute Regex.match?(~r/\b(?:record|value)\b|\*/, columns), sql
    end
  end

  defp traced(fun) do
    :ok = Migrations.migrate()
    tracer = spawn(fn -> collect_calls([]) end)
    for mfa <- @traced_functions, do: :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      result = fun.()
      :erlang.trace(self(), false, [:call])
      reference = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^reference}, 1_000
      send(tracer, {:collect, self()})
      assert_receive {:calls, calls}, 1_000
      {result, calls}
    after
      :erlang.trace(self(), false, [:call])
      for mfa <- @traced_functions, do: :erlang.trace_pattern(mfa, false, [:local])
      if Process.alive?(tracer), do: Process.exit(tracer, :kill)
    end
  end

  defp collect_calls(calls) do
    receive do
      {:trace, _, :call, {Codec, :decode_record, [_record]}} ->
        collect_calls([:decode_record | calls])

      {:trace, _, :call, {Elixir.Turso, :query, [_conn, sql, params, _opts]}} ->
        collect_calls([{:sql, sql, params} | calls])

      {:collect, caller} ->
        send(caller, {:calls, Enum.reverse(calls)})
    end
  end

  defp stop_pool do
    case Process.whereis(@db) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  catch
    :exit, _ -> :ok
  end
end
