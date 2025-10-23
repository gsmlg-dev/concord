defmodule Concord.ConditionalUpdatesTest do
  use ExUnit.Case, async: false

  setup do
    # Start test cluster
    :ok = Concord.TestHelper.start_test_cluster()

    # Clean up any existing keys
    case Concord.get_all() do
      {:ok, pairs} ->
        keys = Enum.map(pairs, fn {k, _v} -> k end)
        if length(keys) > 0, do: Concord.delete_many(keys)

      _ ->
        :ok
    end

    :ok
  end

  describe "put_if/3 with expected value" do
    test "succeeds when expected value matches" do
      # Set initial value
      :ok = Concord.put("counter", 0)

      # Update only if current value is 0
      assert :ok = Concord.put_if("counter", 1, expected: 0)

      # Verify update
      assert {:ok, 1} = Concord.get("counter")
    end

    test "fails when expected value doesn't match" do
      # Set initial value
      :ok = Concord.put("counter", 5)

      # Try to update expecting 0, but current is 5
      assert {:error, :condition_failed} = Concord.put_if("counter", 10, expected: 0)

      # Verify value unchanged
      assert {:ok, 5} = Concord.get("counter")
    end

    test "fails when key doesn't exist" do
      # Try to update non-existent key
      assert {:error, :not_found} = Concord.put_if("nonexistent", "value", expected: "old")
    end

    test "works with complex values" do
      # Set initial value
      config = %{version: 1, settings: %{enabled: true}}
      :ok = Concord.put("config", config)

      # Update only if version matches
      new_config = %{version: 2, settings: %{enabled: false}}
      assert :ok = Concord.put_if("config", new_config, expected: config)

      # Verify update
      assert {:ok, ^new_config} = Concord.get("config")
    end

    test "supports TTL option" do
      :ok = Concord.put("temp", "v1")

      assert :ok = Concord.put_if("temp", "v2", expected: "v1", ttl: 3600)

      # Verify value and TTL
      assert {:ok, {"v2", ttl}} = Concord.get_with_ttl("temp")
      assert ttl > 0 and ttl <= 3600
    end
  end

  describe "put_if/3 with condition function" do
    test "succeeds when condition returns true" do
      :ok = Concord.put("version", %{number: 1, data: "old"})

      new_value = %{number: 2, data: "new"}

      assert :ok =
               Concord.put_if("version", new_value,
                 condition: fn current -> current.number < new_value.number end
               )

      assert {:ok, ^new_value} = Concord.get("version")
    end

    test "fails when condition returns false" do
      :ok = Concord.put("version", %{number: 10, data: "current"})

      old_value = %{number: 5, data: "old"}

      assert {:error, :condition_failed} =
               Concord.put_if("version", old_value,
                 condition: fn current -> current.number < old_value.number end
               )

      # Value unchanged
      assert {:ok, %{number: 10}} = Concord.get("version")
    end

    test "works with custom predicates" do
      :ok = Concord.put("product", %{price: 100, discount: 0})

      # Only update if price is below threshold
      assert :ok =
               Concord.put_if("product", %{price: 80, discount: 20},
                 condition: fn p -> p.price >= 80 end
               )

      assert {:ok, %{discount: 20}} = Concord.get("product")
    end
  end

  describe "put_if/3 validation" do
    test "requires either expected or condition" do
      :ok = Concord.put("key", "value")

      assert {:error, :missing_condition} = Concord.put_if("key", "new_value", [])
    end

    test "rejects both expected and condition" do
      :ok = Concord.put("key", "value")

      assert {:error, :conflicting_conditions} =
               Concord.put_if("key", "new_value",
                 expected: "value",
                 condition: fn _ -> true end
               )
    end

    test "validates key" do
      assert {:error, :invalid_key} = Concord.put_if("", "value", expected: "old")
    end
  end

  describe "delete_if/2 with expected value" do
    test "succeeds when expected value matches" do
      :ok = Concord.put("lock", "session-123")

      assert :ok = Concord.delete_if("lock", expected: "session-123")

      # Verify deletion
      assert {:error, :not_found} = Concord.get("lock")
    end

    test "fails when expected value doesn't match" do
      :ok = Concord.put("lock", "session-456")

      assert {:error, :condition_failed} = Concord.delete_if("lock", expected: "session-123")

      # Verify not deleted
      assert {:ok, "session-456"} = Concord.get("lock")
    end

    test "fails when key doesn't exist" do
      assert {:error, :not_found} = Concord.delete_if("nonexistent", expected: "value")
    end

    test "works with complex values" do
      lock_data = %{owner: "process-1", acquired_at: DateTime.utc_now()}
      :ok = Concord.put("resource_lock", lock_data)

      assert :ok = Concord.delete_if("resource_lock", expected: lock_data)

      assert {:error, :not_found} = Concord.get("resource_lock")
    end
  end

  describe "delete_if/2 with condition function" do
    test "succeeds when condition returns true" do
      :ok = Concord.put("temp_file", %{created_at: ~U[2020-01-01 00:00:00Z], size: 100})

      cutoff = ~U[2021-01-01 00:00:00Z]

      assert :ok =
               Concord.delete_if("temp_file",
                 condition: fn file -> DateTime.compare(file.created_at, cutoff) == :lt end
               )

      assert {:error, :not_found} = Concord.get("temp_file")
    end

    test "fails when condition returns false" do
      recent_time = DateTime.utc_now()
      :ok = Concord.put("recent_file", %{created_at: recent_time, size: 50})

      cutoff = DateTime.add(recent_time, -3600)

      assert {:error, :condition_failed} =
               Concord.delete_if("recent_file",
                 condition: fn file -> DateTime.compare(file.created_at, cutoff) == :lt end
               )

      # File still exists
      assert {:ok, %{size: 50}} = Concord.get("recent_file")
    end
  end

  describe "delete_if/2 validation" do
    test "requires either expected or condition" do
      :ok = Concord.put("key", "value")

      assert {:error, :missing_condition} = Concord.delete_if("key", [])
    end

    test "rejects both expected and condition" do
      :ok = Concord.put("key", "value")

      assert {:error, :conflicting_conditions} =
               Concord.delete_if("key",
                 expected: "value",
                 condition: fn _ -> true end
               )
    end
  end

  describe "concurrent updates" do
    test "compare-and-swap prevents lost updates" do
      # Simulate two processes trying to increment a counter
      :ok = Concord.put("shared_counter", 0)

      # Process 1 reads current value
      {:ok, current1} = Concord.get("shared_counter")

      # Process 2 reads current value
      {:ok, current2} = Concord.get("shared_counter")

      # Process 1 tries to increment
      result1 = Concord.put_if("shared_counter", current1 + 1, expected: current1)

      # Process 2 tries to increment with stale value
      result2 = Concord.put_if("shared_counter", current2 + 1, expected: current2)

      # One should succeed, one should fail
      assert {res1, res2} = {result1, result2}
      assert (:ok in [res1, res2] and {:error, :condition_failed} in [res1, res2])

      # Final value should be 1 (only one increment succeeded)
      assert {:ok, 1} = Concord.get("shared_counter")
    end

    test "distributed lock implementation" do
      lock_id = "my-lock-#{System.unique_integer()}"

      # Acquire lock - only succeeds if key doesn't exist
      # (We use expected: nil for this, but key must exist, so we use condition instead)
      :ok = Concord.put("distributed_lock", lock_id)

      # Try to acquire with different ID - should fail
      assert {:error, :condition_failed} =
               Concord.put_if("distributed_lock", "other-lock", expected: "wrong-id")

      # Release lock - only succeeds if we own it
      assert :ok = Concord.delete_if("distributed_lock", expected: lock_id)

      # Lock is now released
      assert {:error, :not_found} = Concord.get("distributed_lock")
    end
  end

  describe "TTL interaction" do
    test "put_if fails on expired key" do
      # Set key with very short TTL
      ttl_seconds = 1
      :ok = Concord.put("expiring", "value", ttl: ttl_seconds)

      # Wait for expiration
      Process.sleep((ttl_seconds + 1) * 1000)

      # Conditional update should fail with not_found
      assert {:error, :not_found} = Concord.put_if("expiring", "new", expected: "value")
    end

    test "delete_if fails on expired key" do
      ttl_seconds = 1
      :ok = Concord.put("expiring", "value", ttl: ttl_seconds)

      # Wait for expiration
      Process.sleep((ttl_seconds + 1) * 1000)

      assert {:error, :not_found} = Concord.delete_if("expiring", expected: "value")
    end
  end
end
