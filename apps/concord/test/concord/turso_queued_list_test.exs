defmodule Concord.TursoQueuedListTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Concord.Turso.{Codec, ListQueue, Migrations}

  @moduletag :tmp_dir
  @db Concord.Turso.DB
  @queue_tasks ListQueue.Tasks
  @checkout {DBConnection.ConnectionPool, :checkout, 3}
  @sql_functions [{Elixir.Turso, :query, 4}, {Elixir.Turso, :execute, 4}]
  @decode {Codec, :decode_record, 1}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ex_turso)
    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    stop_pool()

    start_supervised!(
      {Elixir.Turso, database: Path.join(tmp_dir, "queued_list.db"), name: @db, pool_size: 1}
    )

    start_supervised!({ListQueue, max_children: 2})
    tasks = start_supervised!(Task.Supervisor)
    on_exit(&stop_pool/0)
    assert {:ok, _} = KV.put("queued/a", "value", engine: :turso)
    %{tasks: tasks}
  end

  test "opt-in waiting succeeds after controlled brief contention within the original budget", %{
    tasks: tasks
  } do
    holder = hold_connection(tasks)

    try do
      {{result, worker}, calls, _decodes} =
        observed(tasks, fn ->
          request =
            Task.Supervisor.async_nolink(tasks, fn ->
              KV.list(engine: :turso, prefix: "queued/", queue: true, timeout: 1_000)
            end)

          try do
            assert_receive {:checkout_attempt, worker}, 1_000
            release_holder(holder)
            {Task.await(request, 1_000), worker}
          after
            stop_task(request)
          end
        end)

      assert {:ok, [%{key: "queued/a", value: "value"}], %{has_more: false, last_key: "queued/a"}} =
               result

      assert_shared_deadline(calls, worker)
    after
      release_holder(holder)
    end
  end

  test "a real 20ms queue deadline returns promptly and leaves admission and pool reusable", %{
    tasks: tasks
  } do
    holder = hold_connection(tasks)

    try do
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               KV.list(engine: :turso, prefix: "queued/", queue: true, timeout: 20)

      assert System.monotonic_time(:millisecond) - started < 200
      wait_until_empty()
    after
      release_holder(holder)
    end

    assert {:ok, [%{key: "queued/a"}], %{has_more: false}} =
             Concord.Turso.list(prefix: "queued/", queue: true, timeout: 500)

    wait_until_empty()
    assert {:ok, "value"} = Concord.Turso.get("queued/a")
  end

  test "default and explicit false remain immediate for finite and infinite timeouts", %{
    tasks: tasks
  } do
    holder = hold_connection(tasks)

    try do
      for opts <- [
            [timeout: 500],
            [timeout: :infinity],
            [queue: false, timeout: 500],
            [queue: false, timeout: :infinity]
          ] do
        started = System.monotonic_time(:millisecond)
        assert {:error, :timeout} = Concord.Turso.list(Keyword.merge([prefix: "queued/"], opts))
        assert System.monotonic_time(:millisecond) - started < 200
      end

      assert Task.Supervisor.children(@queue_tasks) == []
    after
      release_holder(holder)
    end
  end

  test "queue options reject unsupported values and require a finite positive timeout" do
    for queue <- [:wait, nil, 1, "true"] do
      assert {:error, :invalid_queue} =
               KV.list(engine: :turso, prefix: "queued/", queue: queue, timeout: 100)
    end

    for timeout <- [:infinity, 0, -1, nil, 1.5] do
      assert {:error, :invalid_queue_timeout} =
               Concord.Turso.list(prefix: "queued/", queue: true, timeout: timeout)
    end
  end

  test "two admitted waiters overload explicitly and a dead caller promptly frees capacity", %{
    tasks: tasks
  } do
    holder = hold_connection(tasks)

    try do
      {_result, _calls, _decodes} =
        observed(tasks, fn ->
          first = queued_request(tasks)

          try do
            assert_receive {:checkout_attempt, first_worker}, 1_000
            second = queued_request(tasks)

            try do
              assert_receive {:checkout_attempt, second_worker}, 1_000
              refute first_worker == second_worker
              assert length(Task.Supervisor.children(@queue_tasks)) == 2

              assert {:error, :overloaded} =
                       KV.list(engine: :turso, prefix: "queued/", queue: true, timeout: 500)

              monitor = Process.monitor(first_worker)
              started = System.monotonic_time(:millisecond)
              Task.shutdown(first, :brutal_kill)
              assert_receive {:DOWN, ^monitor, :process, ^first_worker, _reason}, 1_000
              assert System.monotonic_time(:millisecond) - started < 500
              wait_for_child_count(1)
              replacement = queued_request(tasks)

              try do
                assert_receive {:checkout_attempt, replacement_worker}, 1_000
                refute replacement_worker in [first_worker, second_worker]
                release_holder(holder)
                assert {:ok, [%{key: "queued/a"}], _} = Task.await(second, 1_000)
                assert {:ok, [%{key: "queued/a"}], _} = Task.await(replacement, 1_000)
              after
                stop_task(replacement)
              end
            after
              stop_task(second)
            end
          after
            stop_task(first)
          end
        end)
    after
      release_holder(holder)
    end

    wait_until_empty()
  end

  test "queued descending key-only reads retain large-value metadata and covering SQL", %{
    tasks: tasks
  } do
    value = :binary.copy("large uncompressed value", 100_000)
    assert byte_size(value) > 2_000_000
    metadata = %{source: "queued fixture", nested: %{binary: <<0, 255>>}}

    for key <- ["large/a", "large/a" <> <<0>>, "large/m", "large/z"] do
      assert {:ok, _} =
               KV.put(key, value,
                 engine: :turso,
                 compress: false,
                 metadata: metadata,
                 content_type: "application/octet-stream",
                 ttl: 3_600
               )
    end

    assert {:ok, full_records, cursor} =
             Concord.Turso.list(prefix: "large/", order: :desc, limit: 2)

    assert cursor == %{has_more: true, last_key: "large/m"}
    :ok = Migrations.migrate()
    holder = hold_connection(tasks)

    try do
      {{result, worker}, calls, decodes} =
        observed(tasks, fn ->
          request =
            Task.Supervisor.async_nolink(tasks, fn ->
              Concord.Turso.list(
                prefix: "large/",
                order: :desc,
                keys_only: true,
                limit: 2,
                queue: true,
                timeout: 1_000
              )
            end)

          try do
            assert_receive {:checkout_attempt, worker}, 1_000
            release_holder(holder)
            {Task.await(request, 1_000), worker}
          after
            stop_task(request)
          end
        end)

      assert result == {:ok, Enum.map(full_records, &Map.put(&1, :value, nil)), cursor}

      assert Enum.all?(
               full_records,
               &(&1.metadata == metadata and &1.content_type == "application/octet-stream")
             )

      assert decodes == 0
      assert_shared_deadline(calls, worker)

      assert [{:sql, ^worker, :query, _conn, sql, params, _opts}] =
               Enum.filter(calls, fn
                 {:sql, _pid, :query, _conn, sql, _params, _opts} ->
                   Regex.match?(~r/ORDER BY\s+key\s+DESC\s+LIMIT\s+\?/i, sql)

                 _ ->
                   false
               end)

      assert List.last(params) == 3
      assert String.contains?(sql, "INDEXED BY concord_turso_current_metadata")
      assert String.contains?(sql, "SELECT key, record_metadata")
      assert {:ok, %{rows: plan}} = Elixir.Turso.query(@db, "EXPLAIN QUERY PLAN " <> sql, params)
      assert Enum.any?(plan, &Regex.match?(~r/COVERING INDEX/i, &1["detail"]))

      for {:sql, _pid, _function, _conn, sql, _params, _opts} <- calls,
          [_, columns] <-
            Regex.scan(~r/SELECT\s+(.*?)\s+FROM\s+concord_turso_(?:current|history)\b/is, sql) do
        refute Regex.match?(~r/\b(?:record|value)\b|\*/, columns), sql
      end
    after
      release_holder(holder)
    end
  end

  defp assert_shared_deadline(calls, worker) do
    assert [{:checkout, ^worker, checkout_opts}] =
             Enum.filter(calls, &match?({:checkout, ^worker, _opts}, &1))

    deadline = Keyword.fetch!(checkout_opts, :deadline)
    assert is_integer(deadline)

    statements =
      for {:sql, ^worker, _function, conn, sql, _params, opts} <- calls, do: {conn, sql, opts}

    refute statements == []

    assert Enum.any?(statements, fn {_conn, sql, _opts} ->
             String.contains?(sql, "CREATE TABLE")
           end)

    for {conn, _sql, opts} <- statements do
      assert %DBConnection{} = conn
      assert Keyword.fetch!(opts, :deadline) == deadline
      assert Keyword.fetch!(opts, :timeout) == 1_000
      assert Keyword.fetch!(opts, :queue) == false
    end
  end

  defp queued_request(tasks) do
    Task.Supervisor.async_nolink(tasks, fn ->
      KV.list(engine: :turso, prefix: "queued/", queue: true, timeout: 2_000)
    end)
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

  defp stop_task(task) do
    if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
  end

  defp observed(tasks, fun) do
    owner = self()

    {:ok, tracer} =
      Task.Supervisor.start_child(tasks, fn -> collect_calls(owner, MapSet.new(), []) end)

    supervisor = Process.whereis(@queue_tasks)

    :erlang.trace_pattern(@checkout, [{:_, [], [{:return_trace}]}], [:local])
    for function <- @sql_functions, do: :erlang.trace_pattern(function, true, [:local])

    :erlang.trace_pattern(@decode, true, [:call_count])
    :erlang.trace(supervisor, true, [:call, :set_on_spawn, {:tracer, tracer}])

    try do
      result = fun.()
      delivered = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^delivered}, 1_000
      send(tracer, {:collect, self()})
      assert_receive {:calls, calls}, 1_000
      {:call_count, decodes} = :erlang.trace_info(@decode, :call_count)
      {result, calls, decodes}
    after
      :erlang.trace(supervisor, false, [:call, :set_on_spawn])

      for function <- [@checkout | @sql_functions],
          do: :erlang.trace_pattern(function, false, [:local])

      :erlang.trace_pattern(@decode, false, [:call_count])
      send(tracer, :stop)
    end
  end

  defp collect_calls(owner, seen, calls) do
    receive do
      {:trace, pid, :call, {DBConnection.ConnectionPool, :checkout, [_pool, _callers, opts]}} ->
        if MapSet.member?(seen, {pid, :call}) do
          collect_calls(owner, seen, calls)
        else
          collect_calls(owner, MapSet.put(seen, {pid, :call}), [{:checkout, pid, opts} | calls])
        end

      {:trace, pid, :return_from, @checkout,
       {:error,
        %DBConnection.ConnectionError{message: "connection not available and queuing is disabled"}}} ->
        if MapSet.member?(seen, {pid, :busy}) do
          collect_calls(owner, seen, calls)
        else
          send(owner, {:checkout_attempt, pid})
          collect_calls(owner, MapSet.put(seen, {pid, :busy}), calls)
        end

      {:trace, _pid, :return_from, @checkout, _result} ->
        collect_calls(owner, seen, calls)

      {:trace, pid, :call, {Elixir.Turso, function, [conn, sql, params, opts]}} ->
        collect_calls(owner, seen, [{:sql, pid, function, conn, sql, params, opts} | calls])

      {:collect, caller} ->
        send(caller, {:calls, Enum.reverse(calls)})
        collect_calls(owner, seen, calls)

      :stop ->
        :ok
    end
  end

  defp wait_until_empty, do: wait_for_child_count(0)

  defp wait_for_child_count(count),
    do: wait_for_child_count(count, System.monotonic_time(:millisecond) + 1_000)

  defp wait_for_child_count(count, deadline) do
    if length(Task.Supervisor.children(@queue_tasks)) == count do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(1)
      wait_for_child_count(count, deadline)
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
