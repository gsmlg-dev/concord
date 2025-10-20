defmodule Concord.TTLTest do
  use ExUnit.Case, async: false
  alias Concord.{StateMachine, TTL}

  describe "Concord.TTL" do
    test "calculate_expiration/1 returns correct timestamp" do
      ttl_seconds = 3600
      expected_expiration = System.system_time(:second) + ttl_seconds
      result = TTL.calculate_expiration(ttl_seconds)

      assert abs(result - expected_expiration) <= 1  # Allow 1 second variance
    end

    test "calculate_expiration/1 handles nil and infinity" do
      assert TTL.calculate_expiration(nil) == nil
      assert TTL.calculate_expiration(:infinity) == nil
    end

    test "validate_ttl/1 validates TTL values" do
      assert TTL.validate_ttl(nil) == :ok
      assert TTL.validate_ttl(:infinity) == :ok
      assert TTL.validate_ttl(3600) == :ok
      assert TTL.validate_ttl(1) == :ok

      assert TTL.validate_ttl(0) == {:error, :invalid_ttl}
      assert TTL.validate_ttl(-1) == {:error, :invalid_ttl}
      assert TTL.validate_ttl("invalid") == {:error, :invalid_ttl}
      assert TTL.validate_ttl(:invalid) == {:error, :invalid_ttl}
    end

    test "config/1 returns current configuration" do
      {:ok, _} = start_supervised({TTL, [cleanup_interval: 60, default_ttl: 7200]})

      config = TTL.config()
      assert config.cleanup_interval == 60
      assert config.default_ttl == 7200
    end

    test "update_cleanup_interval/1 updates the interval" do
      {:ok, _} = start_supervised({TTL, [cleanup_interval: 60]})

      :ok = TTL.update_cleanup_interval(120)
      config = TTL.config()
      assert config.cleanup_interval == 120
    end
  end

  describe "StateMachine TTL operations" do
    setup do
      # Start a fresh state machine for each test
      state = StateMachine.init(%{})
      {:ok, state: state}
    end

    test "apply/3 handles put with TTL", %{state: state} do
      meta = %{index: 1}
      expires_at = System.system_time(:second) + 3600

      {new_state, result, _effects} = StateMachine.apply(meta, {:put, "test_key", "test_value", expires_at}, state)

      assert result == :ok
      assert new_state == state
    end

    test "apply/3 handles backward compatibility put without TTL", %{state: state} do
      meta = %{index: 1}

      {new_state, result, _effects} = StateMachine.apply(meta, {:put, "test_key", "test_value"}, state)

      assert result == :ok
      assert new_state == state
    end

    test "apply/3 handles touch operation", %{state: state} do
      meta = %{index: 1}
      expires_at = System.system_time(:second) + 3600

      # First, put a key with TTL
      StateMachine.apply(meta, {:put, "test_key", "test_value", expires_at}, state)

      # Then touch it to extend TTL
      {new_state, result, _effects} = StateMachine.apply(meta, {:touch, "test_key", 1800}, state)

      assert result == :ok
      assert new_state == state
    end

    test "apply/3 handles touch on non-existent key", %{state: state} do
      meta = %{index: 1}

      {new_state, result, _effects} = StateMachine.apply(meta, {:touch, "non_existent", 1800}, state)

      assert result == {:error, :not_found}
      assert new_state == state
    end

    test "query/2 handles get with TTL filtering", %{state: state} do
      expires_at = System.system_time(:second) + 3600
      future_time = expires_at

      # Insert a key with future expiration directly into ETS
      :ets.insert(:concord_store, {"valid_key", %{value: "valid_value", expires_at: future_time}})
      :ets.insert(:concord_store, {"expired_key", %{value: "expired_value", expires_at: System.system_time(:second) - 1}})
      :ets.insert(:concord_store, {"old_format_key", "old_value"})  # Backward compatibility

      # Should find valid key
      assert StateMachine.query({:get, "valid_key"}, state) == {:ok, "valid_value"}

      # Should not find expired key
      assert StateMachine.query({:get, "expired_key"}, state) == {:error, :not_found}

      # Should find old format key
      assert StateMachine.query({:get, "old_format_key"}, state) == {:ok, "old_value"}
    end

    test "query/2 handles get_with_ttl", %{state: state} do
      expires_at = System.system_time(:second) + 3600

      :ets.insert(:concord_store, {"test_key", %{value: "test_value", expires_at: expires_at}})
      :ets.insert(:concord_store, {"old_key", "old_value"})

      # Should return value and TTL for new format
      {:ok, {value, ttl}} = StateMachine.query({:get_with_ttl, "test_key"}, state)
      assert value == "test_value"
      assert is_integer(ttl) and ttl > 0

      # Should return value and nil TTL for old format
      {:ok, {old_value, old_ttl}} = StateMachine.query({:get_with_ttl, "old_key"}, state)
      assert old_value == "old_value"
      assert old_ttl == nil
    end

    test "query/2 handles ttl query", %{state: state} do
      expires_at = System.system_time(:second) + 3600

      :ets.insert(:concord_store, {"test_key", %{value: "test_value", expires_at: expires_at}})
      :ets.insert(:concord_store, {"old_key", "old_value"})

      # Should return TTL for new format
      {:ok, ttl} = StateMachine.query({:ttl, "test_key"}, state)
      assert is_integer(ttl) and ttl > 0

      # Should return nil for old format
      {:ok, old_ttl} = StateMachine.query({:ttl, "old_key"}, state)
      assert old_ttl == nil
    end

    test "query/2 handles get_all with TTL filtering", %{state: state} do
      expires_at = System.system_time(:second) + 3600

      :ets.insert(:concord_store, {"valid_key", %{value: "valid_value", expires_at: expires_at}})
      :ets.insert(:concord_store, {"expired_key", %{value: "expired_value", expires_at: System.system_time(:second) - 1}})
      :ets.insert(:concord_store, {"old_key", "old_value"})

      {:ok, all_data} = StateMachine.query(:get_all, state)

      # Should include valid and old keys, but not expired
      assert Map.has_key?(all_data, "valid_key")
      assert Map.has_key?(all_data, "old_key")
      assert not Map.has_key?(all_data, "expired_key")
      assert all_data["valid_key"] == "valid_value"
      assert all_data["old_key"] == "old_value"
    end

    test "query/2 handles get_all_with_ttl", %{state: state} do
      expires_at = System.system_time(:second) + 3600

      :ets.insert(:concord_store, {"test_key", %{value: "test_value", expires_at: expires_at}})
      :ets.insert(:concord_store, {"old_key", "old_value"})

      {:ok, all_data} = StateMachine.query(:get_all_with_ttl, state)

      # Should include TTL information
      assert Map.has_key?(all_data, "test_key")
      assert Map.has_key?(all_data, "old_key")

      assert %{value: "test_value", ttl: ttl} = all_data["test_key"]
      assert is_integer(ttl) and ttl > 0
      assert all_data["old_key"] == %{value: "old_value", ttl: nil}
    end

    test "apply/3 handles cleanup_expired", %{state: state} do
      meta = %{index: 1}
      current_time = System.system_time(:second)

      # Insert test data
      :ets.insert(:concord_store, {"valid_key", %{value: "valid", expires_at: current_time + 3600}})
      :ets.insert(:concord_store, {"expired_key1", %{value: "expired1", expires_at: current_time - 100}})
      :ets.insert(:concord_store, {"expired_key2", %{value: "expired2", expires_at: current_time - 200}})
      :ets.insert(:concord_store, {"old_key", "old_value"})

      # Run cleanup
      {_new_state, result, _effects} = StateMachine.apply(meta, :cleanup_expired, state)

      assert {:ok, deleted_count} = result
      assert deleted_count == 2

      # Verify expired keys are gone
      assert :ets.lookup(:concord_store, "expired_key1") == []
      assert :ets.lookup(:concord_store, "expired_key2") == []

      # Verify valid and old keys remain
      assert :ets.lookup(:concord_store, "valid_key") != []
      assert :ets.lookup(:concord_store, "old_key") != []
    end
  end
end