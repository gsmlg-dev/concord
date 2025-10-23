defmodule Concord.QueryTest do
  use ExUnit.Case, async: false

  alias Concord.Query

  setup do
    # Start test cluster
    :ok = Concord.TestHelper.start_test_cluster()

    # Clear all data before each test
    case Concord.get_all() do
      {:ok, pairs} ->
        keys = Enum.map(pairs, fn {k, _v} -> k end)
        if length(keys) > 0, do: Concord.delete_many(keys)

      _ ->
        :ok
    end

    # Insert test data
    :ok = Concord.put("user:1", %{name: "Alice", age: 30, role: "admin"})
    :ok = Concord.put("user:2", %{name: "Bob", age: 25, role: "user"})
    :ok = Concord.put("user:10", %{name: "Charlie", age: 35, role: "user"})
    :ok = Concord.put("user:100", %{name: "David", age: 28, role: "admin"})
    :ok = Concord.put("product:1", %{name: "Widget", price: 99})
    :ok = Concord.put("product:2", %{name: "Gadget", price: 149})
    :ok = Concord.put("product:3", %{name: "Gizmo", price: 199})
    :ok = Concord.put("order:2024-01-15", %{total: 100, status: :completed})
    :ok = Concord.put("order:2024-02-20", %{total: 200, status: :pending})
    :ok = Concord.put("order:2024-03-10", %{total: 150, status: :completed})
    :ok = Concord.put("temp:abc", "temporary")
    :ok = Concord.put("temp:xyz", "also_temp")

    :ok
  end

  describe "keys/1 with prefix" do
    test "finds all keys with prefix" do
      assert {:ok, keys} = Query.keys(prefix: "user:")
      assert length(keys) == 4
      assert "user:1" in keys
      assert "user:2" in keys
      assert "user:10" in keys
      assert "user:100" in keys
    end

    test "finds all product keys" do
      assert {:ok, keys} = Query.keys(prefix: "product:")
      assert length(keys) == 3
      assert Enum.sort(keys) == ["product:1", "product:2", "product:3"]
    end

    test "returns empty list when no matches" do
      assert {:ok, keys} = Query.keys(prefix: "nonexistent:")
      assert keys == []
    end
  end

  describe "keys/1 with suffix" do
    test "finds keys ending with suffix" do
      assert {:ok, keys} = Query.keys(suffix: ":1")
      assert length(keys) == 2
      assert "user:1" in keys
      assert "product:1" in keys
    end

    test "finds keys with numeric suffix" do
      assert {:ok, keys} = Query.keys(suffix: "00")
      assert "user:100" in keys
    end
  end

  describe "keys/1 with contains" do
    test "finds keys containing substring" do
      assert {:ok, keys} = Query.keys(contains: "product")
      assert length(keys) == 3
      assert Enum.all?(keys, &String.contains?(&1, "product"))
    end

    test "finds keys containing date pattern" do
      assert {:ok, keys} = Query.keys(contains: "2024-02")
      assert keys == ["order:2024-02-20"]
    end
  end

  describe "keys/1 with pattern (regex)" do
    test "finds keys matching regex pattern" do
      assert {:ok, keys} = Query.keys(pattern: ~r/user:\d+/)
      assert length(keys) == 4
    end

    test "finds keys with specific digit patterns" do
      assert {:ok, keys} = Query.keys(pattern: ~r/user:\d{2,}/)
      assert length(keys) == 2
      assert "user:10" in keys
      assert "user:100" in keys
    end

    test "finds order keys with date pattern" do
      assert {:ok, keys} = Query.keys(pattern: ~r/order:2024-\d{2}-\d{2}/)
      assert length(keys) == 3
    end
  end

  describe "keys/1 with range" do
    test "finds keys in range (inclusive)" do
      assert {:ok, keys} = Query.keys(range: {"user:1", "user:2"})
      # In lexicographic order: "user:1" < "user:10" < "user:100" < "user:2"
      assert length(keys) == 4
      assert "user:1" in keys
      assert "user:10" in keys
      assert "user:100" in keys
      assert "user:2" in keys
    end

    test "finds keys in date range" do
      assert {:ok, keys} = Query.keys(range: {"order:2024-01-01", "order:2024-02-28"})
      assert length(keys) == 2
      assert "order:2024-01-15" in keys
      assert "order:2024-02-20" in keys
      refute "order:2024-03-10" in keys
    end

    test "finds single key when range bounds are equal" do
      assert {:ok, keys} = Query.keys(range: {"user:1", "user:1"})
      assert keys == ["user:1"]
    end
  end

  describe "keys/1 with pagination" do
    test "limits number of results" do
      assert {:ok, keys} = Query.keys(prefix: "user:", limit: 2)
      assert length(keys) == 2
    end

    test "skips results with offset" do
      assert {:ok, all_keys} = Query.keys(prefix: "user:")
      assert {:ok, offset_keys} = Query.keys(prefix: "user:", offset: 2)

      assert length(offset_keys) == 2
      assert offset_keys == Enum.drop(all_keys, 2)
    end

    test "combines limit and offset" do
      assert {:ok, keys} = Query.keys(prefix: "user:", limit: 2, offset: 1)
      assert length(keys) == 2
    end

    test "handles offset larger than result set" do
      assert {:ok, keys} = Query.keys(prefix: "user:", offset: 100)
      assert keys == []
    end
  end

  describe "keys/1 with combined filters" do
    test "combines prefix and pattern" do
      assert {:ok, keys} = Query.keys(prefix: "user:", pattern: ~r/\d{2,}/)
      assert length(keys) == 2
      assert "user:10" in keys
      assert "user:100" in keys
    end

    test "combines range and contains" do
      assert {:ok, keys} = Query.keys(range: {"order:2024-01-01", "order:2024-12-31"}, contains: "-02-")
      # All order keys are in the range, then filter by contains "-02-"
      assert length(keys) == 1
      assert "order:2024-02-20" in keys
    end
  end

  describe "where/1" do
    test "returns key-value pairs with prefix" do
      assert {:ok, pairs} = Query.where(prefix: "product:")
      assert length(pairs) == 3

      assert {"product:1", %{name: "Widget", price: 99}} in pairs
      assert {"product:2", %{name: "Gadget", price: 149}} in pairs
    end

    test "filters by value predicate" do
      assert {:ok, pairs} = Query.where(
        prefix: "product:",
        filter: fn {_k, v} -> v.price > 100 end
      )

      assert length(pairs) == 2
      assert Enum.all?(pairs, fn {_k, v} -> v.price > 100 end)
    end

    test "filters users by role" do
      assert {:ok, pairs} = Query.where(
        prefix: "user:",
        filter: fn {_k, v} -> v.role == "admin" end
      )

      assert length(pairs) == 2
      names = Enum.map(pairs, fn {_k, v} -> v.name end)
      assert "Alice" in names
      assert "David" in names
    end

    test "filters with complex predicate" do
      assert {:ok, pairs} = Query.where(
        prefix: "user:",
        filter: fn {_k, v} -> v.age >= 30 and v.role == "user" end
      )

      assert length(pairs) == 1
      assert {_k, %{name: "Charlie"}} = hd(pairs)
    end

    test "combines range and filter" do
      assert {:ok, pairs} = Query.where(
        range: {"order:2024-01-01", "order:2024-12-31"},
        filter: fn {_k, v} -> v.status == :completed end
      )

      assert length(pairs) == 2
      assert Enum.all?(pairs, fn {_k, v} -> v.status == :completed end)
    end

    test "supports pagination with filter" do
      assert {:ok, pairs} = Query.where(
        prefix: "user:",
        filter: fn {_k, v} -> v.age > 20 end,
        limit: 2
      )

      assert length(pairs) == 2
    end
  end

  describe "count/1" do
    test "counts keys with prefix" do
      assert {:ok, count} = Query.count(prefix: "user:")
      assert count == 4
    end

    test "counts keys in range" do
      assert {:ok, count} = Query.count(range: {"order:2024-01-01", "order:2024-12-31"})
      assert count == 3
    end

    test "counts keys matching pattern" do
      assert {:ok, count} = Query.count(pattern: ~r/temp:/)
      assert count == 2
    end

    test "returns zero for no matches" do
      assert {:ok, count} = Query.count(prefix: "nonexistent:")
      assert count == 0
    end
  end

  describe "delete_where/1" do
    test "deletes keys with prefix" do
      assert {:ok, deleted_count} = Query.delete_where(prefix: "temp:")
      assert deleted_count == 2

      # Verify deletion
      assert {:ok, keys} = Query.keys(prefix: "temp:")
      assert keys == []
    end

    test "deletes keys in range" do
      assert {:ok, deleted_count} = Query.delete_where(range: {"order:2024-02-01", "order:2024-02-28"})
      assert deleted_count == 1

      # Verify specific key was deleted
      assert {:error, :not_found} = Concord.get("order:2024-02-20")

      # Verify other keys still exist
      assert {:ok, _} = Concord.get("order:2024-01-15")
      assert {:ok, _} = Concord.get("order:2024-03-10")
    end

    test "deletes keys matching pattern" do
      assert {:ok, deleted_count} = Query.delete_where(pattern: ~r/user:1\d+/)
      assert deleted_count == 2

      # Verify deletions
      assert {:error, :not_found} = Concord.get("user:10")
      assert {:error, :not_found} = Concord.get("user:100")

      # Verify others still exist
      assert {:ok, _} = Concord.get("user:1")
      assert {:ok, _} = Concord.get("user:2")
    end

    test "returns zero when no matches" do
      assert {:ok, deleted_count} = Query.delete_where(prefix: "nonexistent:")
      assert deleted_count == 0
    end
  end

  describe "error handling" do
    test "handles empty database" do
      # Clear all data
      {:ok, pairs} = Concord.get_all()
      keys = Enum.map(pairs, fn {k, _v} -> k end)
      Concord.delete_many(keys)

      assert {:ok, keys} = Query.keys(prefix: "any:")
      assert keys == []

      assert {:ok, count} = Query.count(prefix: "any:")
      assert count == 0
    end
  end

  describe "performance with larger datasets" do
    test "handles queries on larger datasets efficiently" do
      # Insert 100 additional keys
      for i <- 1..100 do
        Concord.put("test:#{String.pad_leading(to_string(i), 3, "0")}", %{value: i})
      end

      # Test prefix query
      assert {:ok, keys} = Query.keys(prefix: "test:")
      assert length(keys) == 100

      # Test range query
      assert {:ok, keys} = Query.keys(range: {"test:050", "test:059"})
      assert length(keys) == 10

      # Test pattern query
      assert {:ok, keys} = Query.keys(pattern: ~r/test:0[5-9]\d/)
      assert length(keys) == 50

      # Cleanup
      Query.delete_where(prefix: "test:")
    end
  end
end
