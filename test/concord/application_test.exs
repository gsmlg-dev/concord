defmodule Concord.ApplicationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    concord_clustering = Application.get_env(:concord, :clustering)
    concord_topologies = Application.get_env(:concord, :topologies)
    libcluster_topologies = Application.get_env(:libcluster, :topologies)

    on_exit(fn ->
      restore_env(:concord, :clustering, concord_clustering)
      restore_env(:concord, :topologies, concord_topologies)
      restore_env(:libcluster, :topologies, libcluster_topologies)
    end)

    :ok
  end

  describe "prometheus_enabled?/0" do
    setup do
      previous = Application.get_env(:concord, :prometheus_enabled, :unset)

      on_exit(fn ->
        case previous do
          :unset -> Application.delete_env(:concord, :prometheus_enabled)
          value -> Application.put_env(:concord, :prometheus_enabled, value)
        end
      end)
    end

    test "defaults to disabled when not configured" do
      Application.delete_env(:concord, :prometheus_enabled)

      refute Concord.Application.prometheus_enabled?()
    end

    test "honors checked-in disabled config" do
      assert Application.get_env(:concord, :prometheus_enabled) == false
      refute Concord.Application.prometheus_enabled?()
    end

    test "requires explicit enablement" do
      Application.put_env(:concord, :prometheus_enabled, true)

      assert Concord.Application.prometheus_enabled?()
    end
  end

  test "uses Concord topologies when configured" do
    topologies = [
      concord_gossip: [
        strategy: Cluster.Strategy.Gossip,
        config: [
          secret: "test-secret",
          multicast_addr: {239, 10, 10, 10}
        ]
      ]
    ]

    Application.put_env(:concord, :topologies, topologies)

    assert {Cluster.Supervisor, [^topologies, [name: Concord.ClusterSupervisor]]} =
             cluster_supervisor_child()
  end

  test "falls back to libcluster topologies" do
    topologies = [
      concord_epmd: [
        strategy: Cluster.Strategy.Epmd,
        config: [hosts: [:"a@127.0.0.1"]]
      ]
    ]

    Application.delete_env(:concord, :topologies)
    Application.put_env(:libcluster, :topologies, topologies)

    assert {Cluster.Supervisor, [^topologies, [name: Concord.ClusterSupervisor]]} =
             cluster_supervisor_child()
  end

  test "omits Cluster.Supervisor when clustering is disabled" do
    Application.put_env(:concord, :clustering, false)

    refute Enum.any?(Concord.Application.children(), fn
             {Cluster.Supervisor, _args} -> true
             _child -> false
           end)
  end

  test "starts default Ra system before starting Concord cluster" do
    stop_concord()
    stop_ra()

    create_stale_ra_system_config()

    log =
      capture_log(fn ->
        assert {:ok, _started} = Application.ensure_all_started(:concord)
        assert :ok = Concord.TestHelper.wait_for_cluster_ready(30_000)
      end)

    refute log =~ "Failed to start Concord cluster"
    refute log =~ "system_not_started"
  after
    stop_concord()
    Concord.TestHelper.stop_test_cluster()
  end

  defp create_stale_ra_system_config do
    :application.load(:ra)

    try do
      :ra_system.start_default()
    catch
      :exit, _reason -> :ok
    end

    assert is_map(:ra_system.fetch(:default))
    assert Process.whereis(:ra_server_sup_sup) == nil
  end

  defp stop_concord do
    Application.stop(:concord)
    Process.sleep(100)
  end

  defp stop_ra do
    Application.stop(:ra)
    Process.sleep(100)
    :persistent_term.erase({:"$ra_system", :default})
  end

  defp cluster_supervisor_child do
    Enum.find(Concord.Application.children(), fn
      {Cluster.Supervisor, _args} -> true
      _child -> false
    end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
