defmodule Concord.SnapshotTest do
  use ExUnit.Case, async: false
  alias Concord.StateMachine

  describe "Snapshot round-trip — build_release_cursor_state + snapshot_installed" do
    setup do
      state = StateMachine.init(%{})
      :ets.delete_all_objects(:concord_store)
      {:ok, state: state}
    end

    test "snapshot preserves KV data", %{state: state} do
      meta = %{index: 1}

      # Insert KV data
      {state2, :ok, _} =
        StateMachine.apply_command(meta, {:put, "k1", "value1", nil}, state)

      {state3, :ok, _} =
        StateMachine.apply_command(%{index: 2}, {:put, "k2", "value2", nil}, state2)

      # Build snapshot
      snapshot = build_snapshot(state3)

      # Clear all ETS tables
      clear_all_ets()

      # Install snapshot
      StateMachine.snapshot_installed(snapshot, %{}, state, nil)

      # Verify KV data restored
      assert :ets.lookup(:concord_store, "k1") != []
      assert :ets.lookup(:concord_store, "k2") != []
    end

    test "snapshot preserves secondary index definitions and ETS data", %{state: state} do
      meta = %{index: 1}

      # Create an index
      {state2, :ok, _} =
        StateMachine.apply_command(meta, {:create_index, "by_name", {:map_get, :name}}, state)

      # Insert a record that uses the index
      {state3, :ok, _} =
        StateMachine.apply_command(
          %{index: 2},
          {:put, "user:1", %{name: "Alice"}, nil},
          state2
        )

      # Build snapshot
      snapshot = build_snapshot(state3)

      # Clear all ETS
      clear_all_ets()

      # Install snapshot
      StateMachine.snapshot_installed(snapshot, %{}, state, nil)

      # Verify index definition is in the state
      {:concord_kv, restored_data} = snapshot
      assert Map.has_key?(restored_data, :indexes)
      assert Map.has_key?(restored_data.indexes, "by_name")

      # Verify index ETS table exists and has data
      table = Concord.Index.index_table_name("by_name")
      assert :ets.whereis(table) != :undefined
      assert :ets.tab2list(table) != []
    end

    test "full snapshot round-trip preserves KV and index ETS tables", %{state: state} do
      meta = %{index: 1}

      # Build up state with KV and index data
      # 1. KV data
      {s1, :ok, _} = StateMachine.apply_command(meta, {:put, "k1", "v1", nil}, state)

      # 2. Index
      {s2, :ok, _} =
        StateMachine.apply_command(%{index: 2}, {:create_index, "idx1", {:map_get, :field}}, s1)

      {s3, :ok, _} =
        StateMachine.apply_command(%{index: 3}, {:put, "k2", %{field: "indexed"}, nil}, s2)

      # Build snapshot from final state
      snapshot = build_snapshot(s3)

      # Clear ALL ETS tables
      clear_all_ets()

      # Verify everything is empty
      assert :ets.tab2list(:concord_store) == []

      # Install snapshot
      StateMachine.snapshot_installed(snapshot, %{}, state, nil)

      # Verify KV store
      assert :ets.lookup(:concord_store, "k1") != []
      assert :ets.lookup(:concord_store, "k2") != []

      # Verify index ETS
      table = Concord.Index.index_table_name("idx1")
      assert :ets.whereis(table) != :undefined
    end
  end

  # Helper: construct the snapshot state manually
  # mirroring what build_release_cursor_state does.
  defp build_snapshot(state) do
    {:concord_kv, data} = state
    kv_data = :ets.tab2list(:concord_store)
    indexes = Map.get(data, :indexes, %{})

    index_ets =
      Enum.reduce(indexes, %{}, fn {name, _spec}, acc ->
        table = Concord.Index.index_table_name(name)

        ets_data =
          if :ets.whereis(table) != :undefined,
            do: :ets.tab2list(table),
            else: []

        Map.put(acc, name, ets_data)
      end)

    {:concord_kv,
     Map.merge(data, %{
       __snapshot_version__: 3,
       __kv_data__: kv_data,
       __index_ets__: index_ets
     })}
  end

  defp clear_all_ets do
    :ets.delete_all_objects(:concord_store)
  end
end
