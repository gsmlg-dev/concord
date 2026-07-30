defmodule Concord.IndexTest do
  use ExUnit.Case, async: false

  setup do
    # Start test cluster
    :ok = Concord.TestHelper.start_test_cluster()

    on_exit(fn ->
      Concord.TestHelper.stop_test_cluster()
    end)

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
      extractor = {:map_get, :email}
      assert :ok = Concord.Index.create("users_by_email", extractor)

      {:ok, indexes} = Concord.Index.list()
      assert "users_by_email" in indexes
    end

    test "returns error if index already exists" do
      extractor = {:map_get, :email}
      :ok = Concord.Index.create("users_by_email", extractor)

      assert {:error, :index_exists} = Concord.Index.create("users_by_email", extractor)
    end

    test "validates index name" do
      assert {:error, :invalid_name} = Concord.Index.create("", {:identity})
      assert {:error, :invalid_name} = Concord.Index.create(nil, {:identity})
      assert {:error, :invalid_name} = Concord.Index.create(<<255>>, {:identity})

      assert {:error, :invalid_name} =
               Concord.Index.create(String.duplicate("x", 256), {:identity})
    end

    test "validates declarative extractors" do
      assert {:error, :invalid_extractor} = Concord.Index.create("test", "not_a_function")
      assert {:error, :invalid_extractor} = Concord.Index.create("test", nil)
      assert {:error, :invalid_extractor} = Concord.Index.create("test", fn value -> value end)
    end

    test "rejects function extractors from local and replicated APIs" do
      extractor = fn value -> value end

      assert {:error, :invalid_extractor} = Concord.Local.Index.create("local", extractor)
      assert {:error, :invalid_extractor} = Concord.Cluster.Index.create("cluster", extractor)
      assert {:ok, []} = Concord.Index.list()
    end

    test "supports reindex option" do
      # Add some data first
      :ok = Concord.put("user:1", %{email: "alice@example.com"})
      :ok = Concord.put("user:2", %{email: "bob@example.com"})

      # Create index with reindex
      extractor = {:map_get, :email}
      assert :ok = Concord.Index.create("users_by_email", extractor, reindex: true)

      # Should be able to lookup existing data
      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      assert keys == ["user:1"]
    end
  end

  describe "Index.drop/2" do
    test "drops an existing index" do
      :ok = Concord.Index.create("test_index", {:map_get, :id})
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
      :ok = Concord.Index.create("users_by_email", {:map_get, :email})

      :ok = Concord.put("user:1", %{name: "Alice", email: "alice@example.com"})
      :ok = Concord.put("user:2", %{name: "Bob", email: "bob@example.com"})
      :ok = Concord.put("user:3", %{name: "Alice2", email: "alice@example.com"})

      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      assert length(keys) == 2
      assert "user:1" in keys
      assert "user:3" in keys
    end

    test "returns empty list if no matches" do
      :ok = Concord.Index.create("users_by_email", {:map_get, :email})

      {:ok, keys} = Concord.Index.lookup("users_by_email", "nobody@example.com")
      assert keys == []
    end

    test "returns error if index doesn't exist" do
      assert {:error, :not_found} = Concord.Index.lookup("nonexistent", "value")
    end

    test "handles multi-value indexes (tags)" do
      :ok = Concord.Index.create("posts_by_tag", {:map_get, :tags})

      :ok = Concord.put("post:1", %{title: "Elixir", tags: ["elixir", "functional"]})
      :ok = Concord.put("post:2", %{title: "VSR", tags: ["distributed", "consensus"]})
      :ok = Concord.put("post:3", %{title: "OTP", tags: ["elixir", "otp"]})

      {:ok, keys} = Concord.Index.lookup("posts_by_tag", "elixir")
      assert length(keys) == 2
      assert "post:1" in keys
      assert "post:3" in keys

      {:ok, keys} = Concord.Index.lookup("posts_by_tag", "distributed")
      assert keys == ["post:2"]
    end

    test "skips values when declarative extraction returns nil" do
      :ok = Concord.Index.create("active_users", {:map_get, :active_id})

      :ok = Concord.put("user:1", %{id: 1, active_id: 1})
      :ok = Concord.put("user:2", %{id: 2, active_id: nil})
      :ok = Concord.put("user:3", %{id: 3, active_id: 3})

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

      :ok = Concord.Index.create("index1", {:map_get, :a})
      :ok = Concord.Index.create("index2", {:map_get, :b})

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
      :ok = Concord.Index.create("users_by_email", {:map_get, :email})

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
      :ok = Concord.Index.create("users_by_email", {:map_get, :email})

      :ok = Concord.put("user:1", %{email: "alice@example.com"})

      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      assert keys == ["user:1"]
    end

    test "updates index when value changes" do
      :ok = Concord.Index.create("users_by_email", {:map_get, :email})

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
      :ok = Concord.Index.create("users_by_email", {:map_get, :email})

      :ok = Concord.put("user:1", %{email: "alice@example.com"})
      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      assert keys == ["user:1"]

      :ok = Concord.delete("user:1")

      {:ok, keys} = Concord.Index.lookup("users_by_email", "alice@example.com")
      assert keys == []
    end

    test "handles multi-value index updates" do
      :ok = Concord.Index.create("posts_by_tag", {:map_get, :tags})

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
      :ok = Concord.Index.create("users_by_role", {:map_get, :role})

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

  describe "invalid extractors" do
    test "does not create an index for an anonymous function" do
      assert {:error, :invalid_extractor} =
               Concord.Index.create("bad_index", fn value -> value end)

      assert {:ok, []} = Concord.Index.list()
    end
  end

  describe "index with compression" do
    test "works with compressed values" do
      :ok = Concord.Index.create("products_by_category", {:map_get, :category})

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
