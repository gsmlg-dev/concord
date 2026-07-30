defmodule ViewstampedReplication.RegistryLifecycleTest do
  use ExUnit.Case, async: false

  alias ViewstampedReplication.{Replica, Request}

  test "replica lookups remain unavailable errors while the registry is stopping" do
    on_exit(fn ->
      assert {:ok, _applications} = Application.ensure_all_started(:viewstamped_replication)
    end)

    assert :ok = Application.stop(:viewstamped_replication)

    assert Replica.whereis(:group, :replica) == nil
    assert Replica.status(:group, :replica) == {:error, :not_found}
    assert Replica.read({:group, :replica}, :operation) == {:error, :not_found}

    request = %Request{client_id: :client, request_number: 1, operation: :operation}
    assert Replica.submit({:group, :replica}, self(), request) == :ok
  end
end
