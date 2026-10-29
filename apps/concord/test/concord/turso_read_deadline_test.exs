defmodule Concord.TursoReadDeadlineTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Concord.KV.Record
  alias Concord.Turso.Codec

  @moduletag :tmp_dir
  @db Concord.Turso.DB
  @sql_functions [{Elixir.Turso, :query, 4}, {Elixir.Turso, :execute, 4}]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ex_turso)
    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    stop_pool()

    start_supervised!(
      {Elixir.Turso, database: Path.join(tmp_dir, "read_deadline.db"), name: @db, pool_size: 1}
    )

    tasks = start_supervised!(Task.Supervisor)
    on_exit(&stop_pool/0)
    %{tasks: tasks}
  end

  for readiness <- [:fresh, :ready], operation <- [:value, :metadata, :batch] do
    test "#{operation} reads retain a finite acquisition budget on a #{readiness} store", %{
      tasks: tasks
    } do
      if unquote(readiness) == :ready do
        assert {:ok, _} = KV.put("read/key", :original, engine: :turso)
      end

      holder = hold_connection(tasks)

      try do
        started = System.monotonic_time(:millisecond)
        assert {:error, :timeout} = read(unquote(operation), 20)
        assert System.monotonic_time(:millisecond) - started < 200
      after
        release_holder(holder)
      end

      assert {:ok, _} = KV.put("read/key", :after_timeout, engine: :turso)
      assert {:ok, :after_timeout} = Concord.Turso.get("read/key", timeout: 500)
    end
  end

  test "successful finite and infinite reads preserve values, metadata and historical revisions" do
    assert {:ok, %{revision: first}} =
             KV.put("read/key", :original,
               engine: :turso,
               metadata: %{source: "fixture"},
               content_type: "application/x-erlang"
             )

    assert {:ok, %{revision: second}} = KV.put("read/key", :updated, engine: :turso)
    assert second == first + 1

    for timeout <- [500, :infinity] do
      assert {:ok, :updated} = Concord.Turso.get("read/key", timeout: timeout)

      assert {:ok,
              %Record{
                value: :updated,
                create_revision: ^first,
                mod_revision: ^second,
                version: 2
              }} = KV.get("read/key", engine: :turso, metadata: true, timeout: timeout)

      assert {:ok, :original} =
               KV.get("read/key", engine: :turso, revision: first, timeout: timeout)

      assert {:ok,
              %{
                "read/key" => {:ok, :updated},
                "read/missing" => {:error, :not_found}
              }} = Concord.Turso.get_many(["read/key", "read/missing"], timeout: timeout)

      assert {:error, :not_found} = KV.get("read/missing", engine: :turso, timeout: timeout)
    end

    assert {:ok,
            [
              %Record{
                value: :original,
                mod_revision: ^first,
                metadata: %{source: "fixture"},
                content_type: "application/x-erlang"
              },
              %Record{value: :updated, mod_revision: ^second}
            ]} = KV.history("read/key", engine: :turso)
  end

  test "all batch keys and readiness share one connection and absolute deadline", %{tasks: tasks} do
    assert {:ok, _} = KV.put("read/key", :original, engine: :turso)

    {result, calls} =
      observed(tasks, nil, fn ->
        Concord.Turso.get_many(["read/key", "read/missing"], timeout: 500)
      end)

    assert {:ok, %{"read/key" => {:ok, :original}, "read/missing" => {:error, :not_found}}} =
             result

    statements = for {:sql, conn, _sql, _params, opts} <- calls, do: {conn, opts}
    refute statements == []

    identities =
      Enum.map(statements, fn {conn, _opts} ->
        assert %DBConnection{pool_ref: pool_ref, conn_ref: conn_ref} = conn
        {pool_ref, conn_ref}
      end)

    assert [_identity] = Enum.uniq(identities)

    assert [deadline] =
             statements |> Enum.map(&Keyword.fetch!(elem(&1, 1), :deadline)) |> Enum.uniq()

    assert is_integer(deadline)

    assert ["read/key", "read/missing"] =
             for(
               {:sql, _conn, sql, [key], _opts} <- calls,
               String.contains?(sql, "SELECT record FROM concord_turso_current"),
               do: key
             )
  end

  test "batch expiry during record decoding prevents reading subsequent keys", %{tasks: tasks} do
    value = Enum.to_list(1..1_000_000)
    assert {:ok, _} = KV.put("read/key", value, engine: :turso, compress: false)
    assert {:ok, _} = KV.put("read/later", :must_not_read, engine: :turso)

    {result, calls} =
      observed(tasks, {Codec, :decode_record, 1}, fn ->
        Concord.Turso.get_many(["read/key", "read/later"], timeout: 500)
      end)

    assert {:error, :timeout} = result

    refute Enum.any?(calls, fn
             {:sql, _conn, sql, ["read/later"], _opts} ->
               String.contains?(sql, "SELECT record FROM concord_turso_current")

             _ ->
               false
           end)
  end

  for operation <- [:value, :metadata] do
    test "#{operation} reads cannot acknowledge success after public decompression overruns", %{
      tasks: tasks
    } do
      value = Enum.to_list(1..1_000_000)
      assert {:ok, _} = KV.put("read/key", value, engine: :turso, compress: true)

      {result, _calls} =
        observed(tasks, {Concord.Compression, :decompress, 1}, fn ->
          read(unquote(operation), 500)
        end)

      assert {:error, :timeout} = result
    end
  end

  defp read(:value, timeout), do: Concord.Turso.get("read/key", timeout: timeout)

  defp read(:metadata, timeout),
    do: KV.get("read/key", engine: :turso, metadata: true, timeout: timeout)

  defp read(:batch, timeout), do: Concord.Turso.get_many(["read/key"], timeout: timeout)

  defp hold_connection(tasks) do
    owner = self()

    holder =
      Task.Supervisor.async_nolink(tasks, fn ->
        DBConnection.run(@db, fn _conn ->
          send(owner, {:held, self()})

          receive do
            :release -> :ok
          after
            400 -> :ok
          end
        end)
      end)

    assert_receive {:held, pid}, 1_000
    assert pid == holder.pid
    holder
  end

  defp release_holder(holder) do
    send(holder.pid, :release)
    assert :ok = Task.await(holder, 1_000)
  end

  defp observed(tasks, pause_at, fun) do
    owner = self()

    {:ok, tracer} =
      Task.Supervisor.start_child(tasks, fn ->
        Process.flag(:priority, :high)
        collect_calls(owner, pause_at, [])
      end)

    tracer_monitor = Process.monitor(tracer)

    request =
      Task.Supervisor.async_nolink(tasks, fn ->
        Process.flag(:priority, :low)

        receive do
          :run -> fun.()
        end
      end)

    functions = if pause_at, do: [pause_at | @sql_functions], else: @sql_functions
    for function <- @sql_functions, do: :erlang.trace_pattern(function, true, [:local])

    if pause_at do
      :erlang.trace_pattern(pause_at, [{:_, [], [{:return_trace}]}], [:local])
    end

    :erlang.trace(request.pid, true, [:call, {:tracer, tracer}])

    try do
      send(request.pid, :run)

      if pause_at do
        assert_receive {:pause_state, pid, state}, 2_000
        assert pid == request.pid

        assert state == :inside,
               "decode returned before suspension; the fixture did not inject a deadline overrun"

        Process.sleep(550)
        send(tracer, {:resume, pid})
        assert_receive {:resumed, ^pid}, 1_000
      end

      result = Task.await(request, 2_000)
      delivered = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^delivered}, 1_000
      send(tracer, :collect)
      assert_receive {:calls, calls}, 1_000
      {result, calls}
    after
      if Process.alive?(request.pid) do
        send(tracer, {:resume, request.pid})
        Task.shutdown(request, :brutal_kill)
      end

      for function <- functions, do: :erlang.trace_pattern(function, false, [:local])
      send(tracer, :stop)
      assert_receive {:DOWN, ^tracer_monitor, :process, ^tracer, _reason}, 1_000
    end
  end

  defp collect_calls(owner, pause_at, calls) do
    receive do
      {:trace, pid, :call, {module, function, args}}
      when {module, function, length(args)} == pause_at ->
        true = :erlang.suspend_process(pid)
        # Reject a missed scheduling window instead of testing a delayed task reply.
        delivered = :erlang.trace_delivered(pid)
        state = pause_state(pid, pause_at, delivered, :inside)
        send(owner, {:pause_state, pid, state})
        collect_calls(owner, nil, calls)

      {:trace, _pid, :return_from, _function, _result} ->
        collect_calls(owner, pause_at, calls)

      {:trace, _pid, :call, {Elixir.Turso, _function, [conn, sql, params, opts]}} ->
        collect_calls(owner, pause_at, [{:sql, conn, sql, params, opts} | calls])

      :collect ->
        send(owner, {:calls, Enum.reverse(calls)})
        collect_calls(owner, pause_at, calls)

      {:resume, pid} ->
        resume_request(pid)
        send(owner, {:resumed, pid})
        collect_calls(owner, pause_at, calls)

      :stop ->
        :ok
    end
  end

  defp pause_state(pid, function, delivered, state) do
    receive do
      {:trace, ^pid, :return_from, ^function, _result} ->
        pause_state(pid, function, delivered, :already_returned)

      {:trace_delivered, ^pid, ^delivered} ->
        state
    end
  end

  defp resume_request(pid) do
    :erlang.resume_process(pid)
  rescue
    ArgumentError -> :ok
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
