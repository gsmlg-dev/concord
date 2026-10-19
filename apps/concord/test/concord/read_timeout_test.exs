defmodule Concord.ReadTimeoutTest do
  use ExUnit.Case, async: false

  test "public reads return timeout errors while primary discovery is suspended" do
    previous_vsr = Application.fetch_env(:concord, :vsr)
    assert :ok = Concord.TestHelper.start_test_cluster()

    on_exit(fn ->
      Concord.TestHelper.stop_test_cluster()

      case previous_vsr do
        {:ok, config} -> Application.put_env(:concord, :vsr, config)
        :error -> Application.delete_env(:concord, :vsr)
      end
    end)

    assert :ok = Concord.put("timeout:retained", "value")
    opts = Application.fetch_env!(:concord, :vsr)
    replica = ViewstampedReplication.Replica.whereis(opts[:group_id], opts[:replica_id])
    :ok = :sys.suspend(replica)

    try do
      started = System.monotonic_time(:millisecond)
      assert {:error, :timeout} = Concord.get("timeout:retained", timeout: 50)
      assert System.monotonic_time(:millisecond) - started < 1_000
    after
      :sys.resume(replica)
    end

    assert {:ok, "value"} = Concord.get("timeout:retained")
  end
end
