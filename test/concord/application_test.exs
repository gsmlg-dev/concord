defmodule Concord.ApplicationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

  test "starts default Ra system before starting Concord cluster" do
    stop_concord()
    stop_ra()

    create_stale_ra_system_config()

    log =
      capture_log(fn ->
        assert {:ok, _started} = Application.ensure_all_started(:concord)
        assert :ok = Concord.TestHelper.wait_for_cluster_ready()
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
end
