defmodule Concord.RevisionCASTest do
  use ExUnit.Case, async: false

  alias Concord.CommandSchema
  alias Concord.Engine.{Local, VSR}
  alias Concord.KV
  alias Concord.KV.Record

  @moduletag :tmp_dir

  setup context do
    case context[:engine] do
      :local ->
        pid = Process.whereis(Local) || start_supervised!({Local, []})
        assert :ok = Local.reset()
        %{engine_pid: pid}

      :turso ->
        {:ok, _} = Application.ensure_all_started(:ex_turso)

        start_supervised!(
          {Elixir.Turso,
           database: Path.join(context.tmp_dir, "cas.db"), name: Concord.Turso.DB, pool_size: 1}
        )

        %{engine_pid: Process.whereis(Concord.Turso.DB)}

      :vsr ->
        {:ok, _} = Application.ensure_all_started(:viewstamped_replication)
        opts = vsr_opts(context.tmp_dir, 2)
        start_supervised!({VSR.Supervisor, opts})
        %{engine_pid: Process.whereis(VSR), vsr_opts: opts}

      nil ->
        :ok
    end
  end

  for engine <- [:local, :turso, :vsr] do
    describe "#{engine} revision CAS" do
      @describetag engine: engine

      test "large compressed and uncompressed values commit with bounded conflict acknowledgments",
           context do
        opts = [engine: context.engine, timeout: 30_000]
        old = String.duplicate("你好历史", 130_000)
        new = String.duplicate("new snapshot", 110_000)

        assert {:ok, %{succeeded: true, revision: first, current_kv: %Record{value: nil}}} =
                 KV.compare_and_swap("history", old, opts ++ [mod_revision: 0, compress: false])

        assert {:ok,
                %{succeeded: true, revision: second, current_kv: %Record{value: nil, version: 2}}} =
                 KV.compare_and_swap(
                   "history",
                   new,
                   opts ++ [mod_revision: first, compress: true]
                 )

        assert second == first + 1
        assert {:ok, ^new} = KV.get("history", opts)
        assert {:ok, ^old} = KV.get("history", opts ++ [revision: first])

        assert {:ok,
                %{
                  succeeded: false,
                  revision: ^second,
                  current_kv: %Record{value: nil, mod_revision: ^second}
                }} =
                 KV.compare_and_swap("history", :stale, opts ++ [mod_revision: first])

        assert {:ok, ^second} = KV.revision(opts)
        assert {:ok, ^new} = KV.get("history", opts)

        assert {:error, {:invalid_txn, :spec_too_large}} =
                 KV.update_if("history", new, opts ++ [mod_revision: second])
      end

      test "both encodings honor the16MiB logical value boundary", context do
        opts = [engine: context.engine, timeout: 30_000, mod_revision: 0]
        largest = :binary.copy("x", CommandSchema.max_value_bytes() - 6)
        assert :erlang.external_size(largest) == CommandSchema.max_value_bytes()
        oversized = largest <> "x"

        for compress <- [false, true] do
          key = "boundary/#{compress}"

          assert {:ok, %{succeeded: true}} =
                   KV.compare_and_swap(key, largest, opts ++ [compress: compress])

          assert {:error, :value_too_large} =
                   KV.compare_and_swap(key, oversized, opts ++ [compress: compress])

          assert {:ok, ^largest} = KV.get(key, engine: context.engine, timeout: 30_000)
        end
      end

      test "concurrent revision zero admits exactly one writer and deletion permits a new generation",
           context do
        opts = [engine: context.engine, timeout: 30_000, mod_revision: 0]

        results =
          1..8
          |> Enum.map(fn i -> Task.async(fn -> KV.compare_and_swap("race", i, opts) end) end)
          |> Task.await_many(30_000)

        assert Enum.count(results, &match?({:ok, %{succeeded: true}}, &1)) == 1
        assert Enum.count(results, &match?({:ok, %{succeeded: false}}, &1)) == 7
        assert {:ok, %{revision: deleted}} = KV.delete("race", engine: context.engine)

        assert {:ok, %{succeeded: true, revision: revision, current_kv: %Record{version: 1}}} =
                 KV.compare_and_swap("race", :recreated, opts)

        assert revision == deleted + 1
      end

      test "TTL/content metadata and revision conflicts use the ordinary put path", context do
        opts = [engine: context.engine]

        assert {:ok, %{succeeded: true, revision: first, current_kv: record}} =
                 KV.compare_and_swap(
                   "ttl",
                   :value,
                   opts ++
                     [
                       mod_revision: 0,
                       ttl: 1,
                       metadata: %{source: :cas},
                       content_type: "text/plain"
                     ]
                 )

        assert record.expires_at >= System.system_time(:second)
        assert record.metadata == %{source: :cas}
        assert record.content_type == "text/plain"
        assert :ok = wrapper(context.engine).touch("ttl", 10)

        assert {:ok, %{succeeded: false}} =
                 KV.compare_and_swap("ttl", :stale, opts ++ [mod_revision: first])

        assert {:ok, :value} = KV.get("ttl", opts)
      end

      test "expired values conflict at their old revision and can be replaced at revision zero",
           context do
        opts = [engine: context.engine]

        assert {:ok, %{succeeded: true, revision: first}} =
                 KV.compare_and_swap("expires", :before, opts ++ [mod_revision: 0, ttl: 1])

        Process.sleep(2_100)

        assert {:ok, %{succeeded: false, revision: ^first, current_kv: nil}} =
                 KV.compare_and_swap("expires", :unused, opts ++ [mod_revision: first])

        assert {:ok, %{succeeded: true, revision: second}} =
                 KV.compare_and_swap("expires", :after, opts ++ [mod_revision: 0, ttl: :infinity])

        assert second == first + 1
        assert {:ok, :after} = KV.get("expires", opts)
      end

      test "the public wrapper routes to its engine and timeout zero never mutates", context do
        api = wrapper(context.engine)

        assert {:error, :timeout} =
                 api.compare_and_swap("expired", :unused, mod_revision: 0, timeout: 0)

        assert {:error, :not_found} = KV.get("expired", engine: context.engine)

        assert {:ok, %{succeeded: true}} =
                 api.compare_and_swap("wrapper", :value, mod_revision: 0)
      end
    end
  end

  for engine <- [:local, :vsr] do
    @tag engine: engine
    test "#{engine} CAS maintains indexes, leases and revision history", %{engine: engine} do
      opts = [engine: engine]
      assert :ok = Concord.Index.create("cas-tags", {:map_get, :tag}, opts)
      assert {:ok, %{lease_id: lease}} = Concord.Lease.grant(60, opts)

      assert {:ok, %{succeeded: true, revision: first}} =
               KV.compare_and_swap(
                 "indexed",
                 %{tag: :old},
                 opts ++ [mod_revision: 0, lease: lease]
               )

      assert {:ok, ["indexed"]} = Concord.Index.lookup("cas-tags", :old, opts)
      assert {:ok, %{keys: ["indexed"]}} = Concord.Lease.info(lease, opts)

      assert {:ok, %{succeeded: true, revision: second}} =
               KV.compare_and_swap("indexed", %{tag: :new}, opts ++ [mod_revision: first])

      assert second == first + 1
      assert {:ok, []} = Concord.Index.lookup("cas-tags", :old, opts)
      assert {:ok, ["indexed"]} = Concord.Index.lookup("cas-tags", :new, opts)
      assert {:ok, %{keys: []}} = Concord.Lease.info(lease, opts)
      assert {:ok, %{deleted_keys: 0}} = Concord.Lease.revoke(lease, opts)
      assert {:ok, %{tag: :new}} = KV.get("indexed", opts)
      assert {:ok, %{tag: :old}} = KV.get("indexed", opts ++ [revision: first])
    end

    @tag engine: engine
    test "#{engine} queued CAS expires before admission", %{engine: engine, engine_pid: pid} do
      # Seed readiness before deliberately suspending the engine mailbox.
      assert {:ok, %{succeeded: true, revision: revision}} =
               KV.compare_and_swap("queued", :before, engine: engine, mod_revision: 0)

      :sys.suspend(pid)

      try do
        task =
          Task.async(fn ->
            KV.compare_and_swap("queued", :late,
              engine: engine,
              mod_revision: revision,
              timeout: 20
            )
          end)

        assert {:error, :timeout} = Task.await(task, 1_000)
      after
        :sys.resume(pid)
      end

      assert {:ok, :before} = KV.get("queued", engine: engine)
      assert {:ok, ^revision} = KV.revision(engine: engine)
    end
  end

  @tag engine: :turso
  test "Turso pool acquisition uses the original API deadline" do
    assert {:ok, %{succeeded: true, revision: revision}} =
             Concord.Turso.compare_and_swap("held", :before, mod_revision: 0)

    owner = self()

    holder =
      Task.async(fn ->
        DBConnection.run(Concord.Turso.DB, fn _ ->
          send(owner, :held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :held

    try do
      assert {:error, :timeout} =
               Concord.Turso.compare_and_swap("held", :late, mod_revision: revision, timeout: 20)
    after
      send(holder.pid, :release)
      assert :ok = Task.await(holder)
    end

    assert {:ok, :before} = Concord.Turso.get("held")
    assert {:ok, ^revision} = Concord.Turso.revision()

    assert {:error, :unsupported_operation} =
             Concord.Turso.compare_and_swap("lease", :value, mod_revision: 0, lease: 1)
  end

  test "writers zero and one reject CAS without appending", %{tmp_dir: tmp_dir} do
    {:ok, _} = Application.ensure_all_started(:viewstamped_replication)

    for version <- [0, 1] do
      opts = vsr_opts(Path.join(tmp_dir, to_string(version)), version)
      pid = start_supervised!({VSR.Supervisor, opts})
      assert {:ok, before} = ViewstampedReplication.status(opts[:group_id], 1)

      assert {:error, {:command_version_required, 2}} =
               Concord.compare_and_swap("key", "value", mod_revision: 0)

      assert {:ok, after_status} = ViewstampedReplication.status(opts[:group_id], 1)
      assert after_status.op_number == before.op_number
      assert after_status.commit_number == before.commit_number
      assert Process.alive?(pid)
      stop_supervised!(VSR.Supervisor)
    end
  end

  @tag engine: :vsr
  test "writer two keeps old conditional and batch APIs coherent and replays after restart", %{
    vsr_opts: opts
  } do
    assert {:ok, %{succeeded: true}} = Concord.compare_and_swap("coherent", :one, mod_revision: 0)
    assert :ok = Concord.put_if("coherent", :two, expected: :one)
    assert {:ok, record} = KV.get("coherent", metadata: true)

    assert {:ok, %{succeeded: true, revision: revision}} =
             Concord.compare_and_swap("coherent", :three, mod_revision: record.mod_revision)

    assert {:ok, %{"coherent" => :ok}} = Concord.put_many([{"coherent", :four}])
    assert {:ok, record} = KV.get("coherent", metadata: true)
    assert record.mod_revision > revision
    assert record.value == :four
    stop_supervised!(VSR.Supervisor)
    start_supervised!({VSR.Supervisor, Keyword.put(opts, :bootstrap, false)})
    assert {:ok, :four} = Concord.get("coherent")

    assert {:ok, %{succeeded: true}} =
             Concord.compare_and_swap("coherent", :five, mod_revision: record.mod_revision)

    assert {:ok, :three} = KV.get("coherent", revision: revision)
  end

  test "required revision and invalid metadata fail before engine admission" do
    for expected <- [nil, -1, "0"] do
      assert {:error, :invalid_mod_revision} =
               Concord.compare_and_swap("key", "value", mod_revision: expected)
    end

    assert {:error, :invalid_mod_revision} = Concord.compare_and_swap("key", "value")

    assert {:error, :unsupported_command} =
             Concord.compare_and_swap("key", "value", mod_revision: 0, metadata: nil)
  end

  @tag engine: :local
  test "the Local.KV wrapper uses the same strict CAS API" do
    assert {:ok, %{succeeded: true, current_kv: %Record{value: nil}}} =
             Concord.Local.KV.compare_and_swap("local-kv", :value, mod_revision: 0)

    assert {:ok, :value} = Concord.Local.KV.get("local-kv")

    assert {:error, :pid_in_spec} =
             Concord.Local.KV.compare_and_swap("pid", self(), mod_revision: 0)
  end

  test "writer two preserves both legacy readiness gates before admitting CAS", %{
    tmp_dir: directory
  } do
    {:ok, _} = Application.ensure_all_started(:viewstamped_replication)
    opts = vsr_opts(directory, 0)
    start_supervised!({VSR.Supervisor, opts})
    extractor = fn value -> Map.get(value, :tag) end

    assert {:ok, :ok} =
             ViewstampedReplication.command(
               opts[:group_id],
               {:concord_command, 1_000, {:create_index, "legacy-tags", extractor}},
               client: VSR.Client
             )

    assert :ok = Concord.put("legacy", %{tag: :old})
    stop_supervised!(VSR.Supervisor)

    start_supervised!(
      {VSR.Supervisor, opts |> Keyword.put(:command_version, 2) |> Keyword.put(:bootstrap, false)}
    )

    assert {:error, {:legacy_indexes_require_migration, ["legacy-tags"]}} =
             Concord.compare_and_swap("new", :value, mod_revision: 0)

    assert :ok = Concord.Index.drop("legacy-tags")

    assert {:error, {:legacy_state_requires_reconciliation, %{required: true}}} =
             Concord.compare_and_swap("new", :value, mod_revision: 0)

    assert {:ok, {:ok, %{reconciled: 0}}} = VSR.command(:reconcile_legacy_state)
    assert :ok = Concord.Index.create("tags", {:map_get, :tag}, reindex: true)
    assert {:ok, %{mod_revision: revision}} = KV.get("legacy", metadata: true)

    assert {:ok, %{succeeded: true}} =
             Concord.compare_and_swap("legacy", %{tag: :new}, mod_revision: revision)

    assert {:ok, []} = Concord.Index.lookup("tags", :old)
    assert {:ok, ["legacy"]} = Concord.Index.lookup("tags", :new)

    assert {:ok, %{command_version: 2, storage: %{legacy_state_representation: :current}}} =
             Concord.status()
  end

  defp wrapper(:local), do: Concord.Local
  defp wrapper(:turso), do: Concord.Turso
  defp wrapper(:vsr), do: Concord

  defp vsr_opts(directory, version) do
    group = {:revision_cas, System.unique_integer([:positive])}

    [
      group_id: group,
      replica_id: 1,
      members: [%{id: 1, endpoint: {:local_test_endpoint, group}}],
      transport: :local,
      storage: :file,
      storage_path: directory,
      bootstrap: true,
      retry_timeout: 10,
      command_version: version
    ]
  end
end
