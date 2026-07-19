defmodule Concord.LeaseIntegrationTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Concord.TestHelper.start_test_cluster()

    on_exit(fn ->
      Concord.TestHelper.stop_test_cluster()
    end)

    :ok
  end

  defp replicated_query(query_term) do
    case Concord.Engine.query(query_term) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp replicated_command(command) do
    case Concord.Engine.command(command) do
      {:ok, result} -> result
      error -> error
    end
  end

  describe "lease: grant" do
    test "grants a lease with TTL" do
      cmd = {:grant_lease, 30, %{}}

      result = replicated_command(cmd)

      assert {:ok, %{lease_id: id, ttl: 30}} = result
      assert is_integer(id) and id > 0
    end

    test "lease IDs are sequential" do
      r1 = replicated_command({:grant_lease, 30, %{}})
      r2 = replicated_command({:grant_lease, 60, %{}})

      {:ok, %{lease_id: id1}} = r1
      {:ok, %{lease_id: id2}} = r2
      assert id2 == id1 + 1
    end
  end

  describe "lease: keep_alive" do
    test "refreshes lease TTL" do
      {:ok, %{lease_id: id}} = replicated_command({:grant_lease, 10, %{}})

      # Keep alive should succeed
      result = replicated_command({:keep_alive_lease, id, %{}})

      assert result == :ok
    end

    test "fails for non-existent lease" do
      result = replicated_command({:keep_alive_lease, 999_999, %{}})

      assert result == {:error, :lease_not_found}
    end
  end

  describe "lease: key attachment" do
    test "put with lease attaches key to lease" do
      {:ok, %{lease_id: id}} = replicated_command({:grant_lease, 60, %{}})

      # Put a key with the lease
      cmd = {:put, "leased_key", "value", %{lease: id}}
      _result = replicated_command(cmd)

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
      {:ok, %{lease_id: id}} = replicated_command({:grant_lease, 60, %{}})

      # Put keys with lease
      replicated_command({:put, "lk1", "v1", %{lease: id}})
      replicated_command({:put, "lk2", "v2", %{lease: id}})

      # Verify keys exist
      assert {:ok, "v1"} = Concord.get("lk1")
      assert {:ok, "v2"} = Concord.get("lk2")

      # Revoke
      result = replicated_command({:revoke_lease, id, %{}})

      assert {:ok, %{deleted_keys: 2}} = result

      # Keys should be gone
      assert {:error, :not_found} = Concord.get("lk1")
      assert {:error, :not_found} = Concord.get("lk2")

      # Lease should be gone
      assert :ets.lookup(:concord_leases, id) == []
    end

    test "revoke non-existent lease returns error" do
      result = replicated_command({:revoke_lease, 888_888, %{}})

      assert result == {:error, :lease_not_found}
    end
  end

  describe "lease: queries" do
    test "lease_info returns lease details" do
      {:ok, %{lease_id: id}} = replicated_command({:grant_lease, 120, %{}})

      result = replicated_query({:lease_info, id})
      assert {:ok, lease} = result
      assert lease.id == id
      assert lease.ttl == 120
      assert is_integer(lease.remaining)
      assert lease.remaining > 0
    end

    test "list_leases returns all leases" do
      replicated_command({:grant_lease, 30, %{}})
      replicated_command({:grant_lease, 60, %{}})

      result = replicated_query(:list_leases)
      assert {:ok, leases} = result
      assert length(leases) >= 2
    end
  end
end
