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

      # Clean the ETS table to ensure test isolation
      :ets.delete_all_objects(:concord_store)

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
      now_ms = System.system_time(:millisecond)
      now_s = div(now_ms, 1000)
      meta = %{index: 1, system_time: now_ms}

      # Setup some data
      :ets.insert(:concord_store, {"key1", %{value: "value1", expires_at: nil}})

      :ets.insert(
        :concord_store,
        {"key2", %{value: "value2", expires_at: now_s + 3600}}
      )

      # Expired
      :ets.insert(
        :concord_store,
        {"key3", %{value: "value3", expires_at: now_s - 1}}
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
      now_ms = System.system_time(:millisecond)
      now_s = div(now_ms, 1000)
      meta = %{index: 1, system_time: now_ms}

      # Setup some data with existing TTL
      :ets.insert(:concord_store, {"key1", format_value("value1", now_s + 100)})
      :ets.insert(:concord_store, {"key2", format_value("value2", now_s + 200)})
      # No TTL
      :ets.insert(:concord_store, {"key3", format_value("value3", nil)})

      {new_state, result, _effects} =
        StateMachine.apply_command(meta, {:touch_many, [{"key1", 3600}, {"key2", 7200}]}, state)

      assert result == {:ok, [{"key1", :ok}, {"key2", :ok}]}
      assert new_state == state

      # Verify TTLs were extended — now_s + additional_ttl
      [{_, updated1}] = :ets.lookup(:concord_store, "key1")
      [{_, updated2}] = :ets.lookup(:concord_store, "key2")
      assert updated1.expires_at == now_s + 3600
      assert updated2.expires_at == now_s + 7200
    end

    test "apply_command handles touch_many with non-existent keys", %{state: state} do
      meta = %{index: 1}

      {new_state, result, _effects} =
        StateMachine.apply_command(meta, {:touch_many, [{"nonexistent", 3600}]}, state)

      assert result == {:ok, [{"nonexistent", {:error, :not_found}}]}
      assert new_state == state
    end

    test "put_many updates secondary indexes for all entries", %{state: state} do
      meta = %{index: 1}

      # Create an index on the :email field
      {state_with_index, :ok, _} =
        StateMachine.apply_command(meta, {:create_index, "by_email", {:map_get, :email}}, state)

      # Batch insert records with email fields
      operations = [
        {"user:1", %{email: "alice@test.com", name: "Alice"}, nil},
        {"user:2", %{email: "bob@test.com", name: "Bob"}, nil},
        {"user:3", %{email: "carol@test.com", name: "Carol"}, nil}
      ]

      {_new_state, {:ok, results}, _} =
        StateMachine.apply_command(%{index: 2}, {:put_many, operations}, state_with_index)

      assert length(results) == 3
      assert Enum.all?(results, fn {_k, status} -> status == :ok end)

      # Verify all entries are discoverable via the secondary index
      table = Concord.Index.index_table_name("by_email")
      assert :ets.lookup(table, "alice@test.com") == [{"alice@test.com", ["user:1"]}]
      assert :ets.lookup(table, "bob@test.com") == [{"bob@test.com", ["user:2"]}]
      assert :ets.lookup(table, "carol@test.com") == [{"carol@test.com", ["user:3"]}]
    end

    test "put_many overwrites update index entries correctly", %{state: state} do
      meta = %{index: 1}

      # Create index and insert initial data
      {state_with_index, :ok, _} =
        StateMachine.apply_command(meta, {:create_index, "by_email", {:map_get, :email}}, state)

      # Insert initial record
      {state2, :ok, _} =
        StateMachine.apply_command(
          %{index: 2},
          {:put, "user:1", %{email: "old@test.com", name: "Alice"}, nil},
          state_with_index
        )

      table = Concord.Index.index_table_name("by_email")
      assert :ets.lookup(table, "old@test.com") == [{"old@test.com", ["user:1"]}]

      # Overwrite via put_many with new email
      operations = [{"user:1", %{email: "new@test.com", name: "Alice Updated"}, nil}]

      {_new_state, {:ok, _results}, _} =
        StateMachine.apply_command(%{index: 3}, {:put_many, operations}, state2)

      # Old index entry removed, new one present
      assert :ets.lookup(table, "old@test.com") == []
      assert :ets.lookup(table, "new@test.com") == [{"new@test.com", ["user:1"]}]
    end

    test "put_many with entries missing indexed field skips gracefully", %{state: state} do
      meta = %{index: 1}

      {state_with_index, :ok, _} =
        StateMachine.apply_command(meta, {:create_index, "by_email", {:map_get, :email}}, state)

      # Mix of records with and without the indexed field
      operations = [
        {"user:1", %{email: "alice@test.com", name: "Alice"}, nil},
        {"user:2", %{name: "Bob (no email)"}, nil},
        {"user:3", %{email: "carol@test.com", name: "Carol"}, nil}
      ]

      {_new_state, {:ok, results}, _} =
        StateMachine.apply_command(%{index: 2}, {:put_many, operations}, state_with_index)

      # All inserts succeed
      assert length(results) == 3
      assert Enum.all?(results, fn {_k, status} -> status == :ok end)

      # Only records with email appear in the index
      table = Concord.Index.index_table_name("by_email")
      assert :ets.lookup(table, "alice@test.com") == [{"alice@test.com", ["user:1"]}]
      assert :ets.lookup(table, "carol@test.com") == [{"carol@test.com", ["user:3"]}]
      # No entry for Bob
      assert :ets.tab2list(table) |> Enum.filter(fn {_k, v} -> v == "user:2" end) == []
    end

    test "put_many with empty list is a no-op", %{state: state} do
      meta = %{index: 1}

      {new_state, result, _effects} =
        StateMachine.apply_command(meta, {:put_many, []}, state)

      assert result == {:ok, []}
      assert new_state == state
    end

    test "put_many with duplicate keys keeps last occurrence in index", %{state: state} do
      meta = %{index: 1}

      {state_with_index, :ok, _} =
        StateMachine.apply_command(meta, {:create_index, "by_email", {:map_get, :email}}, state)

      # Same key appears twice with different email values
      operations = [
        {"user:1", %{email: "first@test.com", name: "First"}, nil},
        {"user:1", %{email: "second@test.com", name: "Second"}, nil}
      ]

      {_new_state, {:ok, _results}, _} =
        StateMachine.apply_command(%{index: 2}, {:put_many, operations}, state_with_index)

      table = Concord.Index.index_table_name("by_email")
      # First email should be removed, second should be present
      assert :ets.lookup(table, "first@test.com") == []
      assert :ets.lookup(table, "second@test.com") == [{"second@test.com", ["user:1"]}]
    end

    test "put_if (5-tuple CAS) updates secondary indexes", %{state: state} do
      meta = %{index: 1}

      # Create index
      {state_with_index, :ok, _} =
        StateMachine.apply_command(meta, {:create_index, "by_email", {:map_get, :email}}, state)

      # Insert initial record
      {state2, :ok, _} =
        StateMachine.apply_command(
          %{index: 2},
          {:put, "user:1", %{email: "old@test.com"}, nil},
          state_with_index
        )

      table = Concord.Index.index_table_name("by_email")
      assert :ets.lookup(table, "old@test.com") == [{"old@test.com", ["user:1"]}]

      # Use put_if CAS to update — expected matches the current value
      {_state3, :ok, _} =
        StateMachine.apply_command(
          %{index: 3},
          {:put_if, "user:1", %{email: "new@test.com"}, nil, %{email: "old@test.com"}},
          state2
        )

      # Old index entry removed, new one present
      assert :ets.lookup(table, "old@test.com") == []
      assert :ets.lookup(table, "new@test.com") == [{"new@test.com", ["user:1"]}]
    end

    test "delete_if removes entries from secondary indexes", %{state: state} do
      meta = %{index: 1}

      # Create index
      {state_with_index, :ok, _} =
        StateMachine.apply_command(meta, {:create_index, "by_email", {:map_get, :email}}, state)

      # Insert a record
      {state2, :ok, _} =
        StateMachine.apply_command(
          %{index: 2},
          {:put, "user:1", %{email: "alice@test.com"}, nil},
          state_with_index
        )

      table = Concord.Index.index_table_name("by_email")
      assert :ets.lookup(table, "alice@test.com") == [{"alice@test.com", ["user:1"]}]

      # delete_if with CAS expected value matching the current value
      {_state3, :ok, _} =
        StateMachine.apply_command(
          %{index: 3},
          {:delete_if, "user:1", %{email: "alice@test.com"}, nil},
          state2
        )

      # Key deleted and index entry removed
      assert :ets.lookup(:concord_store, "user:1") == []
      assert :ets.lookup(table, "alice@test.com") == []
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
