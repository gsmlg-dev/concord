defmodule Concord.TTLIntegrationTest do
  use ExUnit.Case, async: false

  import Concord.TestHelper

  @moduletag :capture_log

  describe "TTL Integration Tests" do
    setup do
      start_test_cluster()
      on_exit(fn -> stop_test_cluster() end)
      :ok
    end

    test "put with TTL option expires after specified time" do
      key = "ttl_test_key"
      value = "ttl_test_value"
      # Short TTL for testing
      ttl_seconds = 2

      # Put with TTL
      assert Concord.put(key, value, ttl: ttl_seconds) == :ok

      # Should be available immediately
      assert Concord.get(key) == {:ok, value}

      # Check TTL
      {:ok, remaining_ttl} = Concord.ttl(key)
      assert is_integer(remaining_ttl)
      assert remaining_ttl > 0
      assert remaining_ttl <= ttl_seconds

      # Wait for expiration
      Process.sleep((ttl_seconds + 1) * 1000)

      # Should be expired
      assert Concord.get(key) == {:error, :not_found}
      assert Concord.ttl(key) == {:error, :not_found}
    end

    test "put_with_ttl/4 function works correctly" do
      key = "put_with_ttl_key"
      value = "put_with_ttl_value"
      ttl_seconds = 3

      # Use put_with_ttl function
      assert Concord.put_with_ttl(key, value, ttl_seconds) == :ok

      # Should be available
      assert Concord.get(key) == {:ok, value}

      # Wait for expiration
      Process.sleep((ttl_seconds + 1) * 1000)

      # Should be expired
      assert Concord.get(key) == {:error, :not_found}
    end

    test "get_with_ttl/2 returns value and TTL information" do
      key = "get_with_ttl_key"
      value = "get_with_ttl_value"
      ttl_seconds = 10

      # Put with TTL
      assert Concord.put(key, value, ttl: ttl_seconds) == :ok

      # Get with TTL
      {:ok, {retrieved_value, remaining_ttl}} = Concord.get_with_ttl(key)
      assert retrieved_value == value
      assert is_integer(remaining_ttl)
      assert remaining_ttl > 0
      assert remaining_ttl <= ttl_seconds
    end

    test "get_with_ttl/2 handles non-TTL keys" do
      key = "no_ttl_key"
      value = "no_ttl_value"

      # Put without TTL
      assert Concord.put(key, value) == :ok

      # Get with TTL should return nil TTL
      {:ok, {retrieved_value, remaining_ttl}} = Concord.get_with_ttl(key)
      assert retrieved_value == value
      assert remaining_ttl == nil
    end

    test "touch/3 extends TTL of existing keys" do
      key = "touch_key"
      value = "touch_value"
      initial_ttl = 2
      extension = 3

      # Put with short TTL
      assert Concord.put_with_ttl(key, value, initial_ttl) == :ok

      # Verify it exists
      assert Concord.get(key) == {:ok, value}

      # Touch to extend TTL
      assert Concord.touch(key, extension) == :ok

      # Wait for original TTL to expire (but less than extension)
      Process.sleep(initial_ttl * 1000)

      # Should still be available due to extension
      assert Concord.get(key) == {:ok, value}

      # Check remaining TTL - should have ~1 second left
      {:ok, remaining_ttl} = Concord.ttl(key)
      assert is_integer(remaining_ttl)
      assert remaining_ttl > 0
    end

    test "touch/3 fails on non-existent keys" do
      result = Concord.touch("non_existent_key", 60)
      assert result == {:error, :not_found}
    end

    test "get_all_with_ttl/1 includes TTL information" do
      ttl_key = "all_ttl_key"
      ttl_value = "all_ttl_value"
      no_ttl_key = "all_no_ttl_key"
      no_ttl_value = "all_no_ttl_value"

      # Put one with TTL, one without
      assert Concord.put(ttl_key, ttl_value, ttl: 300) == :ok
      assert Concord.put(no_ttl_key, no_ttl_value) == :ok

      # Get all with TTL info
      {:ok, all_data} = Concord.get_all_with_ttl()

      # Should include both keys with TTL info
      assert Map.has_key?(all_data, ttl_key)
      assert Map.has_key?(all_data, no_ttl_key)

      assert %{value: ^ttl_value, ttl: _ttl} = all_data[ttl_key]
      assert all_data[no_ttl_key] == %{value: no_ttl_value, ttl: nil}
    end

    test "get_all/1 excludes expired keys" do
      ttl_key = "expire_all_key"
      ttl_value = "expire_all_value"
      no_ttl_key = "persist_all_key"
      no_ttl_value = "persist_all_value"

      # Put one with short TTL, one without
      assert Concord.put(ttl_key, ttl_value, ttl: 1) == :ok
      assert Concord.put(no_ttl_key, no_ttl_value) == :ok

      # Wait for expiration
      Process.sleep(1500)

      # Get all should only include non-expired key
      {:ok, all_data} = Concord.get_all()
      assert not Map.has_key?(all_data, ttl_key)
      assert Map.has_key?(all_data, no_ttl_key)
      assert all_data[no_ttl_key] == no_ttl_value
    end

    test "TTL validation rejects invalid values" do
      key = "validation_key"
      value = "validation_value"

      # Test invalid TTL values
      assert Concord.put(key, value, ttl: 0) == {:error, :invalid_ttl}
      assert Concord.put(key, value, ttl: -1) == {:error, :invalid_ttl}
      assert Concord.put(key, value, ttl: "invalid") == {:error, :invalid_ttl}
      assert Concord.put(key, value, ttl: :invalid) == {:error, :invalid_ttl}
    end

    test "TTL accepts valid values" do
      key = "valid_ttl_key"
      value = "valid_ttl_value"

      # Test valid TTL values
      assert Concord.put(key <> "_1", value, ttl: 1) == :ok
      assert Concord.put(key <> "_2", value, ttl: 3600) == :ok
      assert Concord.put(key <> "_3", value, ttl: 86400) == :ok
    end

    test "backward compatibility with existing keys" do
      key = "backward_compat_key"
      value = "backward_compat_value"

      # Put without TTL (old behavior)
      assert Concord.put(key, value) == :ok

      # All operations should work normally
      assert Concord.get(key) == {:ok, value}
      assert Concord.ttl(key) == {:ok, nil}
      {:ok, {retrieved_value, ttl}} = Concord.get_with_ttl(key)
      assert retrieved_value == value
      assert ttl == nil
    end

    test "delete works on TTL keys" do
      key = "delete_ttl_key"
      value = "delete_ttl_value"

      # Put with TTL
      assert Concord.put(key, value, ttl: 300) == :ok
      assert Concord.get(key) == {:ok, value}

      # Delete should work
      assert Concord.delete(key) == :ok
      assert Concord.get(key) == {:error, :not_found}
    end

    test "telemetry events are emitted for TTL operations" do
      # Set up telemetry test
      :telemetry.attach_many(
        "test-ttl-handler",
        [
          [:concord, :api, :put],
          [:concord, :api, :touch],
          [:concord, :api, :ttl],
          [:concord, :api, :get_with_ttl]
        ],
        &handle_telemetry_event/4,
        self()
      )

      key = "telemetry_ttl_key"
      value = "telemetry_ttl_value"

      # Put with TTL
      assert Concord.put(key, value, ttl: 60) == :ok
      assert_receive {:telemetry_event, [:concord, :api, :put], _, %{has_ttl: true}}

      # Touch
      assert Concord.touch(key, 30) == :ok
      assert_receive {:telemetry_event, [:concord, :api, :touch], _, _}

      # Get TTL
      {:ok, _ttl_result} = Concord.ttl(key)
      assert_receive {:telemetry_event, [:concord, :api, :ttl], _, _}

      # Get with TTL
      {:ok, {_value, _ttl_info}} = Concord.get_with_ttl(key)
      assert_receive {:telemetry_event, [:concord, :api, :get_with_ttl], _, _}

      # Clean up
      :telemetry.detach("test-ttl-handler")
    end

    defp handle_telemetry_event(event, measurements, metadata, test_pid) do
      send(test_pid, {:telemetry_event, event, measurements, metadata})
    end
  end
end
