defmodule Concord.VSRStatisticsTest do
  use ExUnit.Case, async: false

  alias Concord.Engine.VSR
  alias Concord.StateMachine.Core
  alias ViewstampedReplication.Replica

  @moduletag :tmp_dir

  setup %{tmp_dir: path} do
    {:ok, _} = Application.ensure_all_started(:viewstamped_replication)

    for module <- [Concord.Sync.WatchHub, Concord.Sync.Dispatcher] do
      if is_nil(Process.whereis(module)), do: start_supervised!(module)
    end

    previous_vsr = Application.fetch_env(:concord, :vsr)
    group = {:vsr_statistics, System.unique_integer([:positive, :monotonic])}

    opts = [
      group_id: group,
      replica_id: 1,
      members: [%{id: 1, endpoint: {:local, group}}],
      transport: :local,
      storage: :file,
      storage_path: path,
      bootstrap: true,
      retry_timeout: 10
    ]

    Application.put_env(:concord, :vsr, opts)
    start_supervised!({VSR.Supervisor, opts})
    assert :ok = Concord.TestHelper.wait_for_cluster_ready()

    on_exit(fn ->
      case previous_vsr do
        {:ok, value} -> Application.put_env(:concord, :vsr, value)
        :error -> Application.delete_env(:concord, :vsr)
      end
    end)

    %{replica: Replica.whereis(group, 1), opts: opts}
  end

  test "file-backed status and telemetry do not validate the full store while point reads run", %{
    replica: replica
  } do
    for batch <- 0..3 do
      entries = for offset <- 1..256, do: {"stats:#{batch * 256 + offset}", %{value: offset}}
      assert {:ok, results} = Concord.put_many(entries)
      assert map_size(results) == 256
      assert Enum.all?(results, fn {_key, result} -> result == :ok end)
    end

    store = :sys.get_state(replica).state_machine_state.store
    expected_memory = byte_size(:erlang.term_to_binary(store))
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:concord, :cluster, :status],
        fn _event, metrics, _meta, _config ->
          send(parent, {:polled_statistics, metrics})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    poller =
      Process.whereis(Concord.Telemetry.Poller) || start_supervised!(Concord.Telemetry.Poller)

    {status, counts} =
      trace_statistics(replica, fn ->
        assert {:ok, status} = Concord.status()
        send(poller, :poll)

        tasks =
          for _ <- 1..8 do
            Task.async(fn -> assert {:ok, %{value: 1}} = Concord.get("stats:1") end)
          end

        Task.await_many(tasks)

        assert_receive {:polled_statistics,
                        %{storage_size: 1_024, storage_memory: ^expected_memory}},
                       1_000

        status
      end)

    assert %{engine: :vsr, command_version: 0, storage: %{size: 1_024, memory: ^expected_memory}} =
             status

    assert counts.stats >= 2
    assert counts.full_validation == 0
  end

  test "file-backed recovery rebuilds statistics and keeps point reads available", %{opts: opts} do
    assert :ok = Concord.put("stats:retained", %{value: 1})
    assert :ok = Concord.put("stats:deleted", "gone")
    assert :ok = Concord.delete("stats:deleted")
    assert {:ok, %{storage: before}} = Concord.status()

    stop_supervised!(VSR.Supervisor)
    start_supervised!({VSR.Supervisor, Keyword.put(opts, :bootstrap, false)})
    assert :ok = Concord.TestHelper.wait_for_cluster_ready()

    assert {:ok, %{storage: ^before}} = Concord.status()
    assert {:ok, %{value: 1}} = Concord.get("stats:retained")
    assert {:error, :not_found} = Concord.get("stats:deleted")
  end

  defp trace_statistics(replica, operation) do
    {:module, :trace} = Code.ensure_loaded(:trace)
    session = :trace.session_create(:vsr_statistics, self(), [])
    stats = {Core, :do_query, 3}
    validation = {Core, :representation_conflict_status, 1}

    try do
      1 = :trace.function(session, stats, [{[:stats, :_, :_], [], []}], [:local])
      1 = :trace.function(session, validation, true, [:local])
      1 = :trace.process(session, replica, true, [:call, :arity])
      result = operation.()
      reference = :trace.delivered(session, replica)
      assert_receive {:trace_delivered, ^replica, ^reference}, 1_000
      {result, collect_calls(replica, %{stats: 0, full_validation: 0})}
    after
      :trace.session_destroy(session)
    end
  end

  defp collect_calls(replica, counts) do
    receive do
      {:trace, ^replica, :call, {Core, :do_query, 3}} ->
        collect_calls(replica, %{counts | stats: counts.stats + 1})

      {:trace, ^replica, :call, {Core, :representation_conflict_status, 1}} ->
        collect_calls(replica, %{counts | full_validation: counts.full_validation + 1})
    after
      0 -> counts
    end
  end
end
