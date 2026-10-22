defmodule ViewstampedReplication.Protocol.OwnedRuntimeTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Configuration, Log, LogEntry, Member, Protocol, Request}
  alias ViewstampedReplication.Protocol.State

  test "owned singleton transitions produce the exhaustive kernel's state and ordered effects" do
    state = ready_state()
    {owned, advance} = Protocol.runtime(state)

    events = [
      {:client_request, :first, request(:writer, 1)},
      {:state_machine_applied, 1, :first_result},
      {:client_request, :retry, request(:writer, 1)},
      {:client_request, :stale, request(:writer, 0)},
      {:client_request, :other, request(:other, 22)},
      {:state_machine_applied, 2, :second_result},
      {:state_machine_applied, 100, :ignored},
      {:read_request, :reader, :query},
      {:snapshot_completed, 1, %{last_op_number: 1}},
      {:client_request, :after_snapshot, request(:writer, 2)},
      {:state_machine_applied, 3, :third_result}
    ]

    Enum.reduce(events, {state, owned, advance}, fn event, {pure, _owned, advance} ->
      {next_pure, pure_effects} = Protocol.step(pure, event)
      {next_owned, owned_effects, next_advance} = advance.(event)
      assert owned_effects == pure_effects
      assert %{next_owned | log: Log.canonical(next_owned.log)} == next_pure
      assert Protocol.assert_invariants!(next_owned) == next_owned
      {next_pure, next_owned, next_advance}
    end)
  end

  test "the factory rebuilds untrusted index metadata and its closure cannot accept replacement state" do
    state = applied_state()

    forged = %{
      state
      | applied_request_index: %{writer: %{1 => :wrong, 2 => 2}, forged: %{3 => 99}}
    }

    {owned, advance} = Protocol.runtime(forged)
    assert owned.applied_request_index == %{writer: %{1 => 1, 2 => 2}}
    assert is_function(advance, 1)
    refute is_function(advance, 2)
    {pending, _effects, acknowledge} = advance.({:client_request, :route, request(:writer, 3)})
    assert pending.op_number == 3
    {complete, _effects, _advance} = acknowledge.({:state_machine_applied, 3, :ok})
    assert complete.applied_request_index == %{writer: %{1 => 1, 2 => 2, 3 => 3}}

    forged_entries = List.update_at(state.log.entries, 1, &%{&1 | request_number: 1})
    invalid = %{state | log: %{state.log | entries: forged_entries}}

    assert_raise ArgumentError, ~r/client_request_applied_more_than_once/, fn ->
      Protocol.runtime(invalid)
    end
  end

  test "public validation still checks indexed states exhaustively" do
    {owned, _advance} = Protocol.runtime(applied_state())
    invalid_log = %{owned.log | entries: Map.delete(owned.log.entries, 1)}

    assert_raise ArgumentError, "invalid indexed log", fn ->
      Protocol.step(%{owned | log: invalid_log}, {:read_request, :route, :query})
    end

    rewritten = Log.fetch!(owned.log, 1) |> Map.put(:operation, :rewritten)
    changed = %{owned | log: %{owned.log | entries: Map.put(owned.log.entries, 1, rewritten)}}

    assert_raise ArgumentError, ~r/committed_entry_replaced/, fn ->
      Protocol.assert_transition!(owned, changed)
    end
  end

  test "missing client-table history cannot make an owned apply admit duplicate request pairs" do
    state = %{applied_state() | client_table: %{}}
    {_owned, advance} = Protocol.runtime(state)
    {_pending, _effects, acknowledge} = advance.({:client_request, :route, request(:writer, 1)})

    assert_raise ArgumentError, ~r/client_request_applied_more_than_once/, fn ->
      acknowledge.({:state_machine_applied, 3, :ok})
    end
  end

  defp request(client, number),
    do: %Request{client_id: client, request_number: number, operation: {:put, :key, :value}}

  defp ready_state do
    configuration =
      Configuration.new!(
        group_id: :owned_runtime,
        replica_id: 1,
        members: [%Member{id: 1, endpoint: :owned_runtime}]
      )

    {state, _effects} =
      Protocol.step(State.new(configuration), {:storage_recovered, {:bootstrap, :nonce}})

    state
  end

  defp applied_state do
    state = ready_state()

    entries =
      for number <- 1..2,
          do: %LogEntry{
            view_number: 0,
            op_number: number,
            client_id: :writer,
            request_number: number,
            operation: {:put, :key, :value}
          }

    {:ok, log} = Log.new(entries)

    %{
      state
      | log: log,
        op_number: 2,
        commit_number: 2,
        applied_number: 2,
        client_table: %{writer: %{request_number: 2, status: :applied, result: :ok}}
    }
  end
end
