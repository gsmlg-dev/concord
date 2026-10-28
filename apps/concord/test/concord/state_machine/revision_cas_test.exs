defmodule Concord.StateMachine.RevisionCASTest do
  use ExUnit.Case, async: false

  alias Concord.{CommandEnvelope, CommandSchema, Compression, StateMachine}
  alias Concord.Engine.VSR.StateMachine, as: Adapter
  alias Concord.KV.Record
  alias Concord.StateMachine.Core
  alias Concord.StateMachine.Core.Context
  alias Concord.Sync.Dispatcher
  alias ViewstampedReplication.ApplyMetadata

  setup do
    owner = self()

    on_exit(fn ->
      reference = Process.monitor(owner)

      receive do
        {:DOWN, ^reference, :process, ^owner, _reason} -> :ok
      end
    end)

    :ok
  end

  test "CAS is an explicit v2 command, preserving both historical replay languages" do
    command = {:compare_and_swap, "key", "new", 0, %{}}
    initial = Core.init()
    assert :ok = CommandSchema.validate_replay(0, command)
    assert {:error, :unsupported_command} = CommandSchema.validate_replay(1, command)
    assert :ok = CommandSchema.validate_replay(2, command)

    assert {:ok, legacy} =
             Adapter.apply(metadata(1), CommandEnvelope.wrap(1_000, command, 0), initial)

    assert legacy.current == %{}
    assert legacy.revision == 0

    assert {{:error, :unsupported_command}, ^initial} =
             Adapter.apply(metadata(1), CommandEnvelope.wrap(1_000, command, 1), initial)

    assert {%{succeeded: true, revision: 1}, current} =
             Adapter.apply(metadata(1), CommandEnvelope.wrap(1_000, command, 2), initial)

    assert {:ok, "new"} = Core.query({:get, "key"}, current, context())
    assert {{:error, :unsupported_command}, ^initial} = Core.apply(context(1), command, initial)
  end

  test "large values retain history and a conflict changes no data or revision" do
    old = :binary.copy("history", 160_000)
    new = :binary.copy("replacement", 110_000)
    {first, state} = cas(Core.init(), old, 0)
    {second, next} = cas(state, new, first.revision)
    assert second.succeeded
    assert second.revision == first.revision + 1
    assert second.current_kv.value == nil
    assert next.current["key"].value == new
    assert next.history[{"key", first.revision}].value == old

    {conflict, final} = cas(next, "stale", first.revision)

    assert conflict == %{
             succeeded: false,
             revision: second.revision,
             current_kv: second.current_kv
           }

    assert %{final | command_count: next.command_count} == next
  end

  test "expected zero observes absence, deletion and expiry; stale revisions cannot overwrite" do
    {missing, initial} = cas(Core.init(), "unused", 4)
    assert missing == %{succeeded: false, revision: 0, current_kv: nil}
    {first, state} = cas(initial, "one", 0, %{ttl: 1})
    {expired, state} = cas(state, "two", 0, %{}, 3_000)
    assert expired.succeeded
    assert expired.revision == first.revision + 1
    {:ok, state} = Core.apply(context(), {:touch, "key", 10}, state)
    {stale, state} = cas(state, "unused", expired.revision)
    refute stale.succeeded
    {%{revision: deleted}, state} = Core.apply(context(), {:delete, "key", %{}}, state)
    {recreated, state} = cas(state, "three", 0)
    assert recreated.revision == deleted + 1
    assert recreated.current_kv.version == 1
    assert recreated.current_kv.create_revision == recreated.revision
    {stale, _} = cas(state, "unused", first.revision)
    refute stale.succeeded
  end

  test "CAS reuses deterministic indexes, leases and put metadata" do
    {:ok, state} = Core.apply(context(), {:create_index, "tags", {:map_get, :tag}}, Core.init())
    {{:ok, %{lease_id: lease}}, state} = Core.apply(context(), {:grant_lease, 60, %{}}, state)
    {first, state} = cas(state, %{tag: :old}, 0, %{lease: lease})
    assert state.leases[lease].keys == ["key"]
    assert {:ok, ["key"]} = Core.query({:index_lookup, "tags", :old}, state, context())

    {second, state} =
      cas(state, %{tag: :new}, first.revision, %{
        ttl: 30,
        content_type: "application/json",
        metadata: %{a: 1}
      })

    assert second.current_kv.expires_at == 31
    assert second.current_kv.content_type == "application/json"
    assert second.current_kv.metadata == %{a: 1}
    assert state.leases[lease].keys == []
    assert {:ok, []} = Core.query({:index_lookup, "tags", :old}, state, context())
    assert {:ok, ["key"]} = Core.query({:index_lookup, "tags", :new}, state, context())

    assert {{:error, :lease_not_found}, _} =
             Core.apply(
               context(),
               {:compare_and_swap, "key", :unused, second.revision, %{lease: 999}},
               state
             )
  end

  test "CAS validates both value encodings while generic transactions keep their frozen cap" do
    value = :binary.copy("x", 1_100_000)

    for encoded <- [value, Compression.compress(value, force: true)] do
      assert :ok = CommandSchema.validate_replay(2, {:compare_and_swap, "key", encoded, 0, %{}})
      command = {:txn, %{compare: [], success: [{:put, "key", encoded, %{}}], failure: []}}

      assert {:error, {:invalid_command, :transaction_too_large}} =
               CommandSchema.validate_replay(2, command)
    end

    for command <- [
          {:compare_and_swap, "key", :value, -1, %{}},
          {:compare_and_swap, "key", :value, 0, %{prev_kv: true}},
          {:compare_and_swap, "key", :value, 0, %{ttl: 1, lease: 1}}
        ] do
      assert {:error, :unsupported_command} = CommandSchema.validate_emission(command)
    end

    assert {:error, {:invalid_command, :pid_in_spec}} =
             CommandSchema.validate_emission({:compare_and_swap, "key", self(), 0, %{}})
  end

  test "version2 adapters track one committed change, no conflict event, and snapshot4 replay" do
    Process.register(self(), Dispatcher)
    initial = Core.init()
    StateMachine.materialize(initial)
    command = {:compare_and_swap, "key", "value", 0, %{}}

    assert {%{succeeded: true}, state} =
             Adapter.apply(metadata(1), CommandEnvelope.wrap(1_000, command, 2), initial)

    assert_receive {:"$gen_cast", {:dispatch, [%{type: :put, key: "key", revision: 1}]}}
    assert [{"key", %Record{value: "value"}}] = :ets.lookup(:concord_current, "key")
    {_, _next, changes} = Core.apply_with_changes(2, context(), command, state)
    assert changes == []

    assert {%{succeeded: false}, state} =
             Adapter.apply(metadata(2), CommandEnvelope.wrap(1_001, command, 2), state)

    refute_receive {:"$gen_cast", {:dispatch, _}}
    assert {:ok, %{__concord_snapshot_version__: 4} = snapshot} = Adapter.snapshot(state)
    assert {:ok, restored} = Adapter.restore(snapshot)
    assert {:ok, "value"} = Core.query({:get, "key"}, restored, context())
  end

  test "v2 rejects oversized compressed CAS values and oversized metadata envelopes" do
    oversized = :binary.copy("x", CommandSchema.max_value_bytes())
    encoded = Compression.compress(oversized, force: true)

    assert {:error, {:invalid_command, :value_too_large}} =
             CommandSchema.validate_replay(2, {:compare_and_swap, "key", encoded, 0, %{}})

    assert {:error, {:invalid_command, :invalid_compressed_value}} =
             CommandSchema.validate_replay(
               2,
               {:compare_and_swap, "key", {:compressed, :zlib, "invalid"}, 0, %{}}
             )

    metadata = %{payload: :binary.copy("x", CommandSchema.max_command_bytes())}

    assert {:error, {:invalid_command, :command_too_large}} =
             CommandSchema.validate_replay(
               2,
               {:compare_and_swap, "key", :value, 0, %{metadata: metadata}}
             )
  end

  defp cas(state, value, expected, opts \\ %{}, timestamp \\ 1_000) do
    Core.apply(context(2, timestamp), {:compare_and_swap, "key", value, expected, opts}, state)
  end

  defp context(version \\ 2, timestamp \\ 1_000),
    do: Context.new!(op_number: 1, timestamp_ms: timestamp, command_version: version)

  defp metadata(op),
    do: %ApplyMetadata{
      group_id: :cas,
      view_number: 0,
      op_number: op,
      client_id: :cas,
      request_number: op
    }
end
