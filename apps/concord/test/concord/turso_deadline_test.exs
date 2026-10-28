defmodule Concord.TursoDeadlineTest do
  use ExUnit.Case, async: false

  alias Concord.KV.Record
  alias Concord.Turso.Codec

  @moduletag :tmp_dir
  @db Concord.Turso.DB

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ex_turso)
    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    stop_pool()

    start_supervised!(
      {Elixir.Turso, database: Path.join(tmp_dir, "deadline.db"), name: @db, pool_size: 1}
    )

    supervisor = start_supervised!(Task.Supervisor)
    on_exit(&stop_pool/0)
    %{tasks: supervisor}
  end

  test "a comparison cannot outwait its acquisition budget", %{tasks: tasks} do
    assert_timed_out_without_mutation(tasks, [{:exists, "deadline/key", :==, false}])
  end

  test "a write cannot commit after its acquisition budget expires", %{tasks: tasks} do
    assert_timed_out_without_mutation(tasks, [])
  end

  test "legacy writes and batch deletes retain the same acquisition deadline", %{tasks: tasks} do
    for operation <- [:put, :delete_many] do
      assert :ok = Concord.Turso.put("deadline/legacy", :original)
      assert {:ok, revision} = Concord.Turso.revision()
      holder = hold_connection(tasks, 400)

      try do
        started = System.monotonic_time(:millisecond)

        result =
          case operation do
            :put -> Concord.Turso.put("deadline/legacy", :unexpected, timeout: 20)
            :delete_many -> Concord.Turso.delete_many(["deadline/legacy"], timeout: 20)
          end

        assert result == {:error, :timeout}
        assert System.monotonic_time(:millisecond) - started < 200
      after
        release_connection(holder)
      end

      assert {:ok, :original} = Concord.Turso.get("deadline/legacy")
      assert {:ok, ^revision} = Concord.Turso.revision()
    end
  end

  test "brief contention succeeds within the original operation budget", %{tasks: tasks} do
    assert {:ok, %{revision: revision}} =
             Concord.KV.put("deadline/key", :original, engine: :turso)

    holder = hold_connection(tasks, 60)

    try do
      started = System.monotonic_time(:millisecond)

      assert {:ok, %Concord.Txn.Result{succeeded: true, revision: next_revision}} =
               Concord.Turso.txn(
                 %{
                   compare: [{:mod_revision, "deadline/key", :==, revision}],
                   success: [{:put, "deadline/key", :updated, %{}}],
                   failure: []
                 },
                 timeout: 500
               )

      assert next_revision == revision + 1
      assert System.monotonic_time(:millisecond) - started < 500
      assert {:ok, :updated} = Concord.Turso.get("deadline/key")
    after
      release_connection(holder)
    end
  end

  test "readiness and transaction statements share one checked-out connection and deadline" do
    assert :ok = Concord.Turso.put("deadline/key", :original)
    functions = [{Elixir.Turso, :query, 4}, {Elixir.Turso, :execute, 4}]
    owner = self()
    tracer = spawn_link(fn -> collect_options(owner, []) end)

    for function <- functions do
      assert :erlang.trace_pattern(function, true, [:local]) == 1
    end

    checkout = {DBConnection.ConnectionPool, :checkout, 3}
    assert :erlang.trace_pattern(checkout, true, [:call_count]) == 1
    assert :erlang.trace(self(), true, [:call, {:tracer, tracer}]) == 1

    try do
      {:call_count, before_count} = :erlang.trace_info(checkout, :call_count)

      assert {:ok, %Concord.Txn.Result{succeeded: true}} =
               Concord.Turso.txn(%{
                 compare: [],
                 success: [{:put, "deadline/key", :updated, %{}}],
                 failure: []
               })

      {:call_count, after_count} = :erlang.trace_info(checkout, :call_count)
      assert after_count - before_count == 1
      assert :erlang.trace(self(), false, [:call]) == 1
      delivered = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^delivered}
      send(tracer, :finish)
      assert_receive {:statement_options, options}
      assert [%DBConnection{} | _] = Enum.map(options, &elem(&1, 0))
      assert Enum.all?(options, &match?(%DBConnection{}, elem(&1, 0)))

      assert [deadline] =
               options |> Enum.map(&Keyword.fetch!(elem(&1, 1), :deadline)) |> Enum.uniq()

      assert is_integer(deadline)
      assert Enum.all?(options, &(Keyword.fetch!(elem(&1, 1), :timeout) == 5_000))
    after
      :erlang.trace(self(), false, [:call])
      for function <- functions, do: :erlang.trace_pattern(function, false, [:local])
      :erlang.trace_pattern(checkout, false, [:call_count])
      if Process.alive?(tracer), do: send(tracer, :finish)
    end
  end

  test "an exhausted migration budget does not start the application transaction" do
    seed_legacy_store()

    assert {:error, :timeout} =
             Concord.Turso.txn(
               %{compare: [], success: [{:put, "deadline/new", :unexpected, %{}}], failure: []},
               timeout: 1
             )

    assert {:ok, %{rows: [%{"value" => 1}]}} =
             Elixir.Turso.query(
               @db,
               "SELECT value FROM concord_turso_meta WHERE name = 'revision'"
             )

    assert {:ok, %{rows: []}} =
             Elixir.Turso.query(@db, "SELECT key FROM concord_turso_current WHERE key = ?", [
               "deadline/new"
             ])

    assert {:ok, %Concord.Txn.Result{succeeded: true, revision: 2}} =
             Concord.Turso.txn(
               %{
                 compare: [],
                 success: [{:put, "deadline/new", :after_upgrade, %{}}],
                 failure: []
               },
               timeout: 5_000
             )

    assert {:ok, :after_upgrade} = Concord.Turso.get("deadline/new")
  end

  defp assert_timed_out_without_mutation(tasks, compare) do
    assert {:ok, %{revision: revision}} =
             Concord.KV.put("deadline/key", :original, engine: :turso)

    holder = hold_connection(tasks, 400)

    try do
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               Concord.Turso.txn(
                 %{
                   compare: compare,
                   success: [{:put, "deadline/key", :unexpected, %{}}],
                   failure: []
                 },
                 timeout: 20
               )

      assert System.monotonic_time(:millisecond) - started < 200
    after
      release_connection(holder)
    end

    assert {:ok, :original} = Concord.Turso.get("deadline/key")
    assert {:ok, ^revision} = Concord.Turso.revision()

    assert {:ok, %Concord.Txn.Result{succeeded: true, revision: next_revision}} =
             Concord.Turso.txn(%{
               compare: [{:mod_revision, "deadline/key", :==, revision}],
               success: [{:put, "deadline/key", :after_timeout, %{}}],
               failure: []
             })

    assert next_revision == revision + 1
    assert {:ok, :after_timeout} = Concord.Turso.get("deadline/key")
  end

  defp hold_connection(supervisor, duration) do
    owner = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        DBConnection.run(@db, fn _conn ->
          send(owner, {:held, self()})

          receive do
            :release -> :ok
          after
            duration -> :ok
          end
        end)
      end)

    assert_receive {:held, pid}, 1_000
    assert pid == holder.pid
    holder
  end

  defp release_connection(holder) do
    send(holder.pid, :release)
    assert :ok = Task.await(holder, 1_000)
  end

  defp collect_options(owner, options) do
    receive do
      {:trace, _pid, :call, {Elixir.Turso, _function, [conn, _sql, _params, opts]}} ->
        collect_options(owner, [{conn, opts} | options])

      :finish ->
        send(owner, {:statement_options, options})
    end
  end

  defp seed_legacy_store do
    assert {:ok, :ok} =
             DBConnection.transaction(@db, fn conn ->
               assert {:ok, _} =
                        Elixir.Turso.execute(
                          conn,
                          "CREATE TABLE concord_turso_meta (name TEXT PRIMARY KEY, value INTEGER NOT NULL)"
                        )

               assert {:ok, _} =
                        Elixir.Turso.execute(
                          conn,
                          "INSERT INTO concord_turso_meta VALUES ('revision', 1)"
                        )

               assert {:ok, _} =
                        Elixir.Turso.execute(conn, """
                        CREATE TABLE concord_turso_current (
                          key TEXT PRIMARY KEY, record BLOB NOT NULL, expires_at INTEGER,
                          mod_revision INTEGER NOT NULL, version INTEGER NOT NULL
                        )
                        """)

               record = %Record{
                 value: :binary.copy("legacy payload", 40_000),
                 create_revision: 1,
                 mod_revision: 1,
                 version: 1
               }

               binary = Codec.encode_record(record)

               for index <- 1..32 do
                 assert {:ok, _} =
                          Elixir.Turso.execute(
                            conn,
                            "INSERT INTO concord_turso_current VALUES (?, ?, NULL, 1, 1)",
                            ["legacy/#{index}", {:blob, binary}]
                          )
               end

               :ok
             end)
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
