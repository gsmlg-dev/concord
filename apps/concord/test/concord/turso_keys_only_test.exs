defmodule Concord.TursoKeysOnlyTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Concord.KV.Record
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
      {Elixir.Turso, database: Path.join(tmp_dir, "keys_only.db"), name: @db, pool_size: 1}
    )

    on_exit(&stop_pool/0)
    :ok
  end

  test "bounded prefix and range pages omit large uncompressed values without decoding records" do
    value = :binary.copy("large uncompressed value", 100_000)

    for key <- ["page/a", "page/a" <> <<0>>, "page/b", "page/c", "unrelated"] do
      assert {:ok, _} =
               KV.put(key, value,
                 engine: :turso,
                 compress: false,
                 content_type: "application/octet-stream",
                 metadata: %{nested: %{source: "fixture"}, binary: <<0, 255>>},
                 ttl: 3_600
               )
    end

    assert {:ok, %Record{value: ^value}} = KV.get("page/a", engine: :turso, metadata: true)

    assert_projected_page([prefix: "page/", limit: 2], ["page/a", "page/a" <> <<0>>], true)

    assert_projected_page(
      [range: {"page/a" <> <<0, 0>>, "page0"}, limit: 2],
      ["page/b", "page/c"],
      false
    )

    assert_projected_page(
      [prefix: "page/", limit: 4],
      ["page/a", "page/a" <> <<0>>, "page/b", "page/c"],
      false
    )

    assert_projected_page([prefix: "missing/", limit: 1], [], false)
    assert_projected_page([range: {"page/z", "page/a"}, limit: 1], [], false)
  end

  test "key-only pages retain creation, update, touch, delete, and transaction metadata" do
    assert {:ok, %{revision: created}} = KV.put("metadata/a", "old", engine: :turso)

    assert {:ok, %{revision: updated}} =
             KV.put("metadata/a", "new",
               engine: :turso,
               metadata: %{owner: "updated"},
               content_type: "text/plain"
             )

    assert :ok = Concord.Turso.touch("metadata/a", 3_600)

    assert {:ok, [record], _} = KV.list(engine: :turso, prefix: "metadata/")
    assert record.create_revision == created
    assert record.mod_revision > updated
    assert record.version > 1
    assert record.metadata == %{owner: "updated"}
    assert record.content_type == "text/plain"
    assert record.expires_at > System.system_time(:second)
    assert_projected_page([prefix: "metadata/", limit: 1], ["metadata/a"], false)

    assert {:ok, _} = KV.delete("metadata/a", engine: :turso)
    assert_projected_page([prefix: "metadata/", limit: 1], [], false)

    assert {:ok, %{revision: recreated}} =
             KV.put("metadata/a", "recreated", engine: :turso, metadata: %{owner: "recreated"})

    assert {:ok, [record], _} = KV.list(engine: :turso, prefix: "metadata/")
    assert record.create_revision == recreated
    assert record.version == 1
    assert record.metadata == %{owner: "recreated"}

    assert {:ok, %Concord.Txn.Result{succeeded: true}} =
             Concord.Turso.txn(%{
               compare: [],
               success: [{:put, "metadata/b", "transaction", %{metadata: %{source: "txn"}}}],
               failure: []
             })

    assert_projected_page([prefix: "metadata/", limit: 2], ["metadata/a", "metadata/b"], false)
  end

  test "expired and deleted rows do not consume visible page limits or continuation" do
    for key <- ["visible/a", "visible/c", "visible/e"] do
      assert {:ok, _} = KV.put(key, key, engine: :turso)
    end

    for key <- [
          "visible/0-expired",
          "visible/b-expired",
          "visible/d-expired",
          "visible/z-expired"
        ] do
      assert {:ok, :ok} =
               Concord.Engine.command({:put, key, "expired", System.system_time(:second) - 60},
                 engine: :turso
               )
    end

    for key <- [
          "visible/1-deleted",
          "visible/b-deleted",
          "visible/d-deleted",
          "visible/z-deleted"
        ] do
      assert {:ok, _} = KV.put(key, "deleted", engine: :turso)
      assert {:ok, _} = KV.delete(key, engine: :turso)
    end

    assert_projected_page([prefix: "visible/", limit: 2], ["visible/a", "visible/c"], true)

    assert_projected_page(
      [range: {"visible/c" <> <<0>>, "visible0"}, limit: 2],
      ["visible/e"],
      false
    )

    assert_projected_page([range: {"visible/e" <> <<0>>, "visible0"}, limit: 2], [], false)
  end

  test "original databases backfill projections and retain old-writer replacement metadata" do
    assert {:ok, _} =
             Elixir.Turso.execute(@db, """
             CREATE TABLE concord_turso_current (
               key TEXT PRIMARY KEY,
               record BLOB NOT NULL,
               expires_at INTEGER,
               mod_revision INTEGER NOT NULL,
               version INTEGER NOT NULL
             )
             """)

    original = %Record{
      value: :binary.copy("old database value", 100_000),
      create_revision: 7,
      mod_revision: 12,
      version: 3,
      expires_at: System.system_time(:second) + 3_600,
      lease_id: 42,
      content_type: "application/octet-stream",
      metadata: %{source: "old database", nested: %{tag: <<0, 255>>}}
    }

    old_writer_put("old/a", original)
    old_writer_put("old/deleted", Record.tombstone("old/deleted", 14, original))
    old_writer_put("old/expired", %{original | expires_at: System.system_time(:second) - 60})
    assert :ok = Migrations.migrate()
    assert :ok = Migrations.migrate()
    assert_projected_page([prefix: "old/", limit: 1], ["old/a"], false)

    replacement = %{
      original
      | value: "replaced",
        mod_revision: 13,
        version: 4,
        metadata: %{source: "old writer"}
    }

    old_writer_put("old/a", replacement)
    assert :ok = Migrations.migrate()
    assert_projected_page([prefix: "old/", limit: 1], ["old/a"], false)

    assert {:ok, _} =
             Elixir.Turso.execute(
               @db,
               "UPDATE concord_turso_current SET record = ? WHERE key = ?",
               [
                 <<"not an encoded record">>,
                 "old/a"
               ]
             )

    {result, calls} =
      traced(fn -> KV.list(engine: :turso, prefix: "old/", keys_only: true, limit: 1) end)

    expected = replacement |> Map.put(:value, nil) |> Map.put(:key, "old/a")
    assert result == {:ok, [expected], %{has_more: false, last_key: "old/a"}}
    refute :decode_record in calls
  end

  test "explicit list timeout includes pooled connection checkout and leaves the pool usable" do
    assert {:ok, _} = KV.put("timeout/a", "value", engine: :turso)
    owner = self()
    supervisor = start_supervised!(Task.Supervisor)

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        DBConnection.run(@db, fn _conn ->
          send(owner, {:checked_out, self()})

          receive do
            :release -> :ok
          end
        end)
      end)

    try do
      assert_receive {:checked_out, pid}, 1_000
      assert pid == holder.pid
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               KV.list(engine: :turso, prefix: "timeout/", keys_only: true, limit: 1, timeout: 20)

      assert System.monotonic_time(:millisecond) - started < 1_000
    after
      send(holder.pid, :release)
      assert :ok = Task.await(holder, 1_000)
    end

    assert_projected_page([prefix: "timeout/", limit: 1], ["timeout/a"], false)
  end

  defp old_writer_put(key, record) do
    assert {:ok, _} =
             Elixir.Turso.execute(
               @db,
               """
               INSERT OR REPLACE INTO concord_turso_current (key, record, expires_at, mod_revision, version)
               VALUES (?, ?, ?, ?, ?)
               """,
               [
                 key,
                 {:blob, :erlang.term_to_binary(record)},
                 record.expires_at,
                 record.mod_revision,
                 record.version
               ]
             )
  end

  defp assert_projected_page(opts, keys, has_more) do
    assert {:ok, full_records, cursor} = KV.list(Keyword.put(opts, :engine, :turso))
    assert Enum.map(full_records, & &1.key) == keys
    assert cursor == %{has_more: has_more, last_key: List.last(keys)}

    {result, calls} =
      traced(fn ->
        KV.list(Keyword.merge(opts, engine: :turso, keys_only: true))
      end)

    assert result == {:ok, Enum.map(full_records, &Map.put(&1, :value, nil)), cursor}
    refute :decode_record in calls

    statements = for {:sql, sql, _params} <- calls, do: sql
    assert Enum.any?(statements, &Regex.match?(~r/SELECT .* FROM concord_turso_current/is, &1))

    assert [{:sql, page_sql, page_params}] =
             Enum.filter(calls, fn
               {:sql, sql, _params} -> Regex.match?(~r/ORDER BY\s+key\s+LIMIT\s+\?/i, sql)
               _ -> false
             end)

    assert List.last(page_params) == Keyword.fetch!(opts, :limit) + 1

    assert_covering_plan(page_sql, page_params)

    assert [{:sql, missing_sql, missing_params}] =
             Enum.filter(calls, fn
               {:sql, sql, _params} -> String.contains?(sql, "record_metadata IS NULL")
               _ -> false
             end)

    assert_covering_plan(missing_sql, missing_params)

    for sql <- statements,
        [_, columns] <-
          Regex.scan(~r/SELECT\s+(.*?)\s+FROM\s+concord_turso_(?:current|history)\b/is, sql) do
      refute Regex.match?(~r/\b(?:record|value)\b|\*/, columns), sql
    end
  end

  defp assert_covering_plan(sql, params) do
    assert {:ok, %Elixir.Turso.Result{rows: plan}} =
             Elixir.Turso.query(@db, "EXPLAIN QUERY PLAN " <> sql, params)

    assert Enum.any?(plan, &Regex.match?(~r/COVERING INDEX/i, &1["detail"]))
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
