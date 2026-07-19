defmodule Concord.StateMachineAdapterTest do
  use ExUnit.Case, async: false

  alias Concord.StateMachine

  test "keeps the compatibility tuple while storing complete service state" do
    state = StateMachine.init(%{})

    {state, result, effects} =
      StateMachine.apply(
        %{index: 9, system_time: 1_000_000},
        {:put, "key", "value", %{ttl: 10}},
        state
      )

    assert %{revision: 1} = result
    assert effects == []

    assert {:concord_kv,
            %{
              store: %{"key" => %{value: "value"}},
              current: %{"key" => %Concord.KV.Record{}},
              command_count: 1
            }} = state
  end

  test "does not emit protocol-specific effects" do
    state =
      {:concord_kv,
       %{
         store: %{},
         current: %{},
         history: %{},
         leases: %{},
         indexes: %{},
         index_entries: %{},
         command_count: 999,
         revision: 0,
         compact_revision: 0,
         next_lease_id: 1
       }}

    {state, :ok, effects} =
      StateMachine.apply(
        %{index: 1_000, system_time: 1_000_000},
        {:put, "key", "value", nil},
        state
      )

    assert {:concord_kv, %{command_count: 1_000}} = state

    assert effects == []
  end

  test "snapshot installation migrates v3 data into adapter materialized views" do
    snapshot =
      {:concord_kv,
       %{
         __snapshot_version__: 3,
         __kv_data__: [{"restored", %{value: "value", expires_at: nil}}],
         __current_data__: [],
         __history_data__: [],
         __lease_data__: [],
         __index_ets__: %{},
         indexes: %{}
       }}

    assert [] = StateMachine.snapshot_installed(snapshot, %{}, StateMachine.init(%{}), nil)

    assert [{"restored", %{value: "value", expires_at: nil}}] =
             :ets.lookup(:concord_store, "restored")
  end
end
