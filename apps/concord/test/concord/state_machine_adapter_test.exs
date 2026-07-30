defmodule Concord.StateMachineAdapterTest do
  use ExUnit.Case, async: false

  alias Concord.{Index, StateMachine}
  alias Concord.StateMachine.Core
  alias Concord.StateMachine.Core.State

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
    test_pid = self()
    handler_id = "snapshot-install-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:concord, :snapshot, :installed],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

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

    assert_receive {:telemetry, [:concord, :snapshot, :installed], %{size: 1}, %{node: _node}}

    assert [{"restored", %{value: "value", expires_at: nil}}] =
             :ets.lookup(:concord_store, "restored")
  end

  test "legacy non-binary index names remain materializable long enough to drop" do
    state = %State{
      indexes: %{atom_name: {:identity}},
      index_entries: %{atom_name: %{}}
    }

    assert :ok = StateMachine.materialize(state)

    assert {{:concord_kv, next_state}, :ok, []} =
             StateMachine.apply_command(
               %{index: 1, system_time: 1_000},
               {:drop_index, :atom_name},
               {:concord_kv, Map.from_struct(state)}
             )

    assert next_state.indexes == %{}
    assert next_state.index_entries == %{}
  end

  test "index materialization uses unnamed tables without interning replicated names" do
    warmup = %State{
      indexes: %{"registry-warmup" => {:identity}},
      index_entries: %{"registry-warmup" => %{}}
    }

    assert :ok = StateMachine.materialize(warmup)
    assert is_reference(Index.index_table_name("registry-warmup"))
    assert :ok = StateMachine.materialize(Core.init())

    suffix = System.unique_integer([:positive])
    names = Enum.map(1..64, &"dynamic-#{suffix}-#{&1}")
    atom_count = :erlang.system_info(:atom_count)

    state = %State{
      indexes: Map.new(names, &{&1, {:identity}}),
      index_entries: Map.new(names, &{&1, %{}})
    }

    assert :ok = StateMachine.materialize(state)

    tables = Enum.map(names, &Index.index_table_name/1)
    assert Enum.all?(tables, &is_reference/1)
    assert Enum.all?(tables, fn table -> :ets.info(table) != :undefined end)
    assert :erlang.system_info(:atom_count) == atom_count

    assert_raise ArgumentError, fn ->
      String.to_existing_atom("concord_index_#{hd(names)}")
    end

    assert :ok = StateMachine.materialize(Core.init())
    assert Enum.all?(tables, fn table -> :ets.info(table) == :undefined end)
  end

  test "legacy invalid UTF-8 index names cannot crash materialization" do
    invalid_name = <<255>>

    state = %State{
      indexes: %{invalid_name => {:identity}},
      index_entries: %{invalid_name => %{}}
    }

    assert :ok = StateMachine.materialize(state)
    table = Index.index_table_name(invalid_name)
    assert is_reference(table)
    assert :ets.info(table) != :undefined
  end
end
