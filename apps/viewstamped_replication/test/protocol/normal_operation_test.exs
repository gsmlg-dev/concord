defmodule ViewstampedReplication.Protocol.NormalOperationTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Configuration, Log, LogEntry, Member, Reply, Request}
  alias ViewstampedReplication.Protocol

  alias ViewstampedReplication.Protocol.{
    Commit,
    Envelope,
    GetState,
    Prepare,
    PrepareOk,
    ReadBarrier,
    ReadBarrierOk,
    State
  }

  test "primary persists, prepares, commits on quorum, applies, and replies" do
    state = normal_state(1)
    request = request(:client, 1, {:put, :key, :value})

    assert {prepared,
            [
              {:emit_telemetry, [:viewstamped_replication, :request, :start], _,
               %{message_type: :request}},
              {:persist, {:append, %LogEntry{op_number: 1} = entry}},
              {:broadcast, %Envelope{payload: %Prepare{op_number: 1, entry: entry}}},
              {:emit_telemetry, [:viewstamped_replication, :prepare, :sent], _,
               %{message_type: :prepare}}
            ]} = Protocol.step(state, {:client_request, :route, request})

    assert prepared.op_number == 1
    assert prepared.commit_number == 0
    assert MapSet.equal?(prepared.prepare_acks[1], MapSet.new([1]))

    assert {committed,
            [
              {:persist, {:set_commit_number, 1}},
              {:broadcast, %Envelope{payload: %Commit{commit_number: 1}}},
              {:emit_telemetry, [:viewstamped_replication, :commit], _, %{message_type: :commit}},
              {:apply, ^entry}
            ]} = peer_step(prepared, 2, %PrepareOk{view_number: 0, op_number: 1})

    assert committed.commit_number == 1
    assert committed.applied_number == 0
    assert committed.applying_number == 1

    assert {applied,
            [
              {:persist, {:applied, 1, client_table}},
              {:emit_telemetry, [:viewstamped_replication, :request, :stop], _,
               %{message_type: :reply}},
              {:reply, :route,
               %Reply{
                 client_id: :client,
                 request_number: 1,
                 result: :ok
               }}
            ]} = Protocol.step(committed, {:state_machine_applied, 1, :ok})

    assert %{client: %{request_number: 1, status: :applied, result: :ok}} = client_table
    assert applied.applied_number == 1
    assert applied.applying_number == nil
  end

  test "duplicate applied and pending requests do not append another entry" do
    state = normal_state(1)
    request = request(:client, 7, :operation)
    {pending, _effects} = Protocol.step(state, {:client_request, :first_route, request})

    assert {rerouted, []} =
             Protocol.step(pending, {:client_request, :retry_route, request})

    assert rerouted.op_number == 1
    assert rerouted.pending_clients[{:client, 7}] == :retry_route

    {committed, _effects} =
      peer_step(rerouted, 2, %PrepareOk{view_number: 0, op_number: 1})

    {applied, _effects} = Protocol.step(committed, {:state_machine_applied, 1, :cached})

    assert {^applied,
            [
              {:reply, :lost_reply_retry,
               %Reply{client_id: :client, request_number: 7, result: :cached}}
            ]} =
             Protocol.step(applied, {:client_request, :lost_reply_retry, request})
  end

  test "primary completes a read after confirming its view with a quorum" do
    state = normal_state(1)

    assert {pending,
            [
              {:broadcast,
               %Envelope{
                 payload:
                   %ReadBarrier{
                     view_number: 0,
                     nonce: nonce,
                     commit_number: 0
                   }
               }},
              {:schedule_timer, :read, _, read_timer}
            ]} = Protocol.step(state, {:read_request, :route, {:get, :key}})

    assert pending.op_number == 0
    assert pending.timer_tokens.read == read_timer

    assert {completed,
            [
              {:read, :route, {:get, :key}},
              {:cancel_timer, :read}
            ]} =
             peer_step(
               pending,
               2,
               %ReadBarrierOk{view_number: 0, nonce: nonce}
             )

    assert completed.op_number == 0
    assert completed.pending_reads == %{}
  end

  test "backup acknowledges a current-view read barrier without appending" do
    state = normal_state(2)

    assert {acknowledged,
            [
              {:send, 1,
               %Envelope{
                 payload: %ReadBarrierOk{view_number: 0, nonce: :read_nonce}
               }},
              {:schedule_timer, :primary, _, _}
            ]} =
             peer_step(
               state,
               1,
               %ReadBarrier{
                 view_number: 0,
                 nonce: :read_nonce,
                 commit_number: 0
               }
             )

    assert acknowledged.op_number == 0
    assert acknowledged.commit_number == 0
  end

  test "stale requests are rejected and one outstanding request per client is enforced" do
    state = normal_state(1)
    {pending, _effects} = Protocol.step(state, {:client_request, :route, request(:client, 4, :a)})

    assert {^pending,
            [
              {:reply, :route, %Reply{request_number: 3, result: {:error, :stale_request}}}
            ]} =
             Protocol.step(pending, {:client_request, :route, request(:client, 3, :old)})

    assert {^pending,
            [
              {:reply, :route, %Reply{request_number: 5, result: {:error, :request_in_progress}}}
            ]} =
             Protocol.step(pending, {:client_request, :route, request(:client, 5, :new)})
  end

  test "backup persists a contiguous prepare before acknowledging it" do
    state = normal_state(2)
    entry = entry(1, 0, :client, 1)

    assert {accepted,
            [
              {:persist, {:append, ^entry}},
              {:send, 1, %Envelope{payload: %PrepareOk{view_number: 0, op_number: 1}}},
              {:schedule_timer, :primary, _, token}
            ]} =
             peer_step(state, 1, %Prepare{
               view_number: 0,
               op_number: 1,
               commit_number: 0,
               entry: entry
             })

    assert accepted.op_number == 1
    assert accepted.timer_tokens.primary == token
  end

  test "duplicate prepare is acknowledged without appending again" do
    entry = entry(1, 0, :client, 1)
    state = %{normal_state(2) | log: Log.append!(Log.new(), entry), op_number: 1}

    assert {same_log,
            [
              {:send, 1, %Envelope{payload: %PrepareOk{op_number: 1}}},
              {:schedule_timer, :primary, _, _}
            ]} =
             peer_step(state, 1, %Prepare{
               view_number: 0,
               op_number: 1,
               commit_number: 0,
               entry: entry
             })

    assert Log.to_list(same_log.log) == [entry]
  end

  test "out-of-order prepare and commit request missing state without mutating the log" do
    state = normal_state(2)
    entry = entry(2, 0, :client, 2)

    assert {^state,
            [
              {:request_state_transfer, 1, 1..2},
              {:send, 1, %Envelope{payload: %GetState{from_op_number: 1}}}
            ]} =
             peer_step(state, 1, %Prepare{
               view_number: 0,
               op_number: 2,
               commit_number: 0,
               entry: entry
             })

    assert {^state,
            [
              {:request_state_transfer, 1, 1..2},
              {:send, 1, %Envelope{payload: %GetState{from_op_number: 1}}}
            ]} = peer_step(state, 1, %Commit{view_number: 0, commit_number: 2})
  end

  test "stale normal messages are ignored and future normal messages start state transfer" do
    state = %{normal_state(2) | view_number: 1, last_normal_view: 1}
    stale = entry(1, 0, :client, 1)

    assert {^state, []} =
             peer_step(state, 1, %Prepare{
               view_number: 0,
               op_number: 1,
               commit_number: 0,
               entry: stale
             })

    future = entry(1, 2, :client, 1)

    assert {recovering,
            [
              {:persist, {:hard_state, %{view_number: 2, status: :recovering}}},
              {:request_state_transfer, 3, 1..1},
              {:send, 3, %Envelope{payload: %GetState{view_number: 2, from_op_number: 1}}}
            ]} =
             peer_step(state, 3, %Prepare{
               view_number: 2,
               op_number: 1,
               commit_number: 0,
               entry: future
             })

    assert recovering.status == :recovering
    assert recovering.view_number == 2
    assert recovering.log == state.log
  end

  test "PrepareOk for N implies acknowledgement of the contiguous prefix" do
    state = normal_state(1)
    {one, _effects} = Protocol.step(state, {:client_request, :a, request(:a, 1, :one)})
    {two, _effects} = Protocol.step(one, {:client_request, :b, request(:b, 1, :two)})

    assert {committed, effects} =
             peer_step(two, 2, %PrepareOk{view_number: 0, op_number: 2})

    assert committed.commit_number == 2
    assert {:persist, {:set_commit_number, 2}} in effects
    assert {:apply, Log.fetch!(committed.log, 1)} in effects
  end

  test "peer envelopes with a missing or mismatched configuration hash are ignored" do
    state = normal_state(2)
    entry = entry(1, 0, :client, 1)
    prepare = %Prepare{view_number: 0, op_number: 1, commit_number: 0, entry: entry}

    for configuration_hash <- [nil, <<0::256>>] do
      envelope = %Envelope{
        group_id: state.group_id,
        configuration_hash: configuration_hash,
        from: 1,
        payload: prepare
      }

      assert {^state, []} = Protocol.step(state, {:peer_message, 1, envelope})
    end
  end

  defp normal_state(replica_id) do
    replica_id
    |> configuration()
    |> State.new()
    |> Map.put(:status, :normal)
  end

  defp configuration(replica_id) do
    Configuration.new!(
      group_id: :group,
      replica_id: replica_id,
      members: [
        %Member{id: 1, endpoint: :one},
        %Member{id: 2, endpoint: :two},
        %Member{id: 3, endpoint: :three}
      ]
    )
  end

  defp request(client_id, request_number, operation) do
    %Request{client_id: client_id, request_number: request_number, operation: operation}
  end

  defp entry(op_number, view_number, client_id, request_number) do
    %LogEntry{
      view_number: view_number,
      op_number: op_number,
      client_id: client_id,
      request_number: request_number,
      operation: {:operation, op_number}
    }
  end

  defp peer_step(state, sender, payload) do
    Protocol.step(
      state,
      {:peer_message, sender,
       %Envelope{
         group_id: state.group_id,
         configuration_hash: Configuration.hash(state.configuration),
         from: sender,
         payload: payload
       }}
    )
  end
end
