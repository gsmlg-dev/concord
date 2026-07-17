defmodule Concord.BulkOperationsIntegrationTest do
  use ExUnit.Case, async: false

  import Concord.TestHelper

  @moduletag :capture_log

  describe "Bulk Operations Integration Tests" do
    setup do
      start_test_cluster()
      on_exit(fn -> stop_test_cluster() end)
      :ok
    end

    test "put_many/2 stores multiple key-value pairs atomically" do
      operations = [
        {"user:1", %{name: "Alice", age: 30}},
        {"user:2", %{name: "Bob", age: 25}},
        {"user:3", %{name: "Charlie", age: 35}}
      ]

      assert Concord.put_many(operations) ==
               {:ok,
                %{
                  "user:1" => :ok,
                  "user:2" => :ok,
                  "user:3" => :ok
                }}

      # Verify all values were stored
      assert Concord.get("user:1") == {:ok, %{name: "Alice", age: 30}}
      assert Concord.get("user:2") == {:ok, %{name: "Bob", age: 25}}
      assert Concord.get("user:3") == {:ok, %{name: "Charlie", age: 35}}
    end

    test "put_many/2 with mixed formats handles different operation types" do
      operations = [
        {"simple_key", "simple_value"},
        {"ttl_key", "ttl_value", 3600},
        {"expires_at_key", "expires_value", System.system_time(:second) + 7200}
      ]

      assert Concord.put_many(operations) ==
               {:ok,
                %{
                  "simple_key" => :ok,
                  "ttl_key" => :ok,
                  "expires_at_key" => :ok
                }}

      # Verify all values were stored
      assert Concord.get("simple_key") == {:ok, "simple_value"}
      assert Concord.get("ttl_key") == {:ok, "ttl_value"}
      assert Concord.get("expires_at_key") == {:ok, "expires_value"}

      # Verify TTL functionality works
      {:ok, ttl_remaining} = Concord.ttl("ttl_key")
      assert is_integer(ttl_remaining) and ttl_remaining > 0
    end

    test "put_many/2 rejects batches larger than limit" do
      # Create batch with 501 operations (over the 500 limit)
      operations = List.duplicate({"key", "value"}, 501)

      assert Concord.put_many(operations) == {:error, :batch_too_large}
    end

    test "put_many/2 rejects invalid operations" do
      operations = [
        {"valid_key", "valid_value"},
        # Empty key
        {"", "invalid_value"}
      ]

      assert Concord.put_many(operations) == {:error, :invalid_key}
    end

    test "put_many_with_ttl/3 stores multiple key-value pairs with TTL" do
      operations = [
        {"cache:1", "data1"},
        {"cache:2", "data2"},
        {"cache:3", "data3"}
      ]

      ttl_seconds = 3600

      assert Concord.put_many_with_ttl(operations, ttl_seconds) ==
               {:ok,
                %{
                  "cache:1" => :ok,
                  "cache:2" => :ok,
                  "cache:3" => :ok
                }}

      # Verify TTL was set for all keys
      Enum.each(["cache:1", "cache:2", "cache:3"], fn key ->
        {:ok, remaining_ttl} = Concord.ttl(key)
        assert is_integer(remaining_ttl)
        assert remaining_ttl > 0
        assert remaining_ttl <= ttl_seconds
      end)
    end

    test "get_many/2 retrieves multiple values" do
      # Setup some data first
      operations = [
        {"key1", "value1"},
        {"key2", "value2"},
        {"key3", "value3"}
      ]

      assert Concord.put_many(operations) == {:ok, %{"key1" => :ok, "key2" => :ok, "key3" => :ok}}

      # Retrieve multiple keys
      keys = ["key1", "key2", "key3", "nonexistent"]

      assert Concord.get_many(keys) ==
               {:ok,
                %{
                  "key1" => {:ok, "value1"},
                  "key2" => {:ok, "value2"},
                  "key3" => {:ok, "value3"},
                  "nonexistent" => {:error, :not_found}
                }}
    end

    test "get_many/2 respects TTL expiration" do
      # Setup data with TTL
      operations = [
        {"ttl_key1", "value1"},
        {"ttl_key2", "value2"}
      ]

      # 1 second TTL
      assert Concord.put_many_with_ttl(operations, 1) ==
               {:ok, %{"ttl_key1" => :ok, "ttl_key2" => :ok}}

      # Wait for expiration (need >2s for second-precision expiry)
      Process.sleep(2100)

      # Manually trigger cleanup to ensure expired keys are removed
      try do
        :ra.process_command({:concord_cluster, node()}, :cleanup_expired, 5000)
      rescue
        # Ignore if cleanup fails
        _ -> :ok
      end

      # Should return not found for expired keys
      assert Concord.get_many(["ttl_key1", "ttl_key2"]) ==
               {:ok,
                %{
                  "ttl_key1" => {:error, :not_found},
                  "ttl_key2" => {:error, :not_found}
                }}
    end

    test "delete_many/2 deletes multiple keys atomically" do
      # Setup some data
      operations = [
        {"delete1", "value1"},
        {"delete2", "value2"},
        {"keep1", "value3"},
        {"delete3", "value4"}
      ]

      assert Concord.put_many(operations) ==
               {:ok,
                %{
                  "delete1" => :ok,
                  "delete2" => :ok,
                  "keep1" => :ok,
                  "delete3" => :ok
                }}

      # Delete multiple keys
      keys_to_delete = ["delete1", "delete3"]

      assert Concord.delete_many(keys_to_delete) ==
               {:ok,
                %{
                  "delete1" => :ok,
                  "delete3" => :ok
                }}

      # Verify deleted keys are gone
      assert Concord.get("delete1") == {:error, :not_found}
      assert Concord.get("delete3") == {:error, :not_found}

      # Verify other key remains
      assert Concord.get("delete2") == {:ok, "value2"}
      assert Concord.get("keep1") == {:ok, "value3"}
    end

    test "touch_many/2 extends TTL for multiple keys" do
      # Setup data with TTL
      operations = [
        {"touch1", "value1"},
        {"touch2", "value2"}
      ]

      # 2 second TTL
      assert Concord.put_many_with_ttl(operations, 2) ==
               {:ok, %{"touch1" => :ok, "touch2" => :ok}}

      # Verify initial TTL
      {:ok, initial_ttl1} = Concord.ttl("touch1")
      {:ok, initial_ttl2} = Concord.ttl("touch2")
      assert initial_ttl1 <= 2
      assert initial_ttl2 <= 2

      # Wait a bit
      Process.sleep(500)

      # Extend TTL
      touch_operations = [
        # 1 hour
        {"touch1", 3600},
        # 2 hours
        {"touch2", 7200}
      ]

      assert Concord.touch_many(touch_operations) ==
               {:ok,
                %{
                  "touch1" => :ok,
                  "touch2" => :ok
                }}

      # Verify TTL was extended
      {:ok, extended_ttl1} = Concord.ttl("touch1")
      {:ok, extended_ttl2} = Concord.ttl("touch2")
      # Should be close to 1 hour
      assert extended_ttl1 > 3000
      # Should be close to 2 hours
      assert extended_ttl2 > 6000
    end

    test "touch_many/2 handles non-existent keys" do
      touch_operations = [
        {"existent", 3600},
        {"nonexistent", 1800}
      ]

      # First put an existing key
      assert Concord.put("existent", "value", ttl: 100) == :ok

      # Touch both keys
      result = Concord.touch_many(touch_operations)

      assert result ==
               {:ok,
                %{
                  "existent" => :ok,
                  "nonexistent" => {:error, :not_found}
                }}
    end

    test "atomic behavior - all operations succeed or fail together" do
      # This test verifies that put_many is atomic by creating a scenario
      # where some operations might fail due to invalid data

      # First, put some valid data
      valid_operations = [
        {"preexisting1", "value1"},
        {"preexisting2", "value2"}
      ]

      assert Concord.put_many(valid_operations) ==
               {:ok, %{"preexisting1" => :ok, "preexisting2" => :ok}}

      # Now try a batch with one invalid operation
      mixed_operations = [
        {"new_valid1", "new_value1"},
        # This should cause the whole batch to fail
        {"", "invalid_key"},
        {"new_valid2", "new_value2"}
      ]

      # The whole batch should fail
      assert Concord.put_many(mixed_operations) == {:error, :invalid_key}

      # Verify that none of the new valid data was stored
      assert Concord.get("new_valid1") == {:error, :not_found}
      assert Concord.get("new_valid2") == {:error, :not_found}

      # Verify preexisting data is still there
      assert Concord.get("preexisting1") == {:ok, "value1"}
      assert Concord.get("preexisting2") == {:ok, "value2"}
    end

    test "telemetry events are emitted for bulk operations" do
      # Set up telemetry test
      :telemetry.attach_many(
        "test-bulk-handler",
        [
          [:concord, :api, :put_many],
          [:concord, :api, :get_many],
          [:concord, :api, :delete_many],
          [:concord, :api, :touch_many]
        ],
        &handle_bulk_telemetry_event/4,
        self()
      )

      operations = [
        {"telemetry_key1", "value1"},
        {"telemetry_key2", "value2"}
      ]

      # Put many
      assert Concord.put_many(operations) ==
               {:ok, %{"telemetry_key1" => :ok, "telemetry_key2" => :ok}}

      assert_receive {:telemetry_event, [:concord, :api, :put_many], _, %{batch_size: 2}}

      # Get many
      assert Concord.get_many(["telemetry_key1", "telemetry_key2"]) ==
               {:ok,
                %{
                  "telemetry_key1" => {:ok, "value1"},
                  "telemetry_key2" => {:ok, "value2"}
                }}

      assert_receive {:telemetry_event, [:concord, :api, :get_many], _, %{batch_size: 2}}

      # Delete many
      assert Concord.delete_many(["telemetry_key1", "telemetry_key2"]) ==
               {:ok,
                %{
                  "telemetry_key1" => :ok,
                  "telemetry_key2" => :ok
                }}

      assert_receive {:telemetry_event, [:concord, :api, :delete_many], _, %{batch_size: 2}}

      # Clean up
      :telemetry.detach("test-bulk-handler")
    end

    defp handle_bulk_telemetry_event(event, measurements, metadata, test_pid) do
      send(test_pid, {:telemetry_event, event, measurements, metadata})
    end
  end
end
