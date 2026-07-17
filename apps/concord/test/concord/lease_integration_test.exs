defmodule Concord.LeaseIntegrationTest do
  use ExUnit.Case, async: false

  alias Concord.KV.Record

  setup do
    :ok = Concord.TestHelper.start_test_cluster()

    on_exit(fn ->
      Concord.TestHelper.stop_test_cluster()
    end)

    :ok
  end

  # Helper to run a Ra query using the correct MFA format
  defp ra_query(query_term) do
    mfa = {Concord.StateMachine, :query, [query_term]}

    case :ra.leader_query({:concord_cluster, node()}, mfa) do
      {:ok, {{_, _}, result}, _} -> result
      {:ok, result, _} -> result
      error -> error
    end
  end

  describe "lease: grant" do
    test "grants a lease with TTL" do
      cmd = {:grant_lease, 30, %{}}

      {:ok, result, _} =
        :ra.process_command({:concord_cluster, node()}, cmd)

      assert {:ok, %{lease_id: id, ttl: 30}} = result
      assert is_integer(id) and id > 0
    end

    test "lease IDs are sequential" do
      {:ok, r1, _} = :ra.process_command({:concord_cluster, node()}, {:grant_lease, 30, %{}})
      {:ok, r2, _} = :ra.process_command({:concord_cluster, node()}, {:grant_lease, 60, %{}})

      {:ok, %{lease_id: id1}} = r1
      {:ok, %{lease_id: id2}} = r2
      assert id2 == id1 + 1
    end
  end

  describe "lease: keep_alive" do
    test "refreshes lease TTL" do
      {:ok, {:ok, %{lease_id: id}}, _} =
        :ra.process_command({:concord_cluster, node()}, {:grant_lease, 10, %{}})

      # Keep alive should succeed
      {:ok, result, _} =
        :ra.process_command({:concord_cluster, node()}, {:keep_alive_lease, id, %{}})

      assert result == :ok
    end

    test "fails for non-existent lease" do
      {:ok, result, _} =
        :ra.process_command({:concord_cluster, node()}, {:keep_alive_lease, 999_999, %{}})

      assert result == {:error, :lease_not_found}
    end
  end

  describe "lease: key attachment" do
    test "put with lease attaches key to lease" do
      {:ok, {:ok, %{lease_id: id}}, _} =
        :ra.process_command({:concord_cluster, node()}, {:grant_lease, 60, %{}})

      # Put a key with the lease
      cmd = {:put, "leased_key", "value", %{lease: id}}
      {:ok, _result, _} = :ra.process_command({:concord_cluster, node()}, cmd)

      # Verify key is attached to the lease
      case :ets.lookup(:concord_leases, id) do
        [{^id, lease}] ->
          assert "leased_key" in lease.keys

        _ ->
          flunk("Lease not found")
      end
    end
  end

  describe "lease: revoke" do
    test "revokes lease and deletes attached keys" do
      # Grant lease
      {:ok, {:ok, %{lease_id: id}}, _} =
        :ra.process_command({:concord_cluster, node()}, {:grant_lease, 60, %{}})

      # Put keys with lease
      :ra.process_command({:concord_cluster, node()}, {:put, "lk1", "v1", %{lease: id}})
      :ra.process_command({:concord_cluster, node()}, {:put, "lk2", "v2", %{lease: id}})

      # Verify keys exist
      assert {:ok, "v1"} = Concord.get("lk1")
      assert {:ok, "v2"} = Concord.get("lk2")

      # Revoke
      {:ok, result, _} =
        :ra.process_command({:concord_cluster, node()}, {:revoke_lease, id, %{}})

      assert {:ok, %{deleted_keys: 2}} = result

      # Keys should be gone
      assert {:error, :not_found} = Concord.get("lk1")
      assert {:error, :not_found} = Concord.get("lk2")

      # Lease should be gone
      assert :ets.lookup(:concord_leases, id) == []
    end

    test "revoke non-existent lease returns error" do
      {:ok, result, _} =
        :ra.process_command({:concord_cluster, node()}, {:revoke_lease, 888_888, %{}})

      assert result == {:error, :lease_not_found}
    end
  end

  describe "lease: queries" do
    test "lease_info returns lease details" do
      {:ok, {:ok, %{lease_id: id}}, _} =
        :ra.process_command({:concord_cluster, node()}, {:grant_lease, 120, %{}})

      result = ra_query({:lease_info, id})
      assert {:ok, lease} = result
      assert lease.id == id
      assert lease.ttl == 120
      assert is_integer(lease.remaining)
      assert lease.remaining > 0
    end

    test "list_leases returns all leases" do
      :ra.process_command({:concord_cluster, node()}, {:grant_lease, 30, %{}})
      :ra.process_command({:concord_cluster, node()}, {:grant_lease, 60, %{}})

      result = ra_query(:list_leases)
      assert {:ok, leases} = result
      assert length(leases) >= 2
    end
  end
end
