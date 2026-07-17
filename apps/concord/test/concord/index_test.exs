defmodule Concord.IndexTest do
  use ExUnit.Case, async: false

  setup do
    # Start test cluster
    :ok = Concord.TestHelper.start_test_cluster()

    # Wait a bit for cluster to fully initialize
    Process.sleep(100)

    # Clean up any existing keys and indexes
    case Concord.get_all() do
      {:ok, pairs} ->
        keys = Enum.map(pairs, fn {k, _v} -> k end)
        if length(keys) > 0, do: Concord.delete_many(keys)

      _ ->
        :ok
    end

    # Drop any existing indexes
    case Concord.Index.list() do
      {:ok, indexes} ->
        Enum.each(indexes, fn name ->
          Concord.Index.drop(name)
        end)

      _ ->
        :ok
    end

    :ok
  end

  describe "Index.create/3" do
    test "creates a new index" do
      extractor = fn user -> user.email end
      assert :ok = Concord.Index.create("users_by_email", extractor)

      {:ok, indexes} = Concord.Index.list()
      assert "users_by_email" in indexes
    end

    test "returns error if index already exists" do
      extractor = fn user -> user.email end
      :ok = Concord.Index.create("users_by_email", extractor)

      assert {:error, :index_exists} = Concord.Index.create("users_by_email", extractor)
    end

    test "validates index name" do
      assert {:error, :invalid_name} = Concord.Index.create("", fn x -> x end)
      assert {:error, :invalid_name} = Concord.Index.create(nil, fn x -> x end)
    end

    test "validates extractor function" do
      assert {:error, :invalid_extractor} = Concord.Index.create("test", "not_a_function")
      assert {:error, :invalid_extractor} = Concord.Index.create("test", nil)
    end

    test "supports reindex option" do
      # Add some data first
      :ok = Concord.put("user:1", %{email: "alice@example.com"})
      :ok = Concord.put("user:2", %{email: "bob@example.com"})

      # Create index with reindex
      extractor = fn user -> user.email end
      assert :ok = Concord.Index.create("users_by_email", extractor, reindex: true)

      # Should be able to lookup existing data
      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      assert keys == ["user:1"]
    end
  end

  describe "Index.drop/2" do
    test "drops an existing index" do
      :ok = Concord.Index.create("test_index", fn x -> x.id end)
      {:ok, indexes} = Concord.Index.list()
      assert "test_index" in indexes

      assert :ok = Concord.Index.drop("test_index")

      {:ok, indexes} = Concord.Index.list()
      refute "test_index" in indexes
    end

    test "returns error if index doesn't exist" do
      assert {:error, :not_found} = Concord.Index.drop("nonexistent")
    end
  end

  describe "Index.lookup/3" do
    test "finds keys by indexed value" do
      :ok = Concord.Index.create("users_by_email", fn u -> u.email end)

      :ok = Concord.put("user:1", %{name: "Alice", email: "alice@example.com"})
      :ok = Concord.put("user:2", %{name: "Bob", email: "bob@example.com"})
      :ok = Concord.put("user:3", %{name: "Alice2", email: "alice@example.com"})

      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      assert length(keys) == 2
      assert "user:1" in keys
      assert "user:3" in keys
    end

    test "returns empty list if no matches" do
      :ok = Concord.Index.create("users_by_email", fn u -> u.email end)

      {:ok, keys} = Concord.Index.lookup("users_by_email", "nobody@example.com")
      assert keys == []
    end

    test "returns error if index doesn't exist" do
      assert {:error, :not_found} = Concord.Index.lookup("nonexistent", "value")
    end

    test "handles multi-value indexes (tags)" do
      :ok = Concord.Index.create("posts_by_tag", fn post -> post.tags end)

      :ok = Concord.put("post:1", %{title: "Elixir", tags: ["elixir", "functional"]})
      :ok = Concord.put("post:2", %{title: "Raft", tags: ["distributed", "consensus"]})
      :ok = Concord.put("post:3", %{title: "OTP", tags: ["elixir", "otp"]})

      {:ok, keys} = Concord.Index.lookup("posts_by_tag", "elixir")
      assert length(keys) == 2
      assert "post:1" in keys
      assert "post:3" in keys

      {:ok, keys} = Concord.Index.lookup("posts_by_tag", "distributed")
      assert keys == ["post:2"]
    end

    test "handles conditional indexing (nil skips)" do
      :ok =
        Concord.Index.create("active_users", fn user ->
          if user.active, do: user.id, else: nil
        end)

      :ok = Concord.put("user:1", %{id: 1, active: true})
      :ok = Concord.put("user:2", %{id: 2, active: false})
      :ok = Concord.put("user:3", %{id: 3, active: true})

      {:ok, keys} = Concord.Index.lookup("active_users", 1)
      assert keys == ["user:1"]

      {:ok, keys} = Concord.Index.lookup("active_users", 2)
      # user:2 is not indexed because active=false
      assert keys == []
    end
  end

  describe "Index.list/1" do
    test "lists all indexes" do
      {:ok, indexes} = Concord.Index.list()
      assert indexes == []

      :ok = Concord.Index.create("index1", fn x -> x.a end)
      :ok = Concord.Index.create("index2", fn x -> x.b end)

      {:ok, indexes} = Concord.Index.list()
      assert length(indexes) == 2
      assert "index1" in indexes
      assert "index2" in indexes
    end
  end

  describe "Index.reindex/2" do
    test "rebuilds index from existing data" do
      # Add data before creating index
      :ok = Concord.put("user:1", %{email: "alice@example.com"})
      :ok = Concord.put("user:2", %{email: "bob@example.com"})

      # Create index without reindex option
      :ok = Concord.Index.create("users_by_email", fn u -> u.email end)

      # Initially empty because data was added before index
      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      assert keys == []

      # Reindex
      assert :ok = Concord.Index.reindex("users_by_email")

      # Now should find the data
      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      assert keys == ["user:1"]
    end

    test "returns error if index doesn't exist" do
      assert {:error, :not_found} = Concord.Index.reindex("nonexistent")
    end
  end

  describe "automatic index maintenance" do
    test "updates index on put" do
      :ok = Concord.Index.create("users_by_email", fn u -> u.email end)

      :ok = Concord.put("user:1", %{email: "alice@example.com"})

      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      assert keys == ["user:1"]
    end

    test "updates index when value changes" do
      :ok = Concord.Index.create("users_by_email", fn u -> u.email end)

      :ok = Concord.put("user:1", %{email: "alice@example.com"})
      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      assert keys == ["user:1"]

      # Change email
      :ok = Concord.put("user:1", %{email: "alice.new@example.com"})

      # Old email should have no results
      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      assert keys == []

      # New email should find the key
      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice.new@example.com")
      assert keys == ["user:1"]
    end

    test "removes from index on delete" do
      :ok = Concord.Index.create("users_by_email", fn u -> u.email end)

      :ok = Concord.put("user:1", %{email: "alice@example.com"})
      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      assert keys == ["user:1"]

      :ok = Concord.delete("user:1")

      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      assert keys == []
    end

    test "handles multi-value index updates" do
      :ok = Concord.Index.create("posts_by_tag", fn post -> post.tags end)

      :ok = Concord.put("post:1", %{tags: ["elixir", "functional"]})

      {:ok, keys} = Concord.Index.lookup("posts_by_tag", "elixir")
      assert keys == ["post:1"]

      # Update tags
      :ok = Concord.put("post:1", %{tags: ["erlang", "functional"]})

      # Old tag should be removed
      {:ok, keys} = Concord.Index.lookup("posts_by_tag", "elixir")
      assert keys == []

      # New tag should be present
      {:ok, keys} = Concord.Index.lookup("posts_by_tag", "erlang")
      assert keys == ["post:1"]

      # Common tag should still be present
      {:ok, keys} = Concord.Index.lookup("posts_by_tag", "functional")
      assert keys == ["post:1"]
    end
  end

  describe "integration with Query module" do
    test "can use indexed lookup with get_many" do
      :ok = Concord.Index.create("users_by_role", fn u -> u.role end)

      :ok = Concord.put("user:1", %{name: "Alice", role: "admin"})
      :ok = Concord.put("user:2", %{name: "Bob", role: "user"})
      :ok = Concord.put("user:3", %{name: "Charlie", role: "admin"})

      # Find all admins using index
      {:ok, admin_keys} = Concord.Index.lookup("users_by_role", "admin")
      {:ok, admins} = Concord.get_many(admin_keys)

      admin_names =
        admins
        |> Enum.map(fn {_k, {:ok, user}} -> user.name end)
        |> Enum.sort()

      assert admin_names == ["Alice", "Charlie"]
    end
  end

  describe "error handling" do
    test "handles extractor exceptions gracefully" do
      # Extractor that might raise
      :ok =
        Concord.Index.create("bad_index", fn value ->
          if is_map(value), do: value.field, else: raise("oops")
        end)

      # Should not crash when extractor fails
      :ok = Concord.put("key:1", "not_a_map")

      # Index lookup should work
      {:ok, keys} = Concord.Index.lookup("bad_index", "anything")
      assert keys == []
    end
  end

  describe "index with compression" do
    test "works with compressed values" do
      :ok = Concord.Index.create("products_by_category", fn p -> p.category end)

      # Put with compression
      large_value = %{
        category: "electronics",
        description: String.duplicate("x", 2000)
      }

      :ok = Concord.put("product:1", large_value)

      # Index should work with decompressed values
      {:ok, keys} = Concord.Index.lookup("products_by_category", "electronics")
      assert keys == ["product:1"]
    end
  end
end
