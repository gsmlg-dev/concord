defmodule Concord.VSRIntegrationTest do
  use ExUnit.Case, async: false

  alias Concord.Engine
  alias Concord.KV.Record
  alias Concord.Sync.Event
  alias ViewstampedReplication.Replica

  setup_all do
    {:ok, _started} = Application.ensure_all_started(:viewstamped_replication)
    :ok
  end

  setup context do
    start_unless_running(Concord.Sync.WatchHub)
    start_unless_running(Concord.Sync.Dispatcher)

    previous_vsr = Application.fetch_env(:concord, :vsr)
    group_id = {:concord_vsr_test, System.unique_integer([:positive, :monotonic])}
    member_endpoint = {:local_test_endpoint, group_id}

    opts =
      [
        group_id: group_id,
        replica_id: 1,
        members: [%{id: 1, endpoint: member_endpoint}],
        transport: :local,
        storage: if(context[:tmp_dir], do: :file, else: :memory),
        storage_path: context[:tmp_dir],
        bootstrap: true,
        retry_timeout: 10,
        client_id: {:concord_vsr_test_client, group_id, 1}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    Application.put_env(:concord, :vsr, opts)

    {:ok, supervisor} = Engine.VSR.Supervisor.start_link(opts)
    Process.unlink(supervisor)

    on_exit(fn ->
      stop_supervisor(supervisor)
      restore_env(:vsr, previous_vsr)
    end)

    {:ok,
     group_id: group_id,
     replica_id: 1,
     member_endpoint: member_endpoint,
     supervisor: supervisor,
     vsr_opts: opts}
  end

  test "the feature-selected singleton serves the public Concord API", %{
    member_endpoint: configured_endpoint
  } do
    assert :ok = Concord.put("vsr:public", %{value: 1})
    assert {:ok, %{value: 1}} = Concord.get("vsr:public")

    assert :ok = Concord.put("vsr:public", %{value: 2})
    assert {:ok, %{value: 2}} = Concord.get("vsr:public")

    assert :ok = Concord.delete("vsr:public")
    assert {:error, :not_found} = Concord.get("vsr:public")

    assert {:ok,
            %{
              engine: :vsr,
              command_version: 0,
              wal_version: 1,
              node: current_node,
              cluster: %{replica_id: 1, status: :normal, primary_id: 1},
              storage: storage
            }} = Concord.status()

    assert current_node == node()
    assert is_map(storage)
    assert {:ok, [{1, member_endpoint}]} = Concord.members()
    assert member_endpoint == configured_endpoint
  end

  test "unsupported commands are rejected before advancing the replicated log", %{
    group_id: group_id,
    replica_id: replica_id
  } do
    assert {:ok, before_status} = ViewstampedReplication.status(group_id, replica_id)
    assert {:error, :unsupported_command} = Engine.VSR.command({:future_command, :payload})
    assert {:ok, after_status} = ViewstampedReplication.status(group_id, replica_id)

    assert after_status.op_number == before_status.op_number
    assert after_status.commit_number == before_status.commit_number
  end

  test "malformed reads do not kill the replica or advance the replicated log", %{
    group_id: group_id,
    replica_id: replica_id
  } do
    replica = Replica.whereis(group_id, replica_id)
    assert is_pid(replica)
    assert {:ok, before_status} = ViewstampedReplication.status(group_id, replica_id)

    malformed_queries = [
      {:history, "key", %{}},
      {:list, {:prefix, :not_a_binary}, %{limit: 1}},
      {:get, "key", revision: :latest},
      {:index_lookup, <<255>>, "value"},
      {:get_many, ["key", :not_a_key]}
    ]

    Enum.each(malformed_queries, fn query ->
      assert {:error, :unsupported_query} = Engine.VSR.query(query)

      assert {:ok, {:error, :unsupported_query}} =
               Replica.read(
                 replica,
                 {:concord_query, System.system_time(:millisecond), query},
                 timeout: 1_000
               )
    end)

    assert {:ok, {:error, {:invalid_query, :pid_in_spec}}} =
             Replica.read(
               replica,
               {:concord_query, System.system_time(:millisecond),
                {:index_lookup, "index", self()}},
               timeout: 1_000
             )

    assert {:ok, {:error, :invalid_query_envelope}} =
             Replica.read(
               replica,
               {:concord_query, -1, :stats},
               timeout: 1_000
             )

    assert Process.alive?(replica)
    assert Replica.whereis(group_id, replica_id) == replica

    assert {:ok, after_status} = ViewstampedReplication.status(group_id, replica_id)
    assert after_status.op_number == before_status.op_number
    assert after_status.commit_number == before_status.commit_number
    assert after_status.applied_number == before_status.applied_number
  end

  test "valid history queries keep transport options outside the fixed query payload" do
    assert {:ok, %{revision: revision}} = Concord.KV.put("history-options", "value")

    assert {:ok, [%Record{value: "value", mod_revision: ^revision}]} =
             Concord.KV.history("history-options",
               from_revision: revision,
               to_revision: revision,
               limit: 1,
               consistency: :strong,
               timeout: 1_000
             )
  end

  test "the version-zero writer rejects reconciliation before advancing the log", %{
    group_id: group_id,
    replica_id: replica_id
  } do
    assert {:ok, before_status} = ViewstampedReplication.status(group_id, replica_id)

    assert {:error, {:command_version_required, 1}} =
             Engine.VSR.command(:reconcile_legacy_state)

    assert {:ok, after_status} = ViewstampedReplication.status(group_id, replica_id)
    assert after_status.op_number == before_status.op_number
    assert after_status.commit_number == before_status.commit_number
  end

  test "a configured client identity base gets a fresh incarnation after restart", %{
    group_id: group_id
  } do
    client_id_base = {:concord_vsr_test_client, group_id, 1}
    original_client = Process.whereis(Concord.Engine.VSR.Client)

    assert %{client_id: {^client_id_base, original_incarnation}} =
             ViewstampedReplication.Client.status(original_client)

    assert byte_size(original_incarnation) == 16
    assert :ok = Concord.put("client-restart:first", "first")

    Process.exit(original_client, :kill)
    restarted_client = wait_for_client_restart(original_client)
    assert :ok = Concord.TestHelper.wait_for_cluster_ready()

    assert %{client_id: {^client_id_base, restarted_incarnation}} =
             ViewstampedReplication.Client.status(restarted_client)

    assert byte_size(restarted_incarnation) == 16
    refute restarted_incarnation == original_incarnation

    assert :ok = Concord.put("client-restart:second", "second")
    assert {:ok, "first"} = Concord.get("client-restart:first")
    assert {:ok, "second"} = Concord.get("client-restart:second")
  end

  test "default client identities are unique for child and supervisor incarnations", %{
    supervisor: supervisor,
    vsr_opts: opts
  } do
    stop_supervisor(supervisor)
    default_opts = Keyword.delete(opts, :client_id)
    Application.put_env(:concord, :vsr, default_opts)

    {:ok, first_supervisor} = Engine.VSR.Supervisor.start_link(default_opts)
    Process.unlink(first_supervisor)
    on_exit(fn -> stop_supervisor(first_supervisor) end)

    first_client = Process.whereis(Concord.Engine.VSR.Client)
    %{client_id: first_client_id} = ViewstampedReplication.Client.status(first_client)

    Process.exit(first_client, :kill)
    restarted_client = wait_for_client_restart(first_client)
    %{client_id: restarted_client_id} = ViewstampedReplication.Client.status(restarted_client)

    stop_supervisor(first_supervisor)

    {:ok, second_supervisor} = Engine.VSR.Supervisor.start_link(default_opts)
    Process.unlink(second_supervisor)
    on_exit(fn -> stop_supervisor(second_supervisor) end)

    %{client_id: second_supervisor_client_id} =
      ViewstampedReplication.Client.status(Concord.Engine.VSR.Client)

    client_ids = [first_client_id, restarted_client_id, second_supervisor_client_id]

    Enum.each(client_ids, fn client_id ->
      assert {Concord.Engine.VSR, incarnation} = client_id
      assert byte_size(incarnation) == 16
    end)

    assert [_first, _restarted, _second_supervisor] = Enum.uniq(client_ids)
  end

  test "quorum failures remain distinguishable from caller timeouts", %{
    supervisor: supervisor
  } do
    stop_supervisor(supervisor)
    group_id = {:concord_vsr_quorum_error, System.unique_integer([:positive, :monotonic])}

    opts = [
      group_id: group_id,
      replica_id: 1,
      members: [
        %{id: 1, endpoint: {:local_test_endpoint, group_id, 1}},
        %{id: 2, endpoint: {:local_test_endpoint, group_id, 2}}
      ],
      transport: :local,
      storage: :memory,
      bootstrap: true,
      retry_timeout: 10,
      client_id: {:concord_vsr_quorum_error_client, group_id}
    ]

    Application.put_env(:concord, :vsr, opts)
    {:ok, minority_supervisor} = Engine.VSR.Supervisor.start_link(opts)
    Process.unlink(minority_supervisor)
    on_exit(fn -> stop_supervisor(minority_supervisor) end)

    assert {:error, :quorum_unavailable} =
             Concord.get("unavailable", consistency: :strong, timeout: 50)
  end

  test "all advertised read consistencies use non-log-growing linearizable reads", %{
    group_id: group_id,
    replica_id: replica_id
  } do
    assert :ok = Concord.put("vsr:consistent", "committed")

    Enum.each([:eventual, :leader, :strong], fn consistency ->
      assert {:ok, before_status} = ViewstampedReplication.status(group_id, replica_id)
      assert {:ok, "committed"} = Concord.get("vsr:consistent", consistency: consistency)
      assert {:ok, after_status} = ViewstampedReplication.status(group_id, replica_id)

      assert after_status.op_number == before_status.op_number
      assert after_status.commit_number == before_status.commit_number
      assert after_status.applied_number == before_status.applied_number
    end)
  end

  test "VSR supplies command timestamps and read-barrier timestamps to TTL operations" do
    before_put = System.system_time(:second)
    assert {:ok, %{revision: revision}} = Concord.KV.put("vsr:ttl", "value", ttl: 30)
    after_put = System.system_time(:second)

    assert {:ok, %Record{expires_at: expires_at, mod_revision: ^revision}} =
             Concord.KV.get("vsr:ttl", metadata: true, consistency: :strong)

    assert expires_at >= before_put + 30
    assert expires_at <= after_put + 30
    assert {:ok, ttl} = Concord.ttl("vsr:ttl", consistency: :strong)
    assert ttl in 29..30

    assert {:ok, {"value", ttl_with_value}} =
             Concord.get_with_ttl("vsr:ttl", consistency: :strong)

    assert ttl_with_value in 29..30
  end

  test "the default v0 writer canonicalizes infinite TTLs before replication" do
    assert {:ok, %{command_version: 0}} = Concord.status()

    assert {:ok, %{revision: 1}} =
             Concord.KV.put("vsr:infinite-ttl", "value", ttl: :infinity)

    assert {:ok, %Record{expires_at: nil}} =
             Concord.KV.get("vsr:infinite-ttl", metadata: true, consistency: :strong)

    assert {:ok, %Concord.Txn.Result{succeeded: true}} =
             Concord.Txn.commit(%{
               success: [
                 {:put, "vsr:txn-infinite-ttl", "value", %{ttl: :infinity}}
               ]
             })

    assert {:ok, %Record{expires_at: nil}} =
             Concord.KV.get("vsr:txn-infinite-ttl", metadata: true, consistency: :strong)
  end

  test "lease timestamps and revocation run through the replicated VSR state" do
    assert {:ok, %{lease_id: lease_id, ttl: 30}} = Concord.Lease.grant(30)
    assert {:ok, %{revision: 2}} = Concord.KV.put("vsr:leased", "value", lease: lease_id)

    assert {:ok, %{id: ^lease_id, ttl: 30, remaining: remaining, keys: ["vsr:leased"]}} =
             Concord.Lease.info(lease_id)

    assert remaining in 29..30
    assert {:ok, %{deleted_keys: 1}} = Concord.Lease.revoke(lease_id)
    assert {:error, :not_found} = Concord.KV.get("vsr:leased", consistency: :strong)
    assert {:error, :lease_not_found} = Concord.Lease.info(lease_id)
  end

  test "concurrent public writes are serialized into one revision order" do
    writes = 20

    results =
      1..writes
      |> Task.async_stream(
        fn value -> Concord.KV.put("vsr:serialized", value) end,
        max_concurrency: writes,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, %{revision: _revision}}}, &1))

    assert {:ok,
            %Record{
              version: ^writes,
              mod_revision: ^writes,
              create_revision: 1
            }} = Concord.KV.get("vsr:serialized", metadata: true, consistency: :strong)

    assert {:ok, revision} = Concord.KV.revision(consistency: :strong)
    assert revision == writes
  end

  test "secondary index create and lookup use the VSR engine" do
    assert :ok = Concord.Index.create("vsr_by_email", {:map_get, :email})
    assert :ok = Concord.put("vsr:user:1", %{email: "user@example.com"})

    assert {:ok, ["vsr:user:1"]} =
             Concord.Index.lookup("vsr_by_email", "user@example.com")
  end

  test "secondary index reindex rebuilds existing VSR data" do
    assert :ok = Concord.put("vsr:user:before-index", %{email: "existing@example.com"})
    assert :ok = Concord.Index.create("vsr_reindex_email", {:map_get, :email})
    assert {:ok, []} = Concord.Index.lookup("vsr_reindex_email", "existing@example.com")

    assert :ok = Concord.Index.reindex("vsr_reindex_email")

    assert {:ok, ["vsr:user:before-index"]} =
             Concord.Index.lookup("vsr_reindex_email", "existing@example.com")
  end

  test "committed VSR puts and deletes each publish one complete Watch event" do
    key = "vsr:watched"
    {:ok, watch_ref} = Concord.Sync.watch({:key, key})

    assert {:ok, %{revision: 1}} = Concord.KV.put(key, "first")

    assert_receive {:concord_event, ^watch_ref,
                    %Event{
                      type: :put,
                      key: ^key,
                      revision: 1,
                      record:
                        %Record{
                          value: "first",
                          create_revision: 1,
                          mod_revision: 1,
                          version: 1
                        } = first_record,
                      prev_record: nil
                    }},
                   500

    refute_receive {:concord_event, ^watch_ref, _duplicate_put}, 50

    assert {:ok, %{revision: 2}} = Concord.KV.delete(key, prev_kv: true)

    assert_receive {:concord_event, ^watch_ref,
                    %Event{
                      type: :delete,
                      key: ^key,
                      revision: 2,
                      record: %Record{
                        value: nil,
                        create_revision: 1,
                        mod_revision: 2,
                        version: 0
                      },
                      prev_record: ^first_record
                    }},
                   500

    refute_receive {:concord_event, ^watch_ref, _duplicate_delete}, 50
    assert :ok = Concord.Sync.unwatch(watch_ref)
  end

  test "failed and read-only replicated operations publish no Watch events" do
    key = "vsr:watched-noop"
    {:ok, watch_ref} = Concord.Sync.watch({:key, key})

    assert {:ok, %{succeeded: false, revision: 0}} =
             Concord.KV.update_if(key, "replacement", mod_revision: 1)

    assert {:ok, %{revision: 0, prev_kv: nil}} = Concord.KV.delete(key, prev_kv: true)
    assert {:error, :not_found} = Concord.KV.get(key, consistency: :strong)

    refute_receive {:concord_event, ^watch_ref, _event}, 150
    assert :ok = Concord.Sync.unwatch(watch_ref)
  end

  @tag :tmp_dir
  test "a checkpointed singleton restores through the VSR file storage", %{
    group_id: group_id,
    replica_id: replica_id,
    supervisor: supervisor,
    vsr_opts: opts
  } do
    assert :ok = Concord.put("vsr:durable", %{restored: true})
    assert :ok = ViewstampedReplication.snapshot(group_id, replica_id)

    stop_supervisor(supervisor)

    restart_opts =
      opts
      |> Keyword.put(:bootstrap, false)
      |> Keyword.put(:client_id, {:concord_vsr_test_client, group_id, 2})

    {:ok, restarted} = Engine.VSR.Supervisor.start_link(restart_opts)
    Process.unlink(restarted)
    on_exit(fn -> stop_supervisor(restarted) end)

    assert {:ok, %{restored: true}} = Concord.get("vsr:durable", consistency: :strong)
  end

  @tag :tmp_dir
  test "version-one commands write, checkpoint, and replay after restart", %{
    group_id: group_id,
    supervisor: supervisor,
    vsr_opts: opts
  } do
    stop_supervisor(supervisor)

    versioned_opts =
      opts
      |> Keyword.put(:bootstrap, false)
      |> Keyword.put(:command_version, 1)
      |> Keyword.put(:client_id, {:concord_vsr_versioned_client, group_id})

    {:ok, versioned} = Engine.VSR.Supervisor.start_link(versioned_opts)
    Process.unlink(versioned)
    on_exit(fn -> stop_supervisor(versioned) end)

    assert :ok = Concord.put("vsr:version-one", %{replayed: true})
    assert :ok = ViewstampedReplication.snapshot(group_id, 1)
    assert {:ok, %{command_version: 1, wal_version: 1}} = Concord.status()

    stop_supervisor(versioned)

    {:ok, restarted} = Engine.VSR.Supervisor.start_link(versioned_opts)
    Process.unlink(restarted)
    on_exit(fn -> stop_supervisor(restarted) end)

    assert {:ok, %{replayed: true}} =
             Concord.get("vsr:version-one", consistency: :strong)
  end

  @tag :tmp_dir
  test "version-one emission blocks until legacy indexes are migrated and backfilled", %{
    group_id: group_id,
    supervisor: supervisor,
    vsr_opts: opts
  } do
    legacy_extractor = fn value -> Map.get(value, :email) end

    assert {:ok, :ok} =
             ViewstampedReplication.command(
               group_id,
               {:concord_command, 1_000, {:create_index, "legacy-email", legacy_extractor}},
               client: Concord.Engine.VSR.Client,
               timeout: 1_000
             )

    assert :ok = Concord.put("legacy-user", %{email: "legacy@example.test"})

    assert {:ok, %{storage: %{legacy_indexes: ["legacy-email"]}}} = Concord.status()

    stop_supervisor(supervisor)

    versioned_opts =
      opts
      |> Keyword.put(:bootstrap, false)
      |> Keyword.put(:command_version, 1)

    {:ok, versioned} = Engine.VSR.Supervisor.start_link(versioned_opts)
    Process.unlink(versioned)
    on_exit(fn -> stop_supervisor(versioned) end)

    assert {:error, {:legacy_indexes_require_migration, ["legacy-email"]}} =
             Concord.put("blocked", true)

    assert :ok = Concord.Index.drop("legacy-email")

    assert {:error, {:legacy_state_requires_reconciliation, %{required: true}}} =
             Concord.Index.create("legacy-email", {:map_get, :email}, reindex: true)

    assert {:ok, {:ok, %{reconciled: 0}}} = Engine.VSR.command(:reconcile_legacy_state)
    assert :ok = Concord.Index.create("legacy-email", {:map_get, :email}, reindex: true)

    assert {:ok, ["legacy-user"]} =
             Concord.Index.lookup("legacy-email", "legacy@example.test")

    assert :ok = Concord.put("unblocked", true)
    assert {:ok, %{storage: %{legacy_indexes: []}}} = Concord.status()
  end

  @tag :tmp_dir
  test "legacy index names are dropped under version zero before reconciliation", %{
    group_id: group_id,
    supervisor: supervisor,
    vsr_opts: opts
  } do
    assert {:ok, :ok} =
             ViewstampedReplication.command(
               group_id,
               {:concord_command, 1_000, {:create_index, :legacy_email, {:map_get, :email}}},
               client: Concord.Engine.VSR.Client,
               timeout: 1_000
             )

    assert :ok = Concord.put("legacy-named-user", %{email: "named@example.test"})
    assert {:ok, %{storage: %{legacy_indexes: [:legacy_email]}}} = Concord.status()

    assert :ok = Concord.Index.drop(:legacy_email)
    assert {:ok, %{storage: %{legacy_indexes: []}}} = Concord.status()

    stop_supervisor(supervisor)

    versioned_opts =
      opts
      |> Keyword.put(:bootstrap, false)
      |> Keyword.put(:command_version, 1)

    {:ok, versioned} = Engine.VSR.Supervisor.start_link(versioned_opts)
    Process.unlink(versioned)
    on_exit(fn -> stop_supervisor(versioned) end)

    assert {:ok, {:ok, %{reconciled: 0}}} = Engine.VSR.command(:reconcile_legacy_state)
    assert :ok = Concord.Index.create("legacy-email", {:map_get, :email}, reindex: true)

    assert {:ok, %{command_version: 1, storage: %{legacy_indexes: []}}} = Concord.status()

    assert {:ok, ["legacy-named-user"]} =
             Concord.Index.lookup("legacy-email", "named@example.test")

    assert :ok = Concord.put("version-one-after-migration", true)
  end

  test "invalid programmatic command versions fail engine startup", %{
    group_id: group_id,
    member_endpoint: member_endpoint,
    supervisor: supervisor
  } do
    stop_supervisor(supervisor)

    configuration =
      ViewstampedReplication.Configuration.new!(
        group_id: group_id,
        replica_id: 1,
        members: [%ViewstampedReplication.Member{id: 1, endpoint: member_endpoint}]
      )

    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:unsupported_command_version, 2}} =
               Engine.VSR.start_link(configuration: configuration, command_version: 2)
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  @tag :tmp_dir
  test "an uncheckpointed singleton restores multiple committed operations", %{
    group_id: group_id,
    replica_id: replica_id,
    supervisor: supervisor,
    vsr_opts: opts
  } do
    for value <- 1..3 do
      assert :ok = Concord.put("vsr:restart:#{value}", %{value: value})
    end

    assert {:ok, %{commit_number: 3, applied_number: 3}} =
             ViewstampedReplication.status(group_id, replica_id)

    stop_supervisor(supervisor)

    restart_opts =
      opts
      |> Keyword.put(:bootstrap, false)
      |> Keyword.put(:client_id, {:concord_vsr_test_client, group_id, 2})

    {:ok, restarted} = Engine.VSR.Supervisor.start_link(restart_opts)
    Process.unlink(restarted)
    on_exit(fn -> stop_supervisor(restarted) end)

    for value <- 1..3 do
      assert {:ok, %{value: ^value}} =
               Concord.get("vsr:restart:#{value}", consistency: :strong)
    end

    assert {:ok, %{commit_number: 3, applied_number: 3}} =
             ViewstampedReplication.status(group_id, replica_id)
  end

  defp stop_supervisor(supervisor) do
    if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
  catch
    :exit, _reason -> :ok
  end

  defp start_unless_running(module) do
    if is_nil(Process.whereis(module)), do: start_supervised!({module, []})
  end

  defp wait_for_client_restart(original_client, attempts \\ 100)

  defp wait_for_client_restart(_original_client, 0) do
    flunk("VSR client did not restart")
  end

  defp wait_for_client_restart(original_client, attempts) do
    case Process.whereis(Concord.Engine.VSR.Client) do
      client when is_pid(client) and client != original_client ->
        client

      _client ->
        Process.sleep(10)
        wait_for_client_restart(original_client, attempts - 1)
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:concord, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:concord, key)
end
