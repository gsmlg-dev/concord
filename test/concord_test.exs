defmodule ConcordTest do
  use ExUnit.Case, async: false

  setup do
    # Clean up any existing data
    on_exit(fn ->
      try do
        Concord.delete("test_key")
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  describe "basic operations" do
    test "put and get a value" do
      assert :ok = Concord.put("test_key", "test_value")
      assert {:ok, "test_value"} = Concord.get("test_key")
    end

    test "get non-existent key returns not_found" do
      assert {:error, :not_found} = Concord.get("non_existent")
    end

    test "delete a key" do
      assert :ok = Concord.put("delete_me", "value")
      assert :ok = Concord.delete("delete_me")
      assert {:error, :not_found} = Concord.get("delete_me")
    end

    test "update existing key" do
      assert :ok = Concord.put("update_key", "old_value")
      assert :ok = Concord.put("update_key", "new_value")
      assert {:ok, "new_value"} = Concord.get("update_key")
    end
  end

  describe "complex values" do
    test "store and retrieve maps" do
      data = %{name: "Alice", age: 30, roles: ["admin", "user"]}
      assert :ok = Concord.put("user:1", data)
      assert {:ok, ^data} = Concord.get("user:1")
    end

    test "store and retrieve lists" do
      list = [1, 2, 3, 4, 5]
      assert :ok = Concord.put("numbers", list)
      assert {:ok, ^list} = Concord.get("numbers")
    end
  end

  describe "validation" do
    test "rejects invalid keys" do
      assert {:error, :invalid_key} = Concord.put("", "value")
      assert {:error, :invalid_key} = Concord.put(nil, "value")
      assert {:error, :invalid_key} = Concord.put(123, "value")
    end

    test "rejects keys that are too long" do
      long_key = String.duplicate("a", 1025)
      assert {:error, :invalid_key} = Concord.put(long_key, "value")
    end
  end

  describe "cluster operations" do
    test "get cluster status" do
      assert {:ok, status} = Concord.status()
      assert Map.has_key?(status, :cluster)
      assert Map.has_key?(status, :storage)
      assert Map.has_key?(status, :node)
    end

    test "get cluster members" do
      assert {:ok, members} = Concord.members()
      assert is_list(members)
    end
  end
end
