defmodule Concord.ReadConsistencyTest do
  use ExUnit.Case, async: false

  setup do
    # Start test cluster
    :ok = Concord.TestHelper.start_test_cluster()

    # Clean up on exit
    on_exit(fn ->
      Concord.TestHelper.stop_test_cluster()
    end)

    :ok
  end

  describe "read consistency levels" do
    test "get/2 with :eventual consistency" do
      key = "test_key_eventual_#{:rand.uniform(10000)}"
      value = "test_value"

      # Put a value
      assert :ok = Concord.put(key, value)

      # Read with eventual consistency
      assert {:ok, ^value} = Concord.get(key, consistency: :eventual)
    end

    test "get/2 with :leader consistency" do
      key = "test_key_leader_#{:rand.uniform(10000)}"
      value = "test_value_leader"

      # Put a value
      assert :ok = Concord.put(key, value)

      # Read with leader consistency (default)
      assert {:ok, ^value} = Concord.get(key, consistency: :leader)
    end

    test "get/2 with :strong consistency" do
      key = "test_key_strong_#{:rand.uniform(10000)}"
      value = "test_value_strong"

      # Put a value
      assert :ok = Concord.put(key, value)

      # Read with strong consistency
      assert {:ok, ^value} = Concord.get(key, consistency: :strong)
    end

    test "get/2 defaults to configured consistency level" do
      key = "test_key_default_#{:rand.uniform(10000)}"
      value = "test_value_default"

      # Put a value
      assert :ok = Concord.put(key, value)

      # Read without specifying consistency (should use default :leader)
      assert {:ok, ^value} = Concord.get(key)
    end

    test "get/2 handles non-existent key with all consistency levels" do
      key = "non_existent_#{:rand.uniform(10000)}"

      assert {:error, :not_found} = Concord.get(key, consistency: :eventual)
      assert {:error, :not_found} = Concord.get(key, consistency: :leader)
      assert {:error, :not_found} = Concord.get(key, consistency: :strong)
    end
  end

  describe "get_many/2 with consistency levels" do
    test "get_many/2 with :eventual consistency" do
      keys = ["batch_key1_#{:rand.uniform(10000)}", "batch_key2_#{:rand.uniform(10000)}"]
      values = ["value1", "value2"]

      # Put values
      Enum.zip(keys, values)
      |> Enum.each(fn {key, value} -> Concord.put(key, value) end)

      # Read with eventual consistency
      {:ok, results} = Concord.get_many(keys, consistency: :eventual)

      assert {:ok, "value1"} = Map.get(results, hd(keys))
      assert {:ok, "value2"} = Map.get(results, List.last(keys))
    end

    test "get_many/2 with :strong consistency" do
      keys = ["strong_key1_#{:rand.uniform(10000)}", "strong_key2_#{:rand.uniform(10000)}"]
      values = ["value1", "value2"]

      # Put values
      Enum.zip(keys, values)
      |> Enum.each(fn {key, value} -> Concord.put(key, value) end)

      # Read with strong consistency
      {:ok, results} = Concord.get_many(keys, consistency: :strong)

      assert {:ok, "value1"} = Map.get(results, hd(keys))
      assert {:ok, "value2"} = Map.get(results, List.last(keys))
    end
  end

  describe "get_with_ttl/2 with consistency levels" do
    test "get_with_ttl/2 with different consistency levels" do
      key = "ttl_key_#{:rand.uniform(10000)}"
      value = "ttl_value"
      ttl = 3600

      # Put with TTL
      assert :ok = Concord.put_with_ttl(key, value, ttl)

      # Read with different consistency levels
      assert {:ok, {^value, remaining_ttl}} = Concord.get_with_ttl(key, consistency: :eventual)
      assert remaining_ttl > 0 and remaining_ttl <= ttl

      assert {:ok, {^value, _}} = Concord.get_with_ttl(key, consistency: :leader)
      assert {:ok, {^value, _}} = Concord.get_with_ttl(key, consistency: :strong)
    end
  end

  describe "ttl/2 with consistency levels" do
    test "ttl/2 with different consistency levels" do
      key = "ttl_check_#{:rand.uniform(10000)}"
      value = "value"
      ttl = 7200

      # Put with TTL
      assert :ok = Concord.put_with_ttl(key, value, ttl)

      # Check TTL with different consistency levels
      assert {:ok, remaining} = Concord.ttl(key, consistency: :eventual)
      assert remaining > 0 and remaining <= ttl

      assert {:ok, _} = Concord.ttl(key, consistency: :leader)
      assert {:ok, _} = Concord.ttl(key, consistency: :strong)
    end
  end

  describe "get_all/1 with consistency levels" do
    test "get_all/1 with different consistency levels" do
      # Put some test data
      key1 = "all_key1_#{:rand.uniform(10000)}"
      key2 = "all_key2_#{:rand.uniform(10000)}"

      assert :ok = Concord.put(key1, "value1")
      assert :ok = Concord.put(key2, "value2")

      # Read all with different consistency levels
      {:ok, results_eventual} = Concord.get_all(consistency: :eventual)
      assert is_map(results_eventual)
      assert Map.has_key?(results_eventual, key1)
      assert Map.has_key?(results_eventual, key2)

      {:ok, results_leader} = Concord.get_all(consistency: :leader)
      assert is_map(results_leader)

      {:ok, results_strong} = Concord.get_all(consistency: :strong)
      assert is_map(results_strong)
    end
  end

  describe "get_all_with_ttl/1 with consistency levels" do
    test "get_all_with_ttl/1 with different consistency levels" do
      key = "all_ttl_#{:rand.uniform(10000)}"
      value = "value_with_ttl"
      ttl = 3600

      assert :ok = Concord.put_with_ttl(key, value, ttl)

      # Read all with TTL using different consistency levels
      {:ok, results} = Concord.get_all_with_ttl(consistency: :eventual)
      assert Map.has_key?(results, key)
      assert %{value: ^value, ttl: _} = Map.get(results, key)

      {:ok, _} = Concord.get_all_with_ttl(consistency: :leader)
      {:ok, _} = Concord.get_all_with_ttl(consistency: :strong)
    end
  end

  describe "status/1 with consistency levels" do
    test "status/1 with different consistency levels" do
      {:ok, status_eventual} = Concord.status(consistency: :eventual)
      assert Map.has_key?(status_eventual, :cluster)
      assert Map.has_key?(status_eventual, :storage)
      assert Map.has_key?(status_eventual, :node)

      {:ok, status_leader} = Concord.status(consistency: :leader)
      assert is_map(status_leader)

      {:ok, status_strong} = Concord.status(consistency: :strong)
      assert is_map(status_strong)
    end
  end

  describe "telemetry integration" do
    test "consistency level is included in telemetry events" do
      key = "telemetry_test_#{:rand.uniform(10000)}"
      value = "test_value"

      # Set up telemetry handler
      test_pid = self()
      handler_id = :telemetry_test_handler

      :telemetry.attach(
        handler_id,
        [:concord, :api, :get],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, measurements, metadata})
        end,
        nil
      )

      # Put and get with strong consistency
      assert :ok = Concord.put(key, value)
      assert {:ok, ^value} = Concord.get(key, consistency: :strong)

      # Verify telemetry event includes consistency level
      assert_receive {:telemetry_event, %{duration: _}, %{consistency: :strong, result: _}}, 1000

      # Clean up
      :telemetry.detach(handler_id)
    end
  end

  describe "configuration" do
    test "uses configured default_read_consistency" do
      # Default should be :leader from config
      default_consistency = Application.get_env(:concord, :default_read_consistency, :leader)
      assert default_consistency == :leader

      key = "config_test_#{:rand.uniform(10000)}"
      value = "config_value"

      assert :ok = Concord.put(key, value)

      # Without specifying consistency, should use default
      assert {:ok, ^value} = Concord.get(key)
    end

    test "can temporarily change default consistency" do
      old_consistency = Application.get_env(:concord, :default_read_consistency, :leader)

      try do
        # Change to :strong
        Application.put_env(:concord, :default_read_consistency, :strong)

        key = "temp_config_#{:rand.uniform(10000)}"
        value = "temp_value"

        assert :ok = Concord.put(key, value)
        assert {:ok, ^value} = Concord.get(key)
      after
        # Restore original setting
        Application.put_env(:concord, :default_read_consistency, old_consistency)
      end
    end
  end

  describe "edge cases and error handling" do
    test "invalid consistency level defaults to :leader" do
      key = "invalid_consistency_#{:rand.uniform(10000)}"
      value = "test_value"

      assert :ok = Concord.put(key, value)

      # Should fall back to leader query for unknown consistency level
      assert {:ok, ^value} = Concord.get(key, consistency: :invalid_level)
    end

    test "consistency levels work with expired keys" do
      key = "expired_key_#{:rand.uniform(10000)}"
      value = "expired_value"

      # Put with very short TTL
      assert :ok = Concord.put_with_ttl(key, value, 1)

      # Wait for expiration (need to wait longer than 1 second to ensure expiry)
      :timer.sleep(2100)

      # Should return not_found with all consistency levels
      result_eventual = Concord.get(key, consistency: :eventual)
      result_leader = Concord.get(key, consistency: :leader)
      result_strong = Concord.get(key, consistency: :strong)

      # All should be not_found
      assert {:error, :not_found} = result_eventual
      assert {:error, :not_found} = result_leader
      assert {:error, :not_found} = result_strong
    end
  end
end
