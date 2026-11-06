defmodule Concord.TursoPrefixReplacementTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Concord.KV.Record
  alias Concord.Turso
  alias Concord.Turso.{Codec, Migrations}

  @moduletag :tmp_dir
  @db Concord.Turso.DB
  @decode {Codec, :decode_record, 1}
  @execute {Elixir.Turso, :execute, 4}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ex_turso)
    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    stop_pool()

    start_supervised!(
      {Elixir.Turso,
       database: Path.join(tmp_dir, "prefix_replacement.db"), name: @db, pool_size: 1}
    )

    tasks = start_supervised!(Task.Supervisor)
    on_exit(&stop_pool/0)
    %{tasks: tasks}
  end

  test "one publication couples metadata, removes stale keys and preserves retained-key history" do
    assert {:ok, %{revision: created}} =
             KV.put("turns/keep", :old,
               engine: :turso,
               metadata: %{source: "original"},
               content_type: "application/x-erlang"
             )

    assert {:ok, %{revision: stale_revision}} = KV.put("turns/stale", :stale, engine: :turso)
    assert {:ok, %{revision: before}} = KV.put("owner", %{generation: 1}, engine: :turso)
    assert {:ok, old_page, %{has_more: false}} = KV.list(engine: :turso, prefix: "turns/")

    assert {:ok, %{succeeded: true, revision: published, deleted: 1, written: 3}} =
             Turso.replace_prefix(
               "turns/",
               [{"turns/keep", :updated}, {"turns/new", :new}, {"owner", %{generation: 2}}],
               compare: [
                 {:mod_revision, "owner", :==, before},
                 {:field, "owner", [:generation], :==, 1}
               ]
             )

    assert published == before + 1
    assert {:ok, ^published} = KV.revision(engine: :turso)

    assert {:ok,
            %Record{
              value: :updated,
              create_revision: ^created,
              mod_revision: ^published,
              version: 2
            }} = KV.get("turns/keep", engine: :turso, metadata: true)

    for key <- ["turns/new", "owner"] do
      assert {:ok, %Record{mod_revision: ^published}} =
               KV.get(key, engine: :turso, metadata: true)
    end

    assert {:error, :not_found} = KV.get("turns/stale", engine: :turso)

    assert {:ok, ^old_page, %{has_more: false}} =
             KV.list(engine: :turso, prefix: "turns/", revision: before)

    assert {:ok, [%{key: "turns/keep", value: :updated}, %{key: "turns/new", value: :new}], _} =
             KV.list(engine: :turso, prefix: "turns/", revision: published)

    assert {:ok, %{generation: 1}} = KV.get("owner", engine: :turso, revision: before)
    assert {:ok, %{generation: 2}} = KV.get("owner", engine: :turso, revision: published)

    assert {:ok,
            [
              %Record{value: :old, mod_revision: ^created, version: 1},
              %Record{value: :updated, mod_revision: ^published, version: 2}
            ]} = KV.history("turns/keep", engine: :turso)

    assert {:ok,
            [
              %Record{value: :stale, mod_revision: ^stale_revision},
              %Record{value: nil, mod_revision: ^published, version: 0}
            ]} = KV.history("turns/stale", engine: :turso)

    assert {:ok, _} = KV.put("turns/keep", :later, engine: :turso)
    assert {:ok, :updated} = KV.get("turns/keep", engine: :turso, revision: published)
    assert {:ok, :old} = KV.get("turns/keep", engine: :turso, revision: before)
  end

  test "empty replacement atomically removes the prefix and preserves other namespaces" do
    assert {:ok, _} = KV.put("empty/a", :a, engine: :turso)
    assert {:ok, _} = KV.put("empty/b", :b, engine: :turso)
    assert {:ok, %{revision: before}} = KV.put("empty0", :outside, engine: :turso)

    assert {:ok, %{succeeded: true, revision: published, deleted: 2, written: 0}} =
             Turso.replace_prefix("empty/", [])

    assert published == before + 1
    assert {:ok, :outside} = KV.get("empty0", engine: :turso)
    assert {:ok, [], %{has_more: false}} = KV.list(engine: :turso, prefix: "empty/")

    assert {:ok, [%{key: "empty/a", value: :a}, %{key: "empty/b", value: :b}], _} =
             KV.list(engine: :turso, prefix: "empty/", revision: before)

    assert {:ok, [], %{has_more: false}} =
             KV.list(engine: :turso, prefix: "empty/", revision: published)

    assert {:ok, %{succeeded: true, deleted: 0, written: 0}} =
             Turso.replace_prefix("missing/", [])
  end

  test "all 500 puts and multi-megabyte values fit one publication outside generic transaction limits" do
    assert {:ok, %{revision: created}} = KV.put("bulk/001", :old, engine: :turso)
    assert {:ok, %{revision: before}} = KV.put("bulk/stale", :stale, engine: :turso)
    large = :binary.copy("large accepted value", 110_000)
    assert byte_size(large) > 1_000_000

    values =
      for n <- 1..499 do
        key = "bulk/" <> String.pad_leading(Integer.to_string(n), 3, "0")
        value = if n == 1, do: large, else: :binary.copy("small accepted value", 200)
        {key, value}
      end

    puts = values ++ [{"bulk-owner", %{published: true}}]
    assert :erlang.external_size(puts) > 1_000_000

    assert {:ok, %{succeeded: true, revision: published, deleted: 1, written: 500}} =
             Turso.replace_prefix("bulk/", puts, compress: false, timeout: 30_000)

    assert published == before + 1

    assert {:ok, [retained | added] = records, %{has_more: false}} =
             KV.list(engine: :turso, prefix: "bulk/", keys_only: true, limit: 1_000)

    assert Enum.map(records, & &1.key) == Enum.map(values, &elem(&1, 0))

    assert %{key: "bulk/001", create_revision: ^created, mod_revision: ^published, version: 2} =
             retained

    assert Enum.all?(added, &(&1.create_revision == published and &1.mod_revision == published))
    assert {:ok, ^large} = KV.get("bulk/001", engine: :turso)
    assert {:ok, %{published: true}} = KV.get("bulk-owner", engine: :turso, revision: published)
    assert {:error, :not_found} = KV.get("bulk/stale", engine: :turso)

    assert {:ok, %{succeeded: true, written: 1}} =
             Turso.replace_prefix("compressed/", [{"compressed/key", large}], compress: true)

    assert {:ok, ^large} = KV.get("compressed/key", engine: :turso)
  end

  test "failed owner comparisons leave records, revision, and histories unchanged" do
    assert {:ok, _} = KV.put("guarded/old", :original, engine: :turso)
    assert {:ok, %{revision: before}} = KV.put("owner", %{generation: 1}, engine: :turso)
    assert {:ok, old_history} = KV.history("guarded/old", engine: :turso)

    for compare <- [
          [{:mod_revision, "owner", :==, before - 1}],
          [{:exists, "missing-owner", :==, true}]
        ] do
      assert {:ok, %{succeeded: false, revision: ^before, deleted: 0, written: 0}} =
               Turso.replace_prefix("guarded/", [{"guarded/new", :new}, {"owner", :new}],
                 compare: compare
               )

      assert {:ok, ^before} = KV.revision(engine: :turso)
      assert {:ok, :original} = KV.get("guarded/old", engine: :turso)
      assert {:error, :not_found} = KV.get("guarded/new", engine: :turso)
      assert {:ok, %{generation: 1}} = KV.get("owner", engine: :turso)
      assert {:ok, ^old_history} = KV.history("guarded/old", engine: :turso)
    end
  end

  test "two writers fencing the same observed owner have exactly one publication winner", %{
    tasks: tasks
  } do
    assert {:ok, _} = KV.put("race/turn/old", :original, engine: :turso)
    assert {:ok, %{revision: before}} = KV.put("race/owner", :original, engine: :turso)

    requests =
      for id <- [1, 2] do
        request =
          Task.Supervisor.async_nolink(tasks, fn ->
            receive do
              :publish ->
                Turso.replace_prefix(
                  "race/turn/",
                  [{"race/turn/key", {:winner, id}}, {"race/owner", id}],
                  compare: [{:mod_revision, "race/owner", :==, before}],
                  timeout: 5_000
                )
            end
          end)

        {id, request}
      end

    try do
      for {_id, request} <- requests, do: send(request.pid, :publish)
      results = for {id, request} <- requests, do: {id, Task.await(request, 5_000)}

      for {_id, result} <- results, do: assert({:ok, %{succeeded: _succeeded}} = result)

      assert [
               {winner, {:ok, %{succeeded: true, revision: published, deleted: 1, written: 2}}}
             ] = Enum.filter(results, fn {_id, {:ok, result}} -> result.succeeded end)

      assert [
               {loser, {:ok, %{succeeded: false, revision: ^published, deleted: 0, written: 0}}}
             ] = Enum.reject(results, fn {_id, {:ok, result}} -> result.succeeded end)

      refute winner == loser
      assert published == before + 1
      assert {:ok, ^published} = KV.revision(engine: :turso)
      assert {:ok, ^winner} = KV.get("race/owner", engine: :turso)
      assert {:ok, {:winner, ^winner}} = KV.get("race/turn/key", engine: :turso)
      assert {:error, :not_found} = KV.get("race/turn/old", engine: :turso)
    after
      for {_id, request} <- requests,
          Process.alive?(request.pid),
          do: Task.shutdown(request, :brutal_kill)
    end
  end

  test "prefix replacement does not decode unrelated current or historical payloads" do
    assert {:ok, _} = KV.put("selected/stale", :stale, engine: :turso)
    assert {:ok, _} = KV.put("selected/keep", :old, engine: :turso)
    assert {:ok, _} = KV.put("unrelated/key", :old, engine: :turso)
    assert {:ok, _} = KV.put("unrelated/key", :new, engine: :turso)
    assert :ok = Migrations.migrate()

    for table <- ["concord_turso_current", "concord_turso_history"] do
      assert {:ok, _} =
               Elixir.Turso.execute(@db, "UPDATE #{table} SET record = ? WHERE key = ?", [
                 {:blob, "unrelated record must never be decoded"},
                 "unrelated/key"
               ])
    end

    assert {:ok, %{succeeded: true, deleted: 1, written: 2}} =
             Turso.replace_prefix("selected/", [
               {"selected/keep", :new},
               {"selected/added", :added}
             ])

    assert {:ok, [%{key: "selected/added", value: :added}, %{key: "selected/keep", value: :new}],
            _} =
             KV.list(engine: :turso, prefix: "selected/")
  end

  test "exact byte prefixes include maximal Unicode, NUL and 0xff suffixes without deleting siblings" do
    for prefix <- ["edge/", <<"binary/", 255>>, <<255, 255>>] do
      retained = prefix <> <<255, 0, 255>>

      selected = [
        prefix,
        prefix <> "ordinary",
        prefix <> <<0, 255>>,
        prefix <> <<0xF4, 0x8F, 0xBF, 0xBF>> <> "suffix",
        retained
      ]

      for key <- selected, do: assert({:ok, _} = KV.put(key, :original, engine: :turso))
      assert {:ok, _} = KV.put(prefix <> "extra", :also_selected, engine: :turso)
      sibling = binary_part(prefix, 0, byte_size(prefix) - 1)
      assert {:ok, _} = KV.put(sibling, :sibling, engine: :turso)
      assert {:ok, %{revision: before}} = KV.put("outside/" <> prefix, :outside, engine: :turso)

      assert {:ok, %{succeeded: true, deleted: 5, written: 2}} =
               Turso.replace_prefix(prefix, [{retained, :retained}, {prefix <> "new", :new}])

      for key <- selected -- [retained] do
        assert {:error, :not_found} = KV.get(key, engine: :turso)
        assert {:ok, :original} = KV.get(key, engine: :turso, revision: before)
      end

      assert {:ok, :retained} = KV.get(retained, engine: :turso)
      assert {:ok, :new} = KV.get(prefix <> "new", engine: :turso)
      assert {:ok, :sibling} = KV.get(sibling, engine: :turso)
      assert {:ok, :outside} = KV.get("outside/" <> prefix, engine: :turso)
    end
  end

  test "an unavailable connection exhausts one finite budget before any publication", %{
    tasks: tasks
  } do
    assert {:ok, %{revision: before}} = KV.put("admission/old", :original, engine: :turso)
    holder = hold_connection(tasks)

    try do
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               Turso.replace_prefix("admission/", [{"admission/new", :new}], timeout: 20)

      assert System.monotonic_time(:millisecond) - started < 500
    after
      release_holder(holder)
    end

    assert {:ok, ^before} = KV.revision(engine: :turso)
    assert {:ok, :original} = KV.get("admission/old", engine: :turso)
    assert {:error, :not_found} = KV.get("admission/new", engine: :turso)

    assert {:ok, %{succeeded: true, deleted: 1, written: 1}} =
             Turso.replace_prefix("admission/", [{"admission/new", :new}], timeout: 500)
  end

  test "expiry after the revision update rolls the complete replacement back before commit", %{
    tasks: tasks
  } do
    large = Enum.to_list(1..1_000_000)

    assert {:ok, %{revision: first}} =
             KV.put("rollback/stale", large, engine: :turso, compress: false)

    assert {:ok, _} = KV.put("rollback/keep", large, engine: :turso, compress: false)
    assert {:ok, %{revision: before}} = KV.put("rollback-owner", :original, engine: :turso)

    assert {:error, :timeout} =
             expire_inside_transaction(tasks, fn ->
               Turso.replace_prefix(
                 "rollback/",
                 [
                   {"rollback/keep", :updated},
                   {"rollback/new", :new},
                   {"rollback-owner", :updated}
                 ],
                 timeout: 500
               )
             end)

    assert {:ok, ^before} = KV.revision(engine: :turso)
    assert {:ok, ^large} = KV.get("rollback/stale", engine: :turso)
    assert {:ok, ^large} = KV.get("rollback/keep", engine: :turso)
    assert {:error, :not_found} = KV.get("rollback/new", engine: :turso)
    assert {:ok, :original} = KV.get("rollback-owner", engine: :turso)

    assert {:ok, [%Record{value: ^large, mod_revision: ^first}]} =
             KV.history("rollback/stale", engine: :turso)
  end

  defp expire_inside_transaction(tasks, fun) do
    owner = self()

    {:ok, tracer} =
      Task.Supervisor.start_child(tasks, fn ->
        Process.flag(:priority, :high)
        observe_expiry(owner, nil, false)
      end)

    tracer_monitor = Process.monitor(tracer)

    request =
      Task.Supervisor.async_nolink(tasks, fn ->
        Process.flag(:priority, :low)

        receive do
          :run -> fun.()
        end
      end)

    :erlang.trace_pattern(@execute, true, [:local])
    :erlang.trace_pattern(@decode, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(request.pid, true, [:call, {:tracer, tracer}])

    try do
      send(request.pid, :run)
      assert_receive {:paused, pid, state, deadline}, 2_000
      assert pid == request.pid

      assert state == :inside,
             "decode returned before suspension; the fixture did not overrun transaction work"

      remaining = max(deadline - System.monotonic_time(:millisecond), 0)
      timer = :erlang.start_timer(remaining + 10, self(), :operation_expired)
      assert_receive {:timeout, ^timer, :operation_expired}, 1_000
      send(tracer, {:resume, pid})
      assert_receive {:resumed, ^pid}, 1_000
      Task.await(request, 2_000)
    after
      if Process.alive?(request.pid) do
        send(tracer, {:resume, request.pid})
        Task.shutdown(request, :brutal_kill)
      end

      :erlang.trace_pattern(@execute, false, [:local])
      :erlang.trace_pattern(@decode, false, [:local])
      send(tracer, :stop)
      assert_receive {:DOWN, ^tracer_monitor, :process, ^tracer, _reason}, 1_000
    end
  end

  defp observe_expiry(owner, deadline, paused?) do
    receive do
      {:trace, _pid, :call, {Elixir.Turso, :execute, [_conn, sql, _params, opts]}} ->
        deadline =
          if Regex.match?(
               ~r/UPDATE\s+concord_turso_meta\s+SET\s+value\s*=\s*value\s*\+\s*1/i,
               sql
             ),
             do: Keyword.fetch!(opts, :deadline),
             else: deadline

        observe_expiry(owner, deadline, paused?)

      {:trace, pid, :call, {Codec, :decode_record, [_record]}}
      when is_integer(deadline) and not paused? ->
        true = :erlang.suspend_process(pid)
        delivered = :erlang.trace_delivered(pid)
        state = pause_state(pid, delivered, :inside)
        send(owner, {:paused, pid, state, deadline})
        observe_expiry(owner, deadline, true)

      {:trace, _pid, :call, {Codec, :decode_record, [_record]}} ->
        observe_expiry(owner, deadline, paused?)

      {:trace, _pid, :return_from, @decode, _result} ->
        observe_expiry(owner, deadline, paused?)

      {:resume, pid} ->
        resume_request(pid)
        send(owner, {:resumed, pid})
        observe_expiry(owner, deadline, paused?)

      :stop ->
        :ok
    end
  end

  defp pause_state(pid, delivered, state) do
    receive do
      {:trace, ^pid, :return_from, @decode, _result} ->
        pause_state(pid, delivered, :already_returned)

      {:trace_delivered, ^pid, ^delivered} ->
        state
    end
  end

  defp resume_request(pid) do
    :erlang.resume_process(pid)
  rescue
    ArgumentError -> :ok
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
