defmodule Concord.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    Concord.TestHelper.stop_test_cluster()
    stop_concord()

    previous =
      for key <- [:cluster_enabled, :turso, :vsr], into: %{} do
        {key, Application.fetch_env(:concord, key)}
      end

    on_exit(fn ->
      stop_concord()

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:concord, key, value)
        {key, :error} -> Application.delete_env(:concord, key)
      end)
    end)

    :ok
  end

  describe "prometheus_enabled?/0" do
    setup do
      previous = Application.fetch_env(:concord, :prometheus_enabled)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:concord, :prometheus_enabled, value)
          :error -> Application.delete_env(:concord, :prometheus_enabled)
        end
      end)

      :ok
    end

    test "defaults to disabled when not configured" do
      Application.delete_env(:concord, :prometheus_enabled)
      refute Concord.Application.prometheus_enabled?()
    end

    test "requires explicit enablement" do
      Application.put_env(:concord, :prometheus_enabled, true)
      assert Concord.Application.prometheus_enabled?()
    end
  end

  @tag :tmp_dir
  test "starts Turso without starting the replicated runtime", %{tmp_dir: tmp_dir} do
    stop_concord()
    Application.put_env(:concord, :cluster_enabled, false)

    Application.put_env(:concord, :turso,
      enabled: true,
      database: Path.join(tmp_dir, "turso.db"),
      pool_size: 1
    )

    assert {:ok, _started} = Application.ensure_all_started(:concord)
    assert Process.whereis(Concord.Turso.DB)
    assert Process.whereis(Concord.Engine.VSR.Supervisor) == nil
    assert Process.whereis(Concord.TTL) == nil
    assert :ok = Concord.Turso.put("app:turso", "value")
    assert {:ok, "value"} = Concord.Turso.get("app:turso")
  end

  test "starts a configured singleton VSR cluster" do
    stop_concord()
    group_id = {:application_vsr, System.unique_integer([:positive, :monotonic])}

    Application.put_env(:concord, :cluster_enabled, true)

    Application.put_env(:concord, :vsr,
      group_id: group_id,
      replica_id: 1,
      members: [%{id: 1, endpoint: {:application_vsr_endpoint, group_id}}],
      transport: :local,
      storage: :memory,
      bootstrap: true,
      retry_timeout: 10
    )

    assert {:ok, _started} = Application.ensure_all_started(:concord)
    assert :ok = Concord.TestHelper.wait_for_cluster_ready()
    assert Process.whereis(Concord.Engine.VSR.Supervisor)
    assert :ok = Concord.put("application:vsr", "ready")
    assert {:ok, "ready"} = Concord.get("application:vsr")
  end

  defp stop_concord do
    Application.stop(:concord)
    Process.sleep(50)
  end
end
