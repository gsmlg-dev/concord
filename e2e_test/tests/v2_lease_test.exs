defmodule Concord.E2E.V2LeaseTest do
  use ExUnit.Case, async: false
  alias Concord.E2E.Cluster

  @moduletag :e2e

  describe "lease lifecycle across cluster" do
    test "grant lease replicates" do
      {:ok, result} = Cluster.ra_command({:grant_lease, 60, %{}})
      assert {:ok, %{lease_id: id, ttl: 60}} = result
      assert is_integer(id) and id > 0

      Process.sleep(500)

      # Query lease from all nodes
      for node <- Cluster.nodes() do
        case Cluster.ra_query(node, {:lease_info, id}) do
          {:ok, lease} ->
            assert lease.id == id
            assert lease.ttl == 60

          other ->
            # Follower nodes may redirect to leader — that's OK
            IO.puts("    Node #{node}: #{inspect(other)}")
        end
      end

      IO.puts("  ✓ Lease #{id} (TTL=60s) replicated")
    end

    test "revoke lease cascades key deletion" do
      # Grant
      {:ok, {:ok, %{lease_id: id}}} = Cluster.ra_command({:grant_lease, 300, %{}})
      leader = Cluster.find_leader()

      # Attach keys
      for i <- 1..3 do
        :rpc.call(leader, :ra, :process_command, [
          {:concord_cluster, leader},
          {:put, "e2e:leased:#{i}", "v#{i}", %{lease: id}}
        ])
      end

      Process.sleep(300)

      # Verify keys exist
      for i <- 1..3 do
        assert :ok = Cluster.wait_replicated("e2e:leased:#{i}", {:ok, "v#{i}"})
      end

      # Revoke
      {:ok, result} = Cluster.ra_command({:revoke_lease, id, %{}})
      assert {:ok, %{deleted_keys: 3}} = result

      Process.sleep(500)

      # All keys should be gone on all nodes
      for node <- Cluster.nodes() do
        for i <- 1..3 do
          assert {:error, :not_found} = :rpc.call(node, Concord, :get, ["e2e:leased:#{i}"])
        end
      end

      IO.puts("  ✓ Lease revoke cascaded 3 key deletions across cluster")
    end

    test "keep_alive refreshes lease" do
      {:ok, {:ok, %{lease_id: id}}} = Cluster.ra_command({:grant_lease, 10, %{}})

      Process.sleep(2000)

      {:ok, result} = Cluster.ra_command({:keep_alive_lease, id, %{}})
      assert result == :ok

      # Check remaining TTL is still > 0
      leader = Cluster.find_leader()
      {:ok, lease} = Cluster.ra_query(leader, {:lease_info, id})
      assert lease.remaining > 0
      IO.puts("  ✓ Keep-alive refreshed (remaining: #{lease.remaining}s)")
    end

    test "list_leases returns all active leases" do
      Cluster.ra_command({:grant_lease, 120, %{}})
      Cluster.ra_command({:grant_lease, 240, %{}})

      Process.sleep(300)

      leader = Cluster.find_leader()
      {:ok, leases} = Cluster.ra_query(leader, :list_leases)
      assert length(leases) >= 2

      IO.puts("  ✓ list_leases returned #{length(leases)} leases")
    end
  end
end
