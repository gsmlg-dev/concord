defmodule Concord.BackupTest do
  use ExUnit.Case, async: false
  alias Concord.StateMachine

  describe "Backup V2 format — state machine restore" do
    setup do
      state = StateMachine.init(%{})
      :ets.delete_all_objects(:concord_store)
      {:ok, state: state}
    end

    test "V2 restore_backup restores KV data and indexes", %{state: state} do
      meta = %{index: 1}

      backup_state = %{
        version: 2,
        kv_data: [
          {"key1", %{value: "val1", expires_at: nil}},
          {"key2", %{value: "val2", expires_at: nil}}
        ],
        indexes: %{}
      }

      {_new_state, :ok, _effects} =
        StateMachine.apply_command(meta, {:restore_backup, backup_state}, state)

      # Verify KV data restored
      assert :ets.lookup(:concord_store, "key1") == [{"key1", %{value: "val1", expires_at: nil}}]
      assert :ets.lookup(:concord_store, "key2") == [{"key2", %{value: "val2", expires_at: nil}}]
    end

    test "V2 restore_backup with indexes rebuilds index ETS", %{state: state} do
      meta = %{index: 1}

      # First create an index so we have index state
      {state_with_index, :ok, _} =
        StateMachine.apply_command(meta, {:create_index, "by_email", {:map_get, :email}}, state)

      # Insert a record so the index has data
      {state2, :ok, _} =
        StateMachine.apply_command(
          %{index: 2},
          {:put, "user:1", %{email: "alice@test.com"}, nil},
          state_with_index
        )

      {:concord_kv, current_data} = state2

      # Now simulate a V2 backup restore with index definitions
      backup_state = %{
        version: 2,
        kv_data: [
          {"user:1",
           %{value: :erlang.term_to_binary(%{email: "alice@test.com"}), expires_at: nil}},
          {"user:2", %{value: :erlang.term_to_binary(%{email: "bob@test.com"}), expires_at: nil}}
        ],
        indexes: Map.get(current_data, :indexes, %{})
      }

      {_new_state, :ok, _} =
        StateMachine.apply_command(%{index: 3}, {:restore_backup, backup_state}, state2)

      # Index tables should exist and be rebuilt
      table = Concord.Index.index_table_name("by_email")
      assert :ets.whereis(table) != :undefined
    end

    test "V1 restore_backup still works (backward compat)", %{state: state} do
      meta = %{index: 1}

      # V1 format: bare list of KV tuples
      kv_entries = [
        {"key1", %{value: "v1", expires_at: nil}},
        {"key2", %{value: "v2", expires_at: nil}}
      ]

      {_new_state, :ok, _effects} =
        StateMachine.apply_command(meta, {:restore_backup, kv_entries}, state)

      # Verify KV data restored
      assert :ets.lookup(:concord_store, "key1") == [{"key1", %{value: "v1", expires_at: nil}}]
      assert :ets.lookup(:concord_store, "key2") == [{"key2", %{value: "v2", expires_at: nil}}]
    end

    test "V2 restore_backup replaces existing state completely", %{state: state} do
      meta = %{index: 1}

      # Pre-populate some data
      :ets.insert(:concord_store, {"old_key", %{value: "old_val", expires_at: nil}})

      # Restore with different data
      backup_state = %{
        version: 2,
        kv_data: [{"new_key", %{value: "new_val", expires_at: nil}}],
        indexes: %{}
      }

      {_new_state, :ok, _effects} =
        StateMachine.apply_command(meta, {:restore_backup, backup_state}, state)

      # Old data should be gone
      assert :ets.lookup(:concord_store, "old_key") == []
      # New data should be present
      assert :ets.lookup(:concord_store, "new_key") == [
               {"new_key", %{value: "new_val", expires_at: nil}}
             ]
    end
  end
end
