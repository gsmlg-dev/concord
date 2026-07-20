defmodule Concord.VSRIntegrationTest do
  use ExUnit.Case, async: false

  alias Concord.Engine
  alias Concord.KV.Record
  alias Concord.Sync.Event

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
              node: current_node,
              cluster: %{replica_id: 1, status: :normal, primary_id: 1},
              storage: storage
            }} = Concord.status()

    assert current_node == node()
    assert is_map(storage)
    assert {:ok, [{1, member_endpoint}]} = Concord.members()
    assert member_endpoint == configured_endpoint
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

  defp restore_env(key, {:ok, value}), do: Application.put_env(:concord, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:concord, key)
end
