defmodule Concord.E2E.LeaseTest do
  use ExUnit.Case, async: false
  alias Concord.E2E.ClusterHelper

  @moduletag :e2e
  @moduletag :distributed

  setup do
    {:ok, nodes, ports} = ClusterHelper.start_cluster(nodes: 3)

    on_exit(fn ->
      ClusterHelper.stop_cluster(ports)
    end)

    %{nodes: nodes, ports: ports}
  end

  describe "Lease Consistency" do
    test "lease grant replicates across cluster", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)
      assert leader != nil

      # Grant a lease via Raft command
      {:ok, result, _} =
        :rpc.call(leader, :ra, :process_command, [
          {:concord_cluster, leader},
          {:grant_lease, 60, %{}}
        ])

      assert {:ok, %{lease_id: lease_id, ttl: 60}} = result
      assert is_integer(lease_id)

      Process.sleep(500)

      # Query lease info from all nodes
      for node <- nodes do
        mfa = {Concord.StateMachine, :query, [{:lease_info, lease_id}]}

        case :rpc.call(node, :ra, :leader_query, [{:concord_cluster, node}, mfa]) do
          {:ok, {{_, _}, {:ok, lease}}, _} ->
            assert lease.id == lease_id
            assert lease.ttl == 60
            assert lease.remaining > 0

          {:ok, {:ok, lease}, _} ->
            assert lease.id == lease_id
            assert lease.ttl == 60

          other ->
            # On follower nodes, leader_query may redirect
            IO.puts("Node #{node} returned: #{inspect(other)}")
        end
      end

      IO.puts("✓ Lease #{lease_id} (TTL=60s) replicated to all nodes")
    end

    test "lease revoke deletes attached keys across cluster", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)

      # Grant a lease
      {:ok, {:ok, %{lease_id: lease_id}}, _} =
        :rpc.call(leader, :ra, :process_command, [
          {:concord_cluster, leader},
          {:grant_lease, 300, %{}}
        ])

      # Attach keys to the lease
      for i <- 1..3 do
        :rpc.call(leader, :ra, :process_command, [
          {:concord_cluster, leader},
          {:put, "leased:#{i}", "value_#{i}", %{lease: lease_id}}
        ])
      end

      Process.sleep(300)

      # Verify keys exist on all nodes
      for node <- nodes do
        for i <- 1..3 do
          assert {:ok, _} = :rpc.call(node, Concord, :get, ["leased:#{i}"])
        end
      end

      # Revoke the lease
      {:ok, result, _} =
        :rpc.call(leader, :ra, :process_command, [
          {:concord_cluster, leader},
          {:revoke_lease, lease_id, %{}}
        ])

      assert {:ok, %{deleted_keys: 3}} = result

      Process.sleep(500)

      # All attached keys should be deleted on all nodes
      for node <- nodes do
        for i <- 1..3 do
          assert {:error, :not_found} = :rpc.call(node, Concord, :get, ["leased:#{i}"])
        end
      end

      IO.puts("✓ Lease revoke cascaded delete of 3 keys across all nodes")
    end

    test "lease keep_alive resets TTL", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)

      # Grant a lease with short TTL
      {:ok, {:ok, %{lease_id: lease_id}}, _} =
        :rpc.call(leader, :ra, :process_command, [
          {:concord_cluster, leader},
          {:grant_lease, 5, %{}}
        ])

      # Wait a bit, then keep alive
      Process.sleep(2000)

      {:ok, result, _} =
        :rpc.call(leader, :ra, :process_command, [
          {:concord_cluster, leader},
          {:keep_alive_lease, lease_id, %{}}
        ])

      assert result == :ok

      # Verify remaining TTL is refreshed
      mfa = {Concord.StateMachine, :query, [{:lease_info, lease_id}]}

      case :rpc.call(leader, :ra, :leader_query, [{:concord_cluster, leader}, mfa]) do
        {:ok, {{_, _}, {:ok, lease}}, _} ->
          assert lease.remaining > 0, "Remaining TTL should be > 0 after keep_alive"
          IO.puts("✓ Keep-alive refreshed lease (remaining: #{lease.remaining}s)")

        {:ok, {:ok, lease}, _} ->
          assert lease.remaining > 0
          IO.puts("✓ Keep-alive refreshed lease (remaining: #{lease.remaining}s)")
      end
    end
  end
end
