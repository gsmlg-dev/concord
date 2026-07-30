defmodule Concord.CommandSafetyTest do
  use ExUnit.Case, async: false

  alias Concord.CommandEnvelope
  alias Concord.CommandSchema
  alias Concord.Engine.VSR.StateMachine, as: VSRStateMachine
  alias Concord.StateMachine.Core
  alias Concord.StateMachine.Core.Context
  alias ViewstampedReplication.ApplyMetadata

  defp metadata(op_number) do
    %ApplyMetadata{
      group_id: :command_safety,
      view_number: 0,
      op_number: op_number,
      client_id: :client,
      request_number: op_number
    }
  end

  test "current command envelopes apply deterministic commands" do
    state = Core.init()
    operation = CommandEnvelope.wrap(1_000, {:put, "key", "value", %{}})

    assert {:concord_command, 1, 1_000, {:put, "key", "value", %{}}} = operation

    assert {%{revision: 1}, next_state} =
             VSRStateMachine.apply(metadata(1), operation, state)

    assert Core.query({:get, "key"}, next_state, %{timestamp_ms: 1_000}) ==
             {:ok, "value"}
  end

  test "command emission supports a two-phase legacy-to-versioned rollout" do
    command = {:put, "key", "value", %{}}

    assert {:concord_command, 1_000, ^command} = CommandEnvelope.wrap(1_000, command, 0)
    assert {:concord_command, 1, 1_000, ^command} = CommandEnvelope.wrap(1_000, command, 1)
    assert CommandEnvelope.supported_version?(0)
    assert CommandEnvelope.supported_version?(1)
    refute CommandEnvelope.supported_version?(2)

    assert {:ok, 0, 1_000, ^command} =
             1_000 |> CommandEnvelope.wrap(command, 0) |> CommandEnvelope.unwrap()

    assert {:ok, 1, 1_000, ^command} =
             1_000 |> CommandEnvelope.wrap(command, 1) |> CommandEnvelope.unwrap()
  end

  test "legacy unversioned command envelopes remain replayable" do
    state = Core.init()
    legacy_operation = {:concord_command, 1_000, {:put, "legacy", "value", %{}}}

    assert {%{revision: 1}, next_state} =
             VSRStateMachine.apply(metadata(1), legacy_operation, state)

    assert Core.query({:get, "legacy"}, next_state, %{timestamp_ms: 1_000}) ==
             {:ok, "value"}
  end

  test "legacy envelopes preserve old extractor semantics while new emission rejects them" do
    state = Core.init()
    extractor = fn value -> Map.get(value, :email) end
    legacy_create = {:concord_command, 1_000, {:create_index, "legacy", extractor}}

    assert {:ok, indexed_state} = VSRStateMachine.apply(metadata(1), legacy_create, state)
    assert is_function(indexed_state.indexes["legacy"], 1)

    legacy_put = {:concord_command, 1_001, {:put, "user", %{email: "legacy@example.test"}, nil}}
    assert {:ok, indexed_state} = VSRStateMachine.apply(metadata(2), legacy_put, indexed_state)

    assert Core.query(
             {:index_lookup, "legacy", "legacy@example.test"},
             indexed_state,
             %{timestamp_ms: 1_001}
           ) == {:ok, ["user"]}

    assert {:error, :unsupported_command} =
             CommandSchema.validate_emission({:future_command, :payload})
  end

  test "version zero preserves arbitrary index names and unknown-command no-op semantics" do
    state = Core.init()
    context = Context.new!(op_number: 1, timestamp_ms: 1_000)

    assert {:ok, indexed_state} =
             Core.apply_legacy(context, {:create_index, :atom_name, {:identity}}, state)

    assert indexed_state.indexes == %{atom_name: {:identity}}
    assert indexed_state.command_count == 1

    assert {:ok, %{legacy_indexes: [:atom_name]}} =
             Core.query(:stats, indexed_state, context)

    unknown = {:command_added_after_the_legacy_release, %{payload: true}}
    operation = {:concord_command, 1_001, unknown}

    assert {:ok, replayed_state} =
             VSRStateMachine.apply(metadata(2), operation, state)

    assert replayed_state.store == state.store
    assert replayed_state.command_count == 1
    assert :ok = CommandSchema.validate(0, unknown)
  end

  test "version one rejects every malformed command before applying it" do
    state = Core.init()

    malformed_commands = [
      {:grant_lease, :bad_ttl, %{}},
      {:put, "key", "value", %{ttl: :bad}},
      {:touch, "key", :bad_ttl},
      {:txn, %{compare: :bad}},
      {:txn, %{success: [{:put, "key", "value", :bad}]}},
      {:restore_backup, [1]},
      {:restore_backup, %{version: 2, kv_data: :malformed, indexes: %{}}}
    ]

    Enum.each(malformed_commands, fn command ->
      assert {:error, :unsupported_command} = CommandSchema.validate(1, command)

      assert {{:error, :unsupported_command}, ^state} =
               VSRStateMachine.apply(metadata(1), CommandEnvelope.wrap(1_000, command), state)

      assert {{:error, :unsupported_command}, ^state} =
               Core.apply(Context.new!(op_number: 1, timestamp_ms: 1_000), command, state)
    end)
  end

  test "infinite TTL is normalized to no expiry in current commands and transactions" do
    context = Context.new!(op_number: 1, timestamp_ms: 1_000)

    assert {%{revision: 1}, state} =
             Core.apply(context, {:put, "direct", "value", %{ttl: :infinity}}, Core.init())

    assert state.current["direct"].expires_at == nil

    transaction = %{
      success: [{:put, "txn", "value", %{ttl: :infinity}}]
    }

    assert {{:ok, %Concord.Txn.Result{}}, state} =
             Core.apply(context, {:txn, transaction}, state)

    assert state.current["txn"].expires_at == nil
  end

  test "current backup restore rejects malformed data and rebuilds represented state" do
    context = Context.new!(op_number: 1, timestamp_ms: 1_000)
    state = Core.init()
    {_, state} = Core.apply(context, {:grant_lease, 60, %{}}, state)
    {_, state} = Core.apply(context, {:put, "old", "value", %{lease: 1}}, state)

    malformed = {:restore_backup, %{version: 2, kv_data: :malformed, indexes: %{}}}
    assert {{:error, :unsupported_command}, ^state} = Core.apply(context, malformed, state)

    backup = %{
      version: 2,
      kv_data: [{"new", %{value: "restored", expires_at: nil}}],
      indexes: %{"by-value" => {:identity}}
    }

    assert {:ok, restored} = Core.apply_command(context, {:restore_backup, backup}, state)
    assert restored.store == %{"new" => %{value: "restored", expires_at: nil}}

    assert %{"new" => %Concord.KV.Record{value: "restored", mod_revision: 3}} =
             restored.current

    assert restored.history == %{}
    assert restored.leases == %{}
    assert restored.requests == %{}
    assert restored.revision == 3
    assert restored.compact_revision == 2
    assert restored.next_lease_id == 1
    assert restored.index_entries == %{"by-value" => %{"restored" => ["new"]}}
  end

  test "nested extractors and field compares return nil instead of raising on scalar intermediates" do
    context = Context.new!(op_number: 1, timestamp_ms: 1_000)

    assert {:ok, state} =
             Core.apply_command(
               context,
               {:create_index, "nested", {:nested, [:profile, :email]}},
               Core.init()
             )

    assert {%{revision: 1}, state} =
             Core.apply(context, {:put, "user", %{profile: 1}, %{}}, state)

    assert Core.query({:index_lookup, "nested", nil}, state, context) == {:ok, []}

    transaction = %{
      compare: [{:field, "user", [:profile, :email], :==, nil}],
      success: [],
      failure: []
    }

    assert {{:ok, %Concord.Txn.Result{succeeded: true}}, _state} =
             Core.apply(context, {:txn, transaction}, state)
  end

  test "drop schema admits an exact legacy name only for migration" do
    assert :ok = CommandSchema.validate(1, {:drop_index, :atom_name})
    assert {:error, :unsupported_command} = CommandSchema.validate(1, {:reindex, :atom_name})

    assert {:error, :unsupported_command} =
             CommandSchema.validate(1, {:create_index, :atom_name, {:identity}})
  end

  test "unsupported command versions and malformed envelopes return explicit errors" do
    state = Core.init()

    assert {{:error, {:unsupported_command_version, 2}}, ^state} =
             VSRStateMachine.apply(
               metadata(1),
               {:concord_command, 2, 1_000, {:put, "key", "value", %{}}},
               state
             )

    assert {{:error, :invalid_command_envelope}, ^state} =
             VSRStateMachine.apply(metadata(1), {:other_application, :command}, state)

    assert {{:error, :invalid_command_envelope}, ^state} =
             VSRStateMachine.apply(
               metadata(1),
               {:concord_command, CommandEnvelope.current_version(), -1, :command},
               state
             )
  end

  test "state-machine validation rejects unsafe commands that bypass the VSR engine" do
    state = Core.init()
    operation = CommandEnvelope.wrap(1_000, {:put, "key", fn -> :unsafe end, %{}})

    assert {{:error, {:invalid_command, :function_in_spec}}, ^state} =
             VSRStateMachine.apply(metadata(1), operation, state)
  end

  test "version-one validation rejects forged struct markers without raising" do
    forged = %{__struct__: self(), value: "unsafe"}

    assert {:error, {:invalid_command, :pid_in_spec}} =
             CommandSchema.validate_replay(1, {:put, "key", forged, %{}})

    state = Core.init()
    operation = CommandEnvelope.wrap(1_000, {:put, "key", forged, %{}})

    assert {{:error, {:invalid_command, :pid_in_spec}}, ^state} =
             VSRStateMachine.apply(metadata(1), operation, state)
  end

  test "unknown application commands return an explicit error" do
    state = Core.init()
    operation = CommandEnvelope.wrap(1_000, {:unknown_command, "payload"})

    assert {{:error, :unsupported_command}, next_state} =
             VSRStateMachine.apply(metadata(1), operation, state)

    assert next_state == state
  end

  test "state machine rejects function extractors even when public validation is bypassed" do
    state = Core.init()
    context = Context.new!(op_number: 1, timestamp_ms: 1_000)

    assert {{:error, :invalid_extractor}, next_state} =
             Core.apply(context, {:create_index, "unsafe", fn value -> value end}, state)

    assert next_state.indexes == %{}
    assert next_state.index_entries == %{}
  end

  test "nested extractors accept only atom and binary map keys" do
    state = Core.init()
    context = Context.new!(op_number: 1, timestamp_ms: 1_000)

    assert {{:error, :invalid_extractor}, next_state} =
             Core.apply(
               context,
               {:create_index, "unsafe-nested", {:nested, [:profile, Access.key(:email)]}},
               state
             )

    assert next_state.indexes == %{}

    assert {:ok, valid_state} =
             Core.apply_command(
               context,
               {:create_index, "safe-nested", {:nested, [:profile, "email"]}},
               state
             )

    assert valid_state.indexes == %{
             "safe-nested" => {:nested, [:profile, "email"]}
           }
  end

  test "snapshot restore fails closed for malformed and unsupported versions" do
    state = Core.init()
    assert {:ok, snapshot} = Core.snapshot(state)
    assert {:ok, ^state} = Core.restore(snapshot)
    current_version = snapshot.__concord_snapshot_version__

    assert {:error, :invalid_snapshot} =
             Core.restore(%{__concord_snapshot_version__: current_version})

    unsupported_version = current_version + 1

    assert {:error, {:unsupported_snapshot_version, ^unsupported_version}} =
             Core.restore(%{
               __concord_snapshot_version__: unsupported_version,
               state: %{store: %{"lost" => true}}
             })
  end

  test "version-four snapshots preserve legacy indexes while new backups reject them" do
    state = Core.init()
    context = Context.new!(op_number: 1, timestamp_ms: 1_000)

    unsafe_indexes = %{
      "legacy-function" => fn value -> value end,
      atom_name: {:identity}
    }

    unsafe_state = %{
      state
      | indexes: unsafe_indexes,
        index_entries: %{"legacy-function" => %{}, atom_name: %{}},
        representation: :legacy
    }

    assert {:ok, snapshot} = Core.snapshot(unsafe_state)

    assert {:ok, restored} = Core.restore(snapshot)
    assert is_function(restored.indexes["legacy-function"], 1)
    assert restored.indexes[:atom_name] == {:identity}

    backup = %{
      version: 2,
      kv_data: [{"key", "value"}],
      indexes: %{"legacy-function" => unsafe_indexes["legacy-function"]}
    }

    assert {{:error, {:invalid_index_extractor, "legacy-function"}}, next_state} =
             Core.apply(context, {:restore_backup, backup}, state)

    assert next_state.store == state.store
    assert next_state.indexes == state.indexes
  end

  test "snapshot restore rejects malformed state shapes without raising" do
    state = Core.init()
    assert {:ok, snapshot} = Core.snapshot(state)
    version = snapshot.__concord_snapshot_version__

    assert {:error, :invalid_snapshot} =
             Core.restore(%{__concord_snapshot_version__: version, state: :bad})

    assert {:error, :invalid_snapshot} = Core.restore(%{garbage: :value})
    assert {:error, {:invalid_snapshot, :invalid_entries}} = Core.restore([:bad])

    assert {:error, {:invalid_snapshot, {:invalid_index_keys, "x", :value}}} =
             Core.restore(%{
               __concord_snapshot_version__: version,
               state: %{
                 state
                 | indexes: %{"x" => {:identity}},
                   index_entries: %{"x" => %{value: :not_a_list}}
               }
             })

    assert {:error, {:invalid_snapshot, :invalid_state_maps}} =
             Core.restore(%{
               __concord_snapshot_version__: version,
               state: %{state | index_entries: nil}
             })

    assert {:error, {:invalid_snapshot, :invalid_state_maps}} =
             Core.snapshot(%{state | index_entries: nil})
  end
end
