defmodule ViewstampedReplication.Protocol.ContractsTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Configuration, Log, LogEntry, Member, Request}
  alias ViewstampedReplication.Protocol
  alias ViewstampedReplication.Protocol.{Envelope, Prepare, State}

  setup do
    configuration =
      Configuration.new!(
        group_id: :test_group,
        replica_id: 1,
        members: [%Member{id: 1, endpoint: :replica_1}]
      )

    %{state: State.new(configuration)}
  end

  test "new protocol state starts recovering with an empty log", %{state: state} do
    assert %State{
             group_id: :test_group,
             replica_id: 1,
             status: :recovering,
             view_number: 0,
             op_number: 0,
             commit_number: 0,
             applied_number: 0,
             client_table: %{}
           } = state

    assert %Log{entries: []} = state.log
    assert state == Protocol.assert_invariants!(state)
  end

  test "a recovering replica rejects client requests without mutating state", %{state: state} do
    request = %Request{client_id: :client, request_number: 1, operation: {:put, :value}}

    assert {^state,
            [
              {:reply, _route,
               %ViewstampedReplication.Reply{
                 client_id: :client,
                 request_number: 1,
                 result: {:error, :recovering}
               }}
            ]} = Protocol.step(state, {:client_request, self(), request})
  end

  test "step rejects events outside the event contract", %{state: state} do
    assert_raise ArgumentError, ~r/invalid protocol event/, fn ->
      Protocol.step(state, {:unknown, :event})
    end
  end

  test "message contracts preserve their protocol fields" do
    entry = entry(1, :client, 1)

    message = %Prepare{view_number: 2, op_number: 1, commit_number: 0, entry: entry}
    envelope = %Envelope{group_id: :test_group, from: 1, payload: message}

    assert %Envelope{
             protocol_version: 1,
             group_id: :test_group,
             from: 1,
             payload: %Prepare{view_number: 2, op_number: 1, commit_number: 0}
           } = envelope
  end

  test "invariants reject invalid operation number ordering", %{state: state} do
    invalid = %{state | commit_number: 1}

    assert_raise ArgumentError, ~r/invalid_operation_numbers/, fn ->
      Protocol.assert_invariants!(invalid)
    end
  end

  test "invariants require the operation number to match the log", %{state: state} do
    invalid = %{state | op_number: 1}

    assert_raise ArgumentError, ~r/log_op_number_mismatch/, fn ->
      Protocol.assert_invariants!(invalid)
    end
  end

  test "transition invariants reject decreasing view, commit, and applied numbers", %{
    state: state
  } do
    log = Log.append!(state.log, entry(1, :client, 1))

    previous = %{
      state
      | status: :normal,
        view_number: 2,
        op_number: 1,
        commit_number: 1,
        applied_number: 1,
        log: log
    }

    for {changes, reason} <- [
          {%{view_number: 1}, "view_number_decreased"},
          {%{commit_number: 0, applied_number: 0}, "commit_number_decreased"},
          {%{applied_number: 0}, "applied_number_decreased"}
        ] do
      current = struct!(previous, changes)

      assert_raise ArgumentError, ~r/#{reason}/, fn ->
        Protocol.assert_transition!(previous, current)
      end
    end
  end

  test "transition invariants reject replacement of a committed entry", %{state: state} do
    previous_log = Log.append!(state.log, entry(1, :client_a, 1))
    current_log = Log.append!(state.log, entry(1, :client_b, 1))
    previous = %{state | status: :normal, op_number: 1, commit_number: 1, log: previous_log}
    current = %{previous | log: current_log}

    assert_raise ArgumentError, ~r/committed_entry_replaced/, fn ->
      Protocol.assert_transition!(previous, current)
    end
  end

  test "invariants reject applying the same client request twice", %{state: state} do
    log =
      state.log
      |> Log.append!(entry(1, :client, 7))
      |> Log.append!(entry(2, :client, 7))

    invalid = %{
      state
      | status: :normal,
        op_number: 2,
        commit_number: 2,
        applied_number: 2,
        log: log
    }

    assert_raise ArgumentError, ~r/client_request_applied_more_than_once/, fn ->
      Protocol.assert_invariants!(invalid)
    end
  end

  defp entry(op_number, client_id, request_number) do
    %LogEntry{
      view_number: 0,
      op_number: op_number,
      client_id: client_id,
      request_number: request_number,
      operation: {:operation, op_number}
    }
  end
end
