defmodule Concord.E2E.RevisionConsistencyTest do
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

  # Helper to query a Ra MFA on a remote node
  defp remote_ra_query(node, query_term) do
    mfa = {Concord.StateMachine, :query, [query_term]}

    case :rpc.call(node, :ra, :leader_query, [{:concord_cluster, node}, mfa]) do
      {:ok, {{_, _}, result}, _} -> result
      {:ok, result, _} -> result
      error -> error
    end
  end

  describe "Revision Consistency" do
    test "revisions are monotonically increasing", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)
      assert leader != nil

      # Perform sequential writes
      for i <- 1..10 do
        :rpc.call(leader, Concord, :put, ["rev:#{i}", "value_#{i}"])
      end

      Process.sleep(500)

      # Query revision on each node — should be consistent
      revisions =
        Enum.map(nodes, fn node ->
          remote_ra_query(node, :get_revision)
        end)

      # All should return the same revision
      rev_values = Enum.map(revisions, fn {:ok, r} -> r end)
      assert length(Enum.uniq(rev_values)) == 1,
             "All nodes should agree on revision: #{inspect(rev_values)}"

      [rev] = Enum.uniq(rev_values)
      assert rev >= 10, "Revision should be >= 10 after 10 puts"

      IO.puts("✓ Revision #{rev} consistent across #{length(nodes)} nodes")
    end

    test "MVCC records have correct metadata", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)

      # Put then update
      :rpc.call(leader, Concord, :put, ["mvcc:key", "v1"])
      Process.sleep(200)
      :rpc.call(leader, Concord, :put, ["mvcc:key", "v2"])
      Process.sleep(500)

      # Get the record on each node
      records =
        Enum.map(nodes, fn node ->
          remote_ra_query(node, {:get_record, "mvcc:key"})
        end)

      # All should return the same record
      for {:ok, rec} <- records do
        assert rec.version == 2, "Version should be 2 after update"
        assert rec.mod_revision > rec.create_revision, "mod > create after update"
      end

      # create_revision should be the same across nodes
      create_revs = Enum.map(records, fn {:ok, r} -> r.create_revision end)
      assert length(Enum.uniq(create_revs)) == 1

      IO.puts("✓ MVCC metadata (version, revisions) consistent across nodes")
    end

    test "tombstones replicate correctly", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)

      # Create and delete
      :rpc.call(leader, Concord, :put, ["tomb:key", "ephemeral"])
      Process.sleep(300)
      :rpc.call(leader, Concord, :delete, ["tomb:key"])
      Process.sleep(500)

      # Key should be gone on all nodes
      for node <- nodes do
        result = :rpc.call(node, Concord, :get, ["tomb:key"])
        assert result == {:error, :not_found},
               "Deleted key should be :not_found on #{node}, got: #{inspect(result)}"
      end

      # Record should also be gone from concord_current
      for node <- nodes do
        result = remote_ra_query(node, {:get_record, "tomb:key"})
        assert result == {:error, :not_found},
               "Deleted record should be :not_found on #{node}"
      end

      IO.puts("✓ Tombstones replicated correctly — key gone on all nodes")
    end

    test "list by prefix consistent across nodes", %{nodes: nodes} do
      leader = ClusterHelper.find_leader(nodes)

      # Create keys under prefix
      for i <- 1..5 do
        :rpc.call(leader, Concord, :put, ["/users/#{i}", %{name: "User #{i}"}])
      end

      :rpc.call(leader, Concord, :put, ["/posts/1", %{title: "Post 1"}])
      Process.sleep(500)

      # Query list by prefix on each node
      results =
        Enum.map(nodes, fn node ->
          remote_ra_query(node, {:list, {:prefix, "/users/"}, %{limit: 100}})
        end)

      for {:ok, records, meta} <- results do
        assert length(records) == 5, "Should find 5 users"
        assert meta.has_more == false
      end

      IO.puts("✓ Prefix list consistent across #{length(nodes)} nodes")
    end
  end
end
