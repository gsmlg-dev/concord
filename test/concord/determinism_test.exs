defmodule Concord.DeterminismTest do
  use ExUnit.Case, async: false
  alias Concord.StateMachine

  @moduledoc """
  Tests that the state machine produces identical output when given identical
  input, regardless of how many times it is replayed. This is the core
  correctness property required by Raft: `apply/3` must be a pure function
  of (meta, command, state).
  """

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  # Fields to compare between two state data maps.
  # command_count is excluded because it is incremented by the apply/3
  # wrapper, not by apply_command/3 which these tests call directly.
  @comparable_fields [:indexes]

  defp clear_ets do
    :ets.delete_all_objects(:concord_store)

    # Clear any index tables that may exist
    for name <- ["idx1"] do
      table = Concord.Index.index_table_name(name)
      if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    end
  end

  defp assert_states_equal({:concord_kv, data_a}, {:concord_kv, data_b}) do
    for field <- @comparable_fields do
      val_a = Map.get(data_a, field)
      val_b = Map.get(data_b, field)

      assert val_a == val_b,
             "State mismatch on field #{inspect(field)}:\n" <>
               "  machine A: #{inspect(val_a)}\n" <>
               "  machine B: #{inspect(val_b)}"
    end
  end

  # The canonical command sequence used across multiple tests.
  # Returns a list of {command, meta} tuples.
  defp canonical_commands do
    ttl = System.system_time(:millisecond) + 3_600_000

    [
      {{:put, "k1", "value1", nil}, %{index: 1, system_time: 1_000_000}},
      {{:put, "k2", "value2", ttl}, %{index: 2, system_time: 1_000_001}},
      {{:delete, "k1"}, %{index: 3, system_time: 1_000_002}},
      {{:create_index, "idx1", {:map_get, :field}}, %{index: 4, system_time: 1_000_003}},
      {{:put, "k3", %{field: "indexed_val"}, nil}, %{index: 5, system_time: 1_000_004}}
    ]
  end

  # Replay a list of {command, meta} tuples on a state, returning the final state.
  defp replay(commands, initial_state) do
    Enum.reduce(commands, initial_state, fn {command, meta}, state ->
      {new_state, _result, _effects} = StateMachine.apply_command(meta, command, state)
      new_state
    end)
  end

  # ──────────────────────────────────────────────
  # Tests
  # ──────────────────────────────────────────────

  describe "deterministic replay" do
    setup do
      state = StateMachine.init(%{})
      clear_ets()
      {:ok, state: state}
    end

    test "two independent replays of the same commands produce identical state", %{state: state} do
      commands = canonical_commands()

      # --- Machine A ---
      state_a = replay(commands, state)
      ets_a = :ets.tab2list(:concord_store) |> Enum.sort()

      # Clear ETS to simulate a second, independent machine
      clear_ets()

      # --- Machine B ---
      state_b = replay(commands, state)
      ets_b = :ets.tab2list(:concord_store) |> Enum.sort()

      # Assert Raft state is identical
      assert_states_equal(state_a, state_b)

      # Assert ETS materialized view is identical
      assert ets_a == ets_b
    end

    test "meta_time uses system_time from meta for TTL, ensuring deterministic expiration",
         %{state: state} do
      expires_at = 2_000

      meta_put = %{index: 1, system_time: 1_000_000}
      meta_cas = %{index: 2, system_time: 1_500_000}

      {state_after_put, :ok, _} =
        StateMachine.apply_command(meta_put, {:put, "ttl_key", "original", expires_at}, state)

      {state_a, result_a, _} =
        StateMachine.apply_command(
          meta_cas,
          {:put_if, "ttl_key", "updated", nil, "original"},
          state_after_put
        )

      assert result_a == :ok

      # Clear and replay identically
      clear_ets()
      _ = StateMachine.init(%{})

      {state_after_put2, :ok, _} =
        StateMachine.apply_command(meta_put, {:put, "ttl_key", "original", expires_at}, state)

      {state_b, result_b, _} =
        StateMachine.apply_command(
          meta_cas,
          {:put_if, "ttl_key", "updated", nil, "original"},
          state_after_put2
        )

      assert result_b == :ok
      assert_states_equal(state_a, state_b)

      # Now verify that a LATER system_time causes the key to be seen as expired
      clear_ets()
      _ = StateMachine.init(%{})

      {state_after_put3, :ok, _} =
        StateMachine.apply_command(meta_put, {:put, "ttl_key", "original", expires_at}, state)

      meta_expired = %{index: 2, system_time: 3_000_000}

      {_state_c, result_c, _} =
        StateMachine.apply_command(
          meta_expired,
          {:put_if, "ttl_key", "updated", nil, "original"},
          state_after_put3
        )

      assert result_c == {:error, :not_found}
    end

    test "results from each command are identical across replays", %{state: state} do
      commands = canonical_commands()

      # Collect results from Machine A
      {_state_a, results_a} =
        Enum.reduce(commands, {state, []}, fn {command, meta}, {s, results} ->
          {new_s, result, _effects} = StateMachine.apply_command(meta, command, s)
          {new_s, results ++ [result]}
        end)

      clear_ets()

      # Collect results from Machine B
      {_state_b, results_b} =
        Enum.reduce(commands, {state, []}, fn {command, meta}, {s, results} ->
          {new_s, result, _effects} = StateMachine.apply_command(meta, command, s)
          {new_s, results ++ [result]}
        end)

      assert results_a == results_b
    end

    test "individual state fields are correct after canonical replay", %{state: state} do
      commands = canonical_commands()
      {:concord_kv, data} = replay(commands, state)

      # k1 was put then deleted — should not be in ETS
      assert :ets.lookup(:concord_store, "k1") == []

      # k2 was put with TTL — should be present with expiration
      [{_key, stored}] = :ets.lookup(:concord_store, "k2")
      assert %{value: "value2", expires_at: expires_at} = stored
      assert is_integer(expires_at)

      # k3 was put — should be present
      assert :ets.lookup(:concord_store, "k3") != []

      # Index "idx1" should be in state
      assert Map.has_key?(data.indexes, "idx1")
      assert data.indexes["idx1"] == {:map_get, :field}
    end
  end
end
