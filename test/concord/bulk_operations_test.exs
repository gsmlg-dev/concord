defmodule Concord.BulkOperationsTest do
  use ExUnit.Case, async: false
  alias Concord.StateMachine

  # Helper function to match the private format_value function in StateMachine
  defp format_value(value, expires_at) do
    %{
      value: value,
      expires_at: expires_at
    }
  end

  describe "StateMachine Bulk Operations" do
    setup do
      state = StateMachine.init(%{})
      {:ok, state: state}
    end

    test "apply_command handles put_many with valid operations", %{state: state} do
      meta = %{index: 1}

      operations = [
        {"key1", "value1", nil},
        {"key2", "value2", nil},
        {"key3", "value3", System.system_time(:second) + 3600}
      ]

      {new_state, result, _effects} =
        StateMachine.apply_command(meta, {:put_many, operations}, state)

      assert result == {:ok, [{"key1", :ok}, {"key2", :ok}, {"key3", :ok}]}
      assert new_state == state

      # Verify data was stored
      assert :ets.lookup(:concord_store, "key1") != []
      assert :ets.lookup(:concord_store, "key2") != []
      assert :ets.lookup(:concord_store, "key3") != []
    end

    test "apply_command rejects put_many with invalid operations", %{state: state} do
      meta = %{index: 1}

      operations = [
        {"key1", "value1", nil},
        # Invalid empty key
        {"", "value2", nil}
      ]

      {new_state, result, _effects} =
        StateMachine.apply_command(meta, {:put_many, operations}, state)

      assert result == {:error, :invalid_key}
      assert new_state == state

      # Verify no data was stored
      assert :ets.lookup(:concord_store, "key1") == []
    end

    test "apply_command handles put_many with batch size limit", %{state: state} do
      meta = %{index: 1}
      # Create batch with 501 operations (over the 500 limit)
      operations = List.duplicate({"key", "value", nil}, 501)

      {new_state, result, _effects} =
        StateMachine.apply_command(meta, {:put_many, operations}, state)

      assert result == {:error, :batch_too_large}
      assert new_state == state
    end

    test "apply_command handles get_many", %{state: state} do
      meta = %{index: 1}

      # Setup some data
      :ets.insert(:concord_store, {"key1", %{value: "value1", expires_at: nil}})

      :ets.insert(
        :concord_store,
        {"key2", %{value: "value2", expires_at: System.system_time(:second) + 3600}}
      )

      # Expired
      :ets.insert(
        :concord_store,
        {"key3", %{value: "value3", expires_at: System.system_time(:second) - 1}}
      )

      {new_state, result, _effects} =
        StateMachine.apply_command(meta, {:get_many, ["key1", "key2", "key3", "key4"]}, state)

      assert result ==
               {:ok,
                [
                  {"key1", {:ok, "value1"}},
                  {"key2", {:ok, "value2"}},
                  {"key3", {:error, :not_found}},
                  {"key4", {:error, :not_found}}
                ]}

      assert new_state == state
    end

    test "apply_command handles delete_many", %{state: state} do
      meta = %{index: 1}

      # Setup some data - use the format_value function for consistency
      :ets.insert(:concord_store, {"key1", format_value("value1", nil)})
      :ets.insert(:concord_store, {"key2", format_value("value2", nil)})
      :ets.insert(:concord_store, {"key3", format_value("value3", nil)})

      {new_state, result, _effects} =
        StateMachine.apply_command(meta, {:delete_many, ["key1", "key3"]}, state)

      assert result == {:ok, [{"key1", :ok}, {"key3", :ok}]}
      assert new_state == state

      # Verify keys were deleted
      assert :ets.lookup(:concord_store, "key1") == []
      assert :ets.lookup(:concord_store, "key3") == []
      # Should still exist
      assert :ets.lookup(:concord_store, "key2") != []
    end

    test "apply_command handles touch_many", %{state: state} do
      meta = %{index: 1}
      current_time = System.system_time(:second)

      # Setup some data with existing TTL
      :ets.insert(:concord_store, {"key1", format_value("value1", current_time + 100)})
      :ets.insert(:concord_store, {"key2", format_value("value2", current_time + 200)})
      # No TTL
      :ets.insert(:concord_store, {"key3", format_value("value3", nil)})

      {new_state, result, _effects} =
        StateMachine.apply_command(meta, {:touch_many, [{"key1", 3600}, {"key2", 7200}]}, state)

      assert result == {:ok, [{"key1", :ok}, {"key2", :ok}]}
      assert new_state == state

      # Verify TTLs were extended - check they're greater than original time
      [{_, updated1}] = :ets.lookup(:concord_store, "key1")
      [{_, updated2}] = :ets.lookup(:concord_store, "key2")
      # Extended beyond original
      assert updated1.expires_at > current_time + 100
      # Extended beyond original
      assert updated2.expires_at > current_time + 200
    end

    test "apply_command handles touch_many with non-existent keys", %{state: state} do
      meta = %{index: 1}

      {new_state, result, _effects} =
        StateMachine.apply_command(meta, {:touch_many, [{"nonexistent", 3600}]}, state)

      assert result == {:ok, [{"nonexistent", {:error, :not_found}}]}
      assert new_state == state
    end

    test "query handles get_many", %{state: state} do
      # Setup some data
      :ets.insert(:concord_store, {"key1", %{value: "value1", expires_at: nil}})

      :ets.insert(
        :concord_store,
        {"key2", %{value: "value2", expires_at: System.system_time(:second) + 3600}}
      )

      # Expired
      :ets.insert(
        :concord_store,
        {"key3", %{value: "value3", expires_at: System.system_time(:second) - 1}}
      )

      result = StateMachine.query({:get_many, ["key1", "key2", "key3", "key4"]}, state)

      assert result ==
               {:ok,
                %{
                  "key1" => {:ok, "value1"},
                  "key2" => {:ok, "value2"},
                  "key3" => {:error, :not_found},
                  "key4" => {:error, :not_found}
                }}
    end
  end
end
