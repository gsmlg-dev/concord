defmodule Concord.TursoHistoricalListTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Concord.KV.Record
  alias Concord.Turso.{Codec, ListQueue, Migrations}

  @moduletag :tmp_dir
  @db Concord.Turso.DB
  @checkout {DBConnection.ConnectionPool, :checkout, 3}
  @traced [{Codec, :decode_record, 1}, {Elixir.Turso, :query, 4}]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ex_turso)
    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    stop_pool()

    start_supervised!(
      {Elixir.Turso, database: Path.join(tmp_dir, "historical_list.db"), name: @db, pool_size: 1}
    )

    start_supervised!({ListQueue, max_children: 2})
    tasks = start_supervised!(Task.Supervisor)
    on_exit(&stop_pool/0)
    %{tasks: tasks}
  end

  for order <- [:asc, :desc] do
    test "#{order} snapshot pages retain values and metadata across later ordinary mutations" do
      for key <- ["snapshot/a", "snapshot/c", "snapshot/e", "snapshot/g", "snapshot/z"] do
        assert {:ok, _} =
                 KV.put(key, %{original: key},
                   engine: :turso,
                   metadata: %{owner: key},
                   content_type: "application/x-erlang"
                 )
      end

      assert {:ok, revision} = KV.revision(engine: :turso)
      assert {:ok, originals, %{has_more: false}} = KV.list(engine: :turso, prefix: "snapshot/")

      assert {:ok, _} = KV.put("snapshot/a", :overwritten, engine: :turso)
      assert {:ok, _} = KV.delete("snapshot/c", engine: :turso)
      assert {:ok, _} = KV.delete("snapshot/g", engine: :turso)
      assert {:ok, _} = KV.put("snapshot/g", :recreated, engine: :turso)
      assert {:ok, _} = KV.put("snapshot/b", :later_append, engine: :turso)
      assert {:ok, _} = KV.put("snapshot/y", :later_append, engine: :turso)
      assert {:ok, _} = KV.put("snapshot0", :outside_prefix, engine: :turso)

      order = unquote(order)
      expected = ordered(originals, order)

      for keys_only <- [false, true] do
        opts = [revision: revision, order: order, keys_only: keys_only, limit: 2]

        assert {:ok, first, %{has_more: true, last_key: first_key}} =
                 Concord.Turso.list(Keyword.put(opts, :prefix, "snapshot/"))

        assert [_, _] = first

        assert {:ok, second, %{has_more: true, last_key: second_key}} =
                 KV.list(continuation(opts, order, first_key))

        assert [_, _] = second

        assert {:ok, third, %{has_more: false, last_key: last_key}} =
                 KV.list(continuation(opts, order, second_key))

        assert [last_record] = third
        assert last_key == last_record.key

        expected_page =
          if keys_only, do: Enum.map(expected, &Map.put(&1, :value, nil)), else: expected

        assert first ++ second ++ third == expected_page

        for record <- first ++ second ++ third do
          assert {:ok, %{original: key}} =
                   KV.get(record.key, engine: :turso, revision: revision)

          assert key == record.key
          assert record.metadata == %{owner: key}
          assert record.content_type == "application/x-erlang"
        end
      end
    end
  end

  test "precreation, deletion, and recreation revisions select the corresponding records" do
    assert {:ok, %{revision: created}} =
             KV.put("life/key", :first, engine: :turso, metadata: %{generation: 1})

    assert {:ok, %{revision: deleted}} = KV.delete("life/key", engine: :turso)

    assert {:ok, %{revision: recreated}} =
             KV.put("life/key", :second, engine: :turso, metadata: %{generation: 2})

    for revision <- [0, created - 1, deleted] do
      assert {:ok, [], %{has_more: false, last_key: nil}} =
               KV.list(engine: :turso, prefix: "life/", revision: revision)
    end

    assert {:ok,
            [
              %{
                key: "life/key",
                value: :first,
                create_revision: ^created,
                mod_revision: ^created,
                version: 1,
                metadata: %{generation: 1}
              }
            ], %{has_more: false}} = KV.list(engine: :turso, prefix: "life/", revision: created)

    assert {:ok,
            [
              %{
                key: "life/key",
                value: :second,
                create_revision: ^recreated,
                mod_revision: ^recreated,
                version: 1,
                metadata: %{generation: 2}
              }
            ], %{has_more: false}} = KV.list(engine: :turso, prefix: "life/", revision: recreated)
  end

  test "historical key-only pages use bounded indexed reads without decoding payloads" do
    value = :binary.copy("uncompressed historical value", 75_000)

    for key <- ["bounded/a", "bounded/c", "bounded/e", "unrelated/key"] do
      assert {:ok, _} =
               KV.put(key, value, engine: :turso, compress: false, metadata: %{source: key})
    end

    assert {:ok, revision} = KV.revision(engine: :turso)
    assert {:ok, original, _} = KV.list(engine: :turso, prefix: "bounded/")
    assert {:ok, _} = KV.delete("bounded/c", engine: :turso)
    assert {:ok, _} = KV.put("bounded/a", :later, engine: :turso)
    assert {:ok, _} = KV.put("unrelated/key", :later, engine: :turso)

    unrelated = for n <- 1..200, do: {"unrelated/#{n}", :unrelated}
    assert {:ok, _} = Concord.Turso.put_many(unrelated)
    assert :ok = Migrations.migrate()

    for table <- ["concord_turso_current", "concord_turso_history"] do
      assert {:ok, _} =
               Elixir.Turso.execute(@db, "UPDATE #{table} SET record = ? WHERE key = ?", [
                 {:blob, "unrelated payload must never be decoded"},
                 "unrelated/key"
               ])
    end

    for order <- [:asc, :desc] do
      {result, calls} =
        traced(fn ->
          KV.list(
            engine: :turso,
            prefix: "bounded/",
            revision: revision,
            order: order,
            keys_only: true,
            limit: 2
          )
        end)

      expected = if order == :asc, do: original, else: Enum.reverse(original)
      [first, second, _lookahead] = expected

      assert result ==
               {:ok, Enum.map([first, second], &Map.put(&1, :value, nil)),
                %{has_more: true, last_key: second.key}}

      refute :decode_record in calls
      assert_indexed_value_free_reads(calls)
    end
  end

  test "legacy history projection migration preserves bytes and repairs old-writer replacements" do
    create_legacy_tables()

    original = %Record{
      value: :binary.copy("legacy historical value", 50_000),
      create_revision: 2,
      mod_revision: 2,
      version: 1,
      metadata: %{source: "legacy history", nested: %{binary: <<0, 255>>}},
      content_type: "application/octet-stream"
    }

    current = Record.next(:current, 4, original, nil, %{metadata: %{source: "legacy current"}})
    old_writer_history("legacy/a", original)
    old_writer_current("legacy/a", current)

    assert {:ok, _} =
             Elixir.Turso.execute(@db, "INSERT INTO concord_turso_meta VALUES ('revision', 4)")

    before_migration = stored_record_bytes()

    expected = original |> Map.put(:value, nil) |> Map.put(:key, "legacy/a")

    assert {:ok, [^expected], %{has_more: false}} =
             KV.list(engine: :turso, prefix: "legacy/", revision: 2, keys_only: true)

    assert stored_record_bytes() == before_migration
    assert {:ok, 4} = KV.revision(engine: :turso)

    old_writer_history("legacy/a", original)

    assert {:ok, %{rows: [%{"record_metadata" => nil}]}} =
             Elixir.Turso.query(
               @db,
               "SELECT record_metadata FROM concord_turso_history WHERE key = ?",
               [
                 "legacy/a"
               ]
             )

    assert {:ok, [^expected], %{has_more: false}} =
             Concord.Turso.list(prefix: "legacy/", revision: 2, keys_only: true)

    assert :ok = Migrations.migrate()
    assert stored_record_bytes() == before_migration
    assert {:ok, 4} = KV.revision(engine: :turso)
  end

  test "revision zero is empty and invalid or future revisions fail explicitly" do
    assert {:ok, _} = KV.put("revision/key", :current, engine: :turso)
    assert {:ok, revision} = KV.revision(engine: :turso)

    assert {:ok, [], %{has_more: false, last_key: nil}} =
             Concord.Turso.list(prefix: "revision/", revision: 0)

    assert {:error, :future_revision} =
             KV.list(engine: :turso, prefix: "revision/", revision: revision + 1)

    for invalid <- [-1, 1.5, "1", false, :latest] do
      assert {:error, :invalid_revision} =
               KV.list(engine: :turso, prefix: "revision/", revision: invalid)
    end

    assert {:ok, [%{key: "revision/key", value: :current}], %{has_more: false}} =
             KV.list(engine: :turso, prefix: "revision/")
  end

  test "historical visibility filters expired records by current wall clock before page limits" do
    assert {:ok, _} = KV.put("ttl/a", :visible, engine: :turso, ttl: 3_600)
    assert {:ok, _} = KV.put("ttl/c", :visible, engine: :turso)

    for key <- ["ttl/0-expired", "ttl/b-expired", "ttl/z-expired"] do
      assert {:ok, :ok} =
               Concord.Engine.command({:put, key, :expired, System.system_time(:second) - 60},
                 engine: :turso
               )
    end

    assert {:ok, revision} = KV.revision(engine: :turso)
    assert {:ok, _} = KV.put("ttl/b-expired", :now_live, engine: :turso)

    for keys_only <- [false, true], order <- [:asc, :desc] do
      assert {:ok, records, %{has_more: false}} =
               KV.list(
                 engine: :turso,
                 prefix: "ttl/",
                 revision: revision,
                 limit: 2,
                 keys_only: keys_only,
                 order: order
               )

      expected = if order == :asc, do: ["ttl/a", "ttl/c"], else: ["ttl/c", "ttl/a"]
      assert Enum.map(records, & &1.key) == expected
    end
  end

  test "historical queue admission retains finite timeout and waits through controlled contention",
       %{
         tasks: tasks
       } do
    assert {:ok, %{revision: revision}} = KV.put("queued/key", :original, engine: :turso)
    assert {:ok, _} = KV.put("queued/key", :later, engine: :turso)
    holder = hold_connection(tasks)

    try do
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               KV.list(
                 engine: :turso,
                 prefix: "queued/",
                 revision: revision,
                 queue: true,
                 timeout: 20
               )

      assert System.monotonic_time(:millisecond) - started < 500
    after
      release_holder(holder)
    end

    holder = hold_connection(tasks)
    owner = self()
    tracer = spawn(fn -> observe_busy_checkout(owner) end)
    supervisor = Process.whereis(ListQueue.Tasks)
    :erlang.trace_pattern(@checkout, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(supervisor, true, [:call, :set_on_spawn, {:tracer, tracer}])

    request =
      Task.Supervisor.async_nolink(tasks, fn ->
        Concord.Turso.list(prefix: "queued/", revision: revision, queue: true, timeout: 1_000)
      end)

    try do
      assert_receive {:busy_checkout, _worker}, 1_000
      release_holder(holder)

      assert {:ok, [%{key: "queued/key", value: :original}], %{has_more: false}} =
               Task.await(request, 1_000)
    after
      release_holder(holder)
      if Process.alive?(request.pid), do: Task.shutdown(request, :brutal_kill)
      :erlang.trace(supervisor, false, [:call, :set_on_spawn])
      :erlang.trace_pattern(@checkout, false, [:local])
      stop_tracer(tracer)
    end
  end

  test "historical pages cross bounded batches of later keys without losing continuation" do
    originals = for n <- 1..250, do: {"batch/" <> String.pad_leading(to_string(n), 3, "0"), n}
    assert {:ok, _} = Concord.Turso.put_many(originals)
    assert {:ok, revision} = KV.revision(engine: :turso)
    assert {:ok, _} = Concord.Turso.delete_many(Enum.map(Enum.take(originals, 150), &elem(&1, 0)))

    future = for n <- 1..200, do: {"batch/000future/#{n}", :future}
    assert {:ok, _} = Concord.Turso.put_many(future)

    for order <- [:asc, :desc] do
      opts = [engine: :turso, revision: revision, order: order, keys_only: true, limit: 120]

      assert {:ok, first, %{has_more: true, last_key: first_key}} =
               KV.list(Keyword.put(opts, :prefix, "batch/"))

      continuation = fn key ->
        range = if order == :asc, do: {key <> <<0>>, "batch0"}, else: {"batch/", key}
        Keyword.put(opts, :range, range)
      end

      assert {:ok, second, %{has_more: true, last_key: second_key}} =
               KV.list(continuation.(first_key))

      assert {:ok, third, %{has_more: false}} = KV.list(continuation.(second_key))

      assert Enum.map(first ++ second ++ third, & &1.key) ==
               originals |> Enum.map(&elem(&1, 0)) |> Enum.sort(order)
    end
  end

  test "historical prefix seeks include NUL, maximum Unicode and arbitrary binary suffixes" do
    prefix_keys = [
      "bytes/a",
      "bytes/" <> <<0>>,
      "bytes/" <> <<0x10FFFF::utf8>> <> "x",
      "bytes/" <> <<255>>
    ]

    binary_keys = [<<255, 255>>, <<255, 255, 0>>, <<255, 255, 255>>]
    keys = prefix_keys ++ binary_keys
    assert {:ok, _} = Concord.Turso.put_many(Enum.map(keys, &{&1, :original}))
    assert {:ok, revision} = KV.revision(engine: :turso)
    assert {:ok, _} = Concord.Turso.delete_many(keys)

    for {prefix, expected} <- [{"bytes/", prefix_keys}, {<<255, 255>>, binary_keys}],
        order <- [:asc, :desc] do
      assert {:ok, records, %{has_more: false}} =
               KV.list(
                 engine: :turso,
                 prefix: prefix,
                 revision: revision,
                 order: order,
                 keys_only: true
               )

      assert Enum.map(records, & &1.key) == Enum.sort(expected, order)
      assert Enum.all?(records, &is_nil(&1.value))
    end
  end

  test "ordinary and transactional touches retain the prior snapshot record" do
    assert {:ok, %{revision: original}} = KV.put("touch/a", :original, engine: :turso, ttl: 7_200)
    assert {:ok, before} = KV.get("touch/a", engine: :turso, metadata: true)
    assert :ok = Concord.Turso.touch("touch/a", 3_600)
    assert {:ok, touched} = KV.revision(engine: :turso)
    assert {:ok, middle} = KV.get("touch/a", engine: :turso, metadata: true)

    assert {:ok, %{succeeded: true}} =
             Concord.Turso.txn(%{
               compare: [],
               success: [{:touch, "touch/a", 1_800, %{}}],
               failure: []
             })

    for {revision, expected} <- [{original, before}, {touched, middle}] do
      expected = Map.put(expected, :key, "touch/a")

      assert {:ok, [^expected], %{has_more: false}} =
               KV.list(engine: :turso, prefix: "touch/", revision: revision)
    end
  end

  defp continuation(opts, :asc, key),
    do: Keyword.merge(opts, engine: :turso, range: {key <> <<0>>, "snapshot0"})

  defp continuation(opts, :desc, key),
    do: Keyword.merge(opts, engine: :turso, range: {"snapshot/", key})

  defp ordered(records, :asc), do: records
  defp ordered(records, :desc), do: Enum.reverse(records)

  defp assert_indexed_value_free_reads(calls) do
    queries =
      for {:sql, sql, params} <- calls,
          Regex.match?(~r/\b(?:FROM|JOIN)\s+concord_turso_(?:current|history)\b/i, sql),
          not String.contains?(sql, "record_metadata IS NULL"),
          do: {sql, params}

    refute queries == []

    plans =
      Enum.flat_map(queries, fn {sql, params} ->
        for [_, columns] <-
              Regex.scan(~r/SELECT\s+(.*?)\s+FROM\s+concord_turso_(?:current|history)\b/is, sql) do
          refute Regex.match?(~r/\b(?:record|value)\b|\*/, columns), sql
        end

        assert {:ok, %{rows: plan}} =
                 Elixir.Turso.query(@db, "EXPLAIN QUERY PLAN " <> sql, params)

        Enum.map(plan, &Map.fetch!(&1, "detail"))
      end)

    assert Enum.any?(queries, fn {sql, _params} -> Regex.match?(~r/\bLIMIT\b/i, sql) end)
    assert Enum.any?(plans, &Regex.match?(~r/SEARCH.*(?:INDEX|PRIMARY KEY)/i, &1))
    assert Enum.any?(plans, &Regex.match?(~r/COVERING INDEX/i, &1))
    refute Enum.any?(plans, &String.contains?(&1, "TEMP B-TREE"))
  end

  defp create_legacy_tables do
    for sql <- [
          "CREATE TABLE concord_turso_meta (name TEXT PRIMARY KEY, value INTEGER NOT NULL)",
          "CREATE TABLE concord_turso_current (key TEXT PRIMARY KEY, record BLOB NOT NULL, " <>
            "expires_at INTEGER, mod_revision INTEGER NOT NULL, version INTEGER NOT NULL)",
          "CREATE TABLE concord_turso_history (key TEXT NOT NULL, revision INTEGER NOT NULL, " <>
            "record BLOB NOT NULL, PRIMARY KEY (key, revision))"
        ] do
      assert {:ok, _} = Elixir.Turso.execute(@db, sql)
    end
  end

  defp old_writer_history(key, record) do
    assert {:ok, _} =
             Elixir.Turso.execute(
               @db,
               "INSERT OR REPLACE INTO concord_turso_history (key, revision, record) VALUES (?, ?, ?)",
               [key, record.mod_revision, {:blob, Codec.encode_record(record)}]
             )
  end

  defp old_writer_current(key, record) do
    assert {:ok, _} =
             Elixir.Turso.execute(
               @db,
               "INSERT OR REPLACE INTO concord_turso_current " <>
                 "(key, record, expires_at, mod_revision, version) VALUES (?, ?, ?, ?, ?)",
               [
                 key,
                 {:blob, Codec.encode_record(record)},
                 record.expires_at,
                 record.mod_revision,
                 record.version
               ]
             )
  end

  defp stored_record_bytes do
    for table <- ["concord_turso_current", "concord_turso_history"] do
      assert {:ok, %{rows: rows}} =
               Elixir.Turso.query(@db, "SELECT record FROM #{table} ORDER BY key")

      {table, rows}
    end
  end

  defp traced(fun) do
    assert :ok = Migrations.migrate()
    tracer = spawn(fn -> collect_calls([]) end)
    for mfa <- @traced, do: :erlang.trace_pattern(mfa, true, [:local])
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
      for mfa <- @traced, do: :erlang.trace_pattern(mfa, false, [:local])
      stop_tracer(tracer)
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
        collect_calls(calls)

      {:stop, caller, reference} ->
        send(caller, {:stopped, reference})
    end
  end

  defp observe_busy_checkout(owner) do
    receive do
      {:trace, pid, :return_from, @checkout,
       {:error,
        %DBConnection.ConnectionError{message: "connection not available and queuing is disabled"}}} ->
        send(owner, {:busy_checkout, pid})
        observe_busy_checkout(owner)

      {:stop, caller, reference} ->
        send(caller, {:stopped, reference})

      _trace ->
        observe_busy_checkout(owner)
    end
  end

  defp stop_tracer(tracer) do
    reference = make_ref()
    send(tracer, {:stop, self(), reference})
    assert_receive {:stopped, ^reference}, 1_000
  end

  defp hold_connection(tasks) do
    owner = self()

    holder =
      Task.Supervisor.async_nolink(tasks, fn ->
        DBConnection.run(@db, fn _conn ->
          send(owner, {:held, self()})

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive {:held, pid}, 1_000
    assert pid == holder.pid
    holder
  end

  defp release_holder(holder) do
    if Process.alive?(holder.pid) do
      send(holder.pid, :release)
      assert :ok = Task.await(holder, 1_000)
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
