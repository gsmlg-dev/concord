defmodule Concord.E2E.V2KVTest do
  use ExUnit.Case, async: false
  alias Concord.E2E.Cluster

  @moduletag :e2e

  describe "MVCC revision tracking" do
    test "revisions are consistent across nodes" do
      primary = Cluster.find_primary()

      for i <- 1..5 do
        :rpc.call(primary, Concord, :put, ["e2e:rev:#{i}", "v#{i}"])
      end

      Process.sleep(500)

      revisions =
        Enum.map(Cluster.nodes(), fn node ->
          Cluster.replicated_query(node, :get_revision)
        end)

      rev_values = Enum.map(revisions, fn {:ok, r} -> r end)
      assert length(Enum.uniq(rev_values)) == 1,
             "Revisions should be identical: #{inspect(rev_values)}"

      [rev] = Enum.uniq(rev_values)
      assert rev >= 5
      IO.puts("  ✓ Cluster revision #{rev} consistent across all nodes")
    end

    test "MVCC records have correct version on update" do
      primary = Cluster.find_primary()

      :rpc.call(primary, Concord, :put, ["e2e:mvcc:ver", "v1"])
      :rpc.call(primary, Concord, :put, ["e2e:mvcc:ver", "v2"])
      :rpc.call(primary, Concord, :put, ["e2e:mvcc:ver", "v3"])
      Process.sleep(500)

      for node <- Cluster.nodes() do
        {:ok, rec} = Cluster.replicated_query(node, {:get_record, "e2e:mvcc:ver"})
        assert rec.version == 3, "Version should be 3 on #{node}"
        assert rec.mod_revision > rec.create_revision
      end

      IO.puts("  ✓ MVCC version=3, mod>create on all nodes")
    end

    test "tombstone deletes are consistent" do
      primary = Cluster.find_primary()

      :rpc.call(primary, Concord, :put, ["e2e:tomb:1", "alive"])
      Process.sleep(300)
      :rpc.call(primary, Concord, :delete, ["e2e:tomb:1"])
      Process.sleep(500)

      for node <- Cluster.nodes() do
        result = Cluster.replicated_query(node, {:get_record, "e2e:tomb:1"})
        assert result == {:error, :not_found},
               "Deleted key should return :not_found on #{node}"
      end

      IO.puts("  ✓ Tombstone consistent across all nodes")
    end
  end

  describe "list/prefix queries" do
    test "prefix list returns matching records on all nodes" do
      primary = Cluster.find_primary()

      for i <- 1..5 do
        :rpc.call(primary, Concord, :put, ["/e2e/users/#{i}", %{name: "User #{i}"}])
      end

      :rpc.call(primary, Concord, :put, ["/e2e/posts/1", %{title: "Post 1"}])
      Process.sleep(500)

      for node <- Cluster.nodes() do
        {:ok, records, meta} =
          Cluster.replicated_query(node, {:list, {:prefix, "/e2e/users/"}, %{limit: 100}})

        assert length(records) == 5, "Should find 5 users on #{node}"
        assert meta.has_more == false
      end

      IO.puts("  ✓ Prefix list consistent (5 users) across all nodes")
    end

    test "list with limit returns has_more" do
      primary = Cluster.find_primary()

      for i <- 1..10 do
        :rpc.call(primary, Concord, :put, ["/e2e/paginate/#{String.pad_leading("#{i}", 2, "0")}", i])
      end

      Process.sleep(500)

      {:ok, records, meta} =
        Cluster.replicated_query(Cluster.find_primary(), {:list, {:prefix, "/e2e/paginate/"}, %{limit: 3}})

      assert length(records) == 3
      assert meta.has_more == true
      IO.puts("  ✓ Pagination: limit=3, has_more=true")
    end
  end
end
