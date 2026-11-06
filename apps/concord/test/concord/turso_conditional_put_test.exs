defmodule Concord.TursoConditionalPutTest do
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
      {Elixir.Turso, database: Path.join(tmp_dir, "conditional_put.db"), name: @db, pool_size: 1}
    )

    tasks = start_supervised!(Task.Supervisor)
    on_exit(&stop_pool/0)
    %{tasks: tasks}
  end

  test "499 new turns and metadata publish at one revision without touching omitted records" do
    assert {:ok, _} = KV.put("session/turns/000", :earlier, engine: :turso)
    assert {:ok, _} = KV.put("session/config", :config, engine: :turso)
    assert {:ok, _} = KV.put("sibling/turns/001", :sibling, engine: :turso)

    assert {:ok, %{revision: before}} =
             KV.put("session/metadata", %{title: "Original"}, engine: :turso)

    assert {:ok, previous, _} = KV.list(prefix: "", engine: :turso)
    assert {:ok, old_history} = KV.history("session/turns/000", engine: :turso)
    large = :binary.copy("large accepted value", 110_000)

    turns =
      for n <- 1..499 do
        key = "session/turns/" <> String.pad_leading(Integer.to_string(n), 3, "0")
        {key, if(n == 1, do: large, else: %{turn: n})}
      end

    puts = turns ++ [{"session/metadata", %{title: "Updated"}}]
    assert :erlang.external_size(puts) > 1_000_000

    assert {:ok, %{succeeded: true, revision: published, written: 500}} =
             Turso.put_many_if(puts,
               compare: [{:mod_revision, "session/metadata", :==, before}],
               compress: false,
               engine: :local,
               timeout: 30_000
             )

    assert published == before + 1
    assert {:ok, ^published} = KV.revision(engine: :turso)
    assert {:ok, records, %{has_more: false}} = KV.list(prefix: "", engine: :turso, limit: 1_000)

    expected =
      previous
      |> Map.new(&{&1.key, &1.value})
      |> Map.merge(Map.new(puts))

    assert Map.new(records, &{&1.key, &1.value}) == expected

    for {key, value} <- turns do
      assert %{value: ^value, create_revision: ^published, mod_revision: ^published, version: 1} =
               Enum.find(records, &(&1.key == key))
    end

    assert {:ok, %Record{create_revision: ^before, mod_revision: ^published, version: 2}} =
             KV.get("session/metadata", engine: :turso, metadata: true)

    for record <- previous, record.key != "session/metadata" do
      assert record == Enum.find(records, &(&1.key == record.key))
    end

    assert {:ok, ^old_history} = KV.history("session/turns/000", engine: :turso)
    assert {:ok, ^previous, _} = KV.list(prefix: "", engine: :turso, revision: before)

    assert {:ok, ^records, _} =
             KV.list(prefix: "", engine: :turso, revision: published, limit: 1_000)

    assert {:error, :not_found} = KV.get("session/turns/001", engine: :turso, revision: before)
    assert {:ok, ^large} = KV.get("session/turns/001", engine: :turso, revision: published)

    assert {:ok, %{title: "Original"}} =
             KV.get("session/metadata", engine: :turso, revision: before)

    assert {:ok, [%Record{value: %{title: "Original"}}, %Record{value: %{title: "Updated"}}]} =
             KV.history("session/metadata", engine: :turso)

    assert {:ok, _} = KV.put("session/metadata", :later, engine: :turso)
    assert {:ok, _} = KV.delete("session/turns/001", engine: :turso)

    assert {:ok, ^records, _} =
             KV.list(prefix: "", engine: :turso, revision: published, limit: 1_000)
  end

  test "a confirmed conflict preserves data, revision and histories" do
    assert {:ok, _} = KV.put("turns/old", :original, engine: :turso)
    assert {:ok, %{revision: before}} = KV.put("metadata", :original, engine: :turso)
    assert {:ok, records, _} = KV.list(prefix: "", engine: :turso)
    assert {:ok, history} = KV.history("metadata", engine: :turso)

    assert {:ok, %{succeeded: false, revision: ^before, written: 0}} =
             Turso.put_many_if([{"turns/new", :new}, {"metadata", :updated}],
               compare: [{:mod_revision, "metadata", :==, before - 1}]
             )

    assert {:ok, ^before} = KV.revision(engine: :turso)
    assert {:ok, ^records, _} = KV.list(prefix: "", engine: :turso)
    assert {:ok, ^history} = KV.history("metadata", engine: :turso)
    assert {:ok, []} = KV.history("turns/new", engine: :turso)
  end

  test "two writers fencing the same metadata revision have exactly one winner", %{tasks: tasks} do
    assert {:ok, _} = KV.put("turns/old", :original, engine: :turso)
    assert {:ok, %{revision: before}} = KV.put("metadata", :original, engine: :turso)

    requests =
      for id <- [1, 2] do
        task =
          Task.Supervisor.async_nolink(tasks, fn ->
            receive do
              :publish ->
                Turso.put_many_if([{"turns/#{id}", id}, {"metadata", id}],
                  compare: [{:mod_revision, "metadata", :==, before}]
                )
            end
          end)

        {id, task}
      end

    try do
      for {_id, task} <- requests, do: send(task.pid, :publish)
      results = for {id, task} <- requests, do: {id, Task.await(task, 5_000)}
      for {_id, result} <- results, do: assert({:ok, %{succeeded: _}} = result)

      assert [{winner, {:ok, %{succeeded: true, revision: published, written: 2}}}] =
               Enum.filter(results, fn {_id, {:ok, result}} -> result.succeeded end)

      assert [{loser, {:ok, %{succeeded: false, revision: ^published, written: 0}}}] =
               Enum.reject(results, fn {_id, {:ok, result}} -> result.succeeded end)

      assert published == before + 1
      assert {:ok, ^winner} = KV.get("metadata", engine: :turso)
      assert {:ok, ^winner} = KV.get("turns/#{winner}", engine: :turso)
      assert {:error, :not_found} = KV.get("turns/#{loser}", engine: :turso)
      assert {:ok, :original} = KV.get("turns/old", engine: :turso)
    after
      for {_id, task} <- requests, Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end
  end

  test "empty batches compare without advancing the revision and support the transaction grammar" do
    assert {:ok, %{succeeded: true, revision: 0, written: 0}} = Turso.put_many_if([])
    assert {:ok, %{revision: before}} = KV.put("metadata", %{title: "Original"}, engine: :turso)

    compares = [
      {:exists, "metadata", :==, true},
      {:value, "metadata", :==, %{title: "Original"}},
      {:field, "metadata", [:title], :!=, "Updated"},
      {:version, "metadata", :>=, 1},
      {:create_revision, "metadata", :==, before},
      {:mod_revision, "metadata", :==, before},
      {:lease, "metadata", :==, nil},
      {:ttl, "metadata", :==, nil},
      {:exists, "missing", :==, false},
      {:mod_revision, "missing", :==, 0}
    ]

    assert {:ok, %{succeeded: true, revision: ^before, written: 0}} =
             Turso.put_many_if([], compare: compares)

    assert {:ok, %{succeeded: false, revision: ^before, written: 0}} =
             Turso.put_many_if([], compare: [{:exists, "missing", :==, true}])

    assert {:ok, ^before} = KV.revision(engine: :turso)

    value = %{text: :binary.copy("compressed", 1_000)}

    assert {:ok, %{succeeded: true, revision: published, written: 1}} =
             Turso.put_many_if([{"compressed", value}], compress: true, compare: compares)

    assert published == before + 1
    assert {:ok, ^value} = Turso.get("compressed")
  end

  test "overwrite and delete/recreate retain ordinary pair history and record semantics" do
    assert {:ok, %{revision: created}} =
             KV.put("key", :original,
               engine: :turso,
               ttl: 1_000,
               content_type: "text/plain",
               metadata: %{source: :old}
             )

    assert {:ok, %{succeeded: true, revision: updated, written: 1}} =
             Turso.put_many_if([{"key", :updated}])

    assert {:ok,
            %Record{
              value: :updated,
              create_revision: ^created,
              mod_revision: ^updated,
              version: 2,
              expires_at: nil,
              lease_id: nil,
              content_type: nil,
              metadata: %{}
            }} = KV.get("key", engine: :turso, metadata: true)

    assert {:ok, %{revision: deleted}} = KV.delete("key", engine: :turso)

    assert {:ok, %{succeeded: true, revision: recreated, written: 1}} =
             Turso.put_many_if([{"key", :recreated}], compare: [{:exists, "key", :==, false}])

    assert {:ok, %Record{create_revision: ^recreated, mod_revision: ^recreated, version: 1}} =
             KV.get("key", engine: :turso, metadata: true)

    assert {:ok,
            [
              %Record{value: :original, mod_revision: ^created, version: 1},
              %Record{value: :updated, mod_revision: ^updated, version: 2},
              %Record{value: nil, mod_revision: ^deleted, version: 0},
              %Record{value: :recreated, mod_revision: ^recreated, version: 1}
            ]} = KV.history("key", engine: :turso)

    assert {:ok, :original} = KV.get("key", engine: :turso, revision: created)
    assert {:ok, :updated} = KV.get("key", engine: :turso, revision: updated)
    assert {:error, :not_found} = KV.get("key", engine: :turso, revision: deleted)
  end

  test "warm append never decodes or rewrites omitted earlier transcript payloads" do
    assert {:ok, _} = KV.put("session/turns/old", :old, engine: :turso)
    assert {:ok, _} = KV.put("session/turns/old", :new, engine: :turso)
    assert {:ok, %{revision: before}} = KV.put("metadata", :original, engine: :turso)
    assert :ok = Migrations.migrate()
    invalid = "omitted transcript must never be decoded"

    for table <- ["concord_turso_current", "concord_turso_history"] do
      assert {:ok, _} =
               Elixir.Turso.execute(@db, "UPDATE #{table} SET record = ? WHERE key = ?", [
                 {:blob, invalid},
                 "session/turns/old"
               ])
    end

    assert {:ok, %{succeeded: true, written: 2}} =
             Turso.put_many_if([{"session/turns/new", :appended}, {"metadata", :updated}],
               compare: [{:mod_revision, "metadata", :==, before}]
             )

    assert {:ok, :appended} = KV.get("session/turns/new", engine: :turso)

    for table <- ["concord_turso_current", "concord_turso_history"] do
      assert {:ok, %{rows: [%{"record" => ^invalid}]}} =
               Elixir.Turso.query(@db, "SELECT record FROM #{table} WHERE key = ?", [
                 "session/turns/old"
               ])
    end
  end

  test "connection contention consumes one finite budget without publication", %{tasks: tasks} do
    assert {:ok, %{revision: before}} = KV.put("metadata", :original, engine: :turso)
    holder = hold_connection(tasks)

    try do
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               Turso.put_many_if([{"turns/new", :new}, {"metadata", :updated}], timeout: 20)

      assert System.monotonic_time(:millisecond) - started < 500
    after
      release_holder(holder)
    end

    assert {:ok, ^before} = KV.revision(engine: :turso)
    assert {:ok, :original} = KV.get("metadata", engine: :turso)
    assert {:error, :not_found} = KV.get("turns/new", engine: :turso)

    assert {:ok, %{succeeded: true, written: 1}} =
             Turso.put_many_if([{"turns/new", :new}], timeout: 500)
  end

  test "expiry during transaction work rolls back pairs, history and revision", %{tasks: tasks} do
    large = Enum.to_list(1..1_000_000)
    assert {:ok, %{revision: before}} = KV.put("metadata", large, engine: :turso, compress: false)

    assert {:error, :timeout} =
             expire_inside_transaction(tasks, fn ->
               Turso.put_many_if([{"turns/new", :new}, {"metadata", :updated}], timeout: 500)
             end)

    assert {:ok, ^before} = KV.revision(engine: :turso)
    assert {:ok, ^large} = KV.get("metadata", engine: :turso)
    assert {:error, :not_found} = KV.get("turns/new", engine: :turso)

    assert {:ok, [%Record{value: ^large, mod_revision: ^before}]} =
             KV.history("metadata", engine: :turso)

    assert {:ok, []} = KV.history("turns/new", engine: :turso)
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
    :exit, _reason -> :ok
  end
end
