defmodule ViewstampedReplication.Protocol.RecoveryTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Configuration, Log, LogEntry, Member}
  alias ViewstampedReplication.Protocol

  alias ViewstampedReplication.Protocol.{
    Envelope,
    GetState,
    NewState,
    Recovery,
    RecoveryResponse,
    State
  }

  test "empty multi-replica state starts nonce-scoped recovery" do
    state = State.new(configuration(3))

    assert {recovering,
            [
              {:broadcast, %Envelope{payload: %Recovery{nonce: :fresh_nonce}}},
              {:emit_telemetry, [:viewstamped_replication, :recovery, :start], _,
               %{message_type: :recovery}},
              {:schedule_timer, :recovery, _, token}
            ]} =
             Protocol.step(state, {:storage_recovered, {:empty, :fresh_nonce}})

    assert recovering.status == :recovering
    assert recovering.recovery_nonce == :fresh_nonce
    assert recovering.timer_tokens.recovery == token

    assert {retrying,
            [
              {:broadcast, %Envelope{payload: %Recovery{nonce: new_nonce}}},
              {:emit_telemetry, [:viewstamped_replication, :recovery, :start], _,
               %{message_type: :recovery}},
              {:schedule_timer, :recovery, _, _}
            ]} = Protocol.step(recovering, {:timeout, :recovery, token})

    refute new_nonce == :fresh_nonce
    assert retrying.recovery_nonce == new_nonce
  end

  test "only normal replicas respond and only the current primary includes full state" do
    primary = normal_state(1)
    backup = normal_state(2)
    recovering = State.new(configuration(1))

    assert {^primary,
            [
              {:send, 3,
               %Envelope{
                 payload: %RecoveryResponse{
                   nonce: :nonce,
                   view_number: 0,
                   op_number: 0,
                   commit_number: 0,
                   log: %Log{}
                 }
               }}
            ]} = peer_step(primary, 3, %Recovery{nonce: :nonce})

    assert {^backup,
            [
              {:send, 3,
               %Envelope{
                 payload: %RecoveryResponse{
                   nonce: :nonce,
                   view_number: 0,
                   op_number: nil,
                   commit_number: nil,
                   log: nil
                 }
               }}
            ]} = peer_step(backup, 3, %Recovery{nonce: :nonce})

    assert {^recovering, []} = peer_step(recovering, 3, %Recovery{nonce: :nonce})
  end

  test "recovery requires distinct quorum responses and full primary response at highest view" do
    state = %{State.new(configuration(3)) | recovery_nonce: :nonce}
    entry = entry(1)
    log = Log.append!(Log.new(), entry)

    backup_response = %RecoveryResponse{
      nonce: :nonce,
      view_number: 0,
      op_number: nil,
      commit_number: nil,
      log: nil
    }

    assert {waiting, []} = peer_step(state, 2, backup_response)
    assert map_size(waiting.recovery_responses) == 1

    assert {same_waiting, []} = peer_step(waiting, 2, backup_response)
    assert map_size(same_waiting.recovery_responses) == 1

    primary_response = %RecoveryResponse{
      nonce: :nonce,
      view_number: 0,
      op_number: 1,
      commit_number: 1,
      log: log,
      client_table: %{}
    }

    assert {normal, effects} = peer_step(same_waiting, 1, primary_response)
    assert normal.status == :normal
    assert normal.log == log
    assert normal.commit_number == 1
    assert normal.applying_number == 1
    assert Enum.any?(effects, &match?({:persist, {:install_state, _}}, &1))
    assert Enum.any?(effects, &match?({:apply, ^entry}, &1))
    assert Enum.any?(effects, &match?({:schedule_timer, :primary, _, _}, &1))
  end

  test "stale recovery nonce and quorum without highest-view primary are ignored" do
    state = %{State.new(configuration(3)) | recovery_nonce: :current}

    stale = %RecoveryResponse{nonce: :old, view_number: 0}
    assert {^state, []} = peer_step(state, 1, stale)

    view_one_backup = %RecoveryResponse{nonce: :current, view_number: 1}

    view_zero_primary = %RecoveryResponse{
      nonce: :current,
      view_number: 0,
      op_number: 0,
      commit_number: 0,
      log: Log.new()
    }

    {waiting, []} = peer_step(state, 3, view_one_backup)
    assert {still_waiting, []} = peer_step(waiting, 1, view_zero_primary)
    assert still_waiting.status == :recovering
  end

  test "GetState returns a transferable state and NewState installs it from the primary" do
    entry = entry(1)

    primary = %{
      normal_state(1)
      | log: Log.append!(Log.new(), entry),
        op_number: 1,
        commit_number: 1
    }

    assert {^primary,
            [
              {:send, 3,
               %Envelope{
                 payload: %NewState{
                   view_number: 0,
                   op_number: 1,
                   commit_number: 1,
                   log: %Log{}
                 }
               }}
            ]} = peer_step(primary, 3, %GetState{view_number: 0, from_op_number: 1})

    new_state = %NewState{
      view_number: 0,
      last_normal_view: 0,
      op_number: 1,
      commit_number: 1,
      log: primary.log,
      client_table: primary.client_table,
      snapshot: %{state: :snapshot},
      snapshot_op_number: 0,
      log_suffix: [entry]
    }

    recovering = State.new(configuration(3))
    assert {installed, effects} = peer_step(recovering, 1, new_state)
    assert installed.status == :normal
    assert installed.log == primary.log
    assert Enum.any?(effects, &match?({:persist, {:install_state, _}}, &1))
  end

  test "single-replica empty bootstrap enters normal directly" do
    state = State.new(single_configuration())

    assert {normal,
            [
              {:persist, {:hard_state, %{status: :normal}}},
              {:schedule_timer, :heartbeat, _, _}
            ]} = Protocol.step(state, {:storage_recovered, :empty})

    assert normal.status == :normal
  end

  test "snapshot completion compacts the local log and persists the checkpoint before state" do
    entries = [entry(1), entry(2), entry(3)]
    {:ok, log} = Log.new(entries)

    state = %{
      normal_state(1)
      | log: log,
        op_number: 3,
        commit_number: 3,
        applied_number: 3
    }

    snapshot = %{last_op_number: 2, state_machine: %{value: 2}}

    assert {compacted,
            [
              {:persist, {:write_snapshot, ^snapshot}},
              {:persist,
               {:install_state, %{snapshot: ^snapshot, snapshot_op_number: 2, applied_number: 3}}}
            ]} = Protocol.step(state, {:snapshot_completed, 2, snapshot})

    assert compacted.snapshot == snapshot
    assert compacted.snapshot_op_number == 2
    assert compacted.log.base_op_number == 2
    assert [%LogEntry{op_number: 3}] = Log.to_list(compacted.log)
  end

  test "peer checkpoint install restores snapshot before installing and applying suffix" do
    snapshot = %{last_op_number: 2, state_machine: %{value: 2}}
    third = entry(3)
    {:ok, compacted_log} = Log.new(2, [third])

    new_state = %NewState{
      view_number: 0,
      last_normal_view: 0,
      op_number: 3,
      commit_number: 3,
      log: compacted_log,
      client_table: %{},
      snapshot: snapshot,
      snapshot_op_number: 2,
      log_suffix: [third]
    }

    recovering = State.new(configuration(3))

    assert {installed,
            [
              {:persist, {:install_snapshot, ^snapshot}},
              {:persist,
               {:install_state, %{snapshot_op_number: 2, applied_number: 2, log: ^compacted_log}}},
              {:cancel_timer, :view_change},
              {:cancel_timer, :recovery},
              {:emit_telemetry, [:viewstamped_replication, :recovery, :stop], _,
               %{message_type: :new_state}},
              {:schedule_timer, :primary, _, _},
              {:apply, ^third}
            ]} = peer_step(recovering, 1, new_state)

    assert installed.status == :normal
    assert installed.snapshot_op_number == 2
    assert installed.applied_number == 2
    assert installed.applying_number == 3
  end

  test "GetState sends and receiver merges only a missing log suffix for a small gap" do
    entries = [entry(1), entry(2), entry(3)]
    {:ok, primary_log} = Log.new(entries)

    primary = %{
      normal_state(1)
      | log: primary_log,
        op_number: 3,
        commit_number: 2
    }

    assert {^primary,
            [
              {:send, 3,
               %Envelope{
                 payload: %NewState{
                   log: %Log{base_op_number: 2, entries: [third]},
                   log_suffix: [third],
                   snapshot: nil
                 }
               }}
            ]} = peer_step(primary, 3, %GetState{view_number: 0, from_op_number: 3})

    assert third.op_number == 3

    {:ok, local_log} = Log.new(Enum.take(entries, 2))
    receiver = %{normal_state(3) | log: local_log, op_number: 2}

    suffix_message = %NewState{
      view_number: 0,
      op_number: 3,
      commit_number: 2,
      log: %Log{base_op_number: 2, entries: [third]},
      log_suffix: [third],
      client_table: %{}
    }

    assert {installed, _effects} = peer_step(receiver, 1, suffix_message)
    assert installed.log == primary_log
    assert installed.op_number == 3
  end

  test "GetState sends checkpoint and its post-checkpoint suffix for a compacted gap" do
    snapshot = %{last_op_number: 2, state_machine: %{value: 2}}
    third = entry(3)
    {:ok, compacted_log} = Log.new(2, [third])

    primary = %{
      normal_state(1)
      | log: compacted_log,
        snapshot: snapshot,
        snapshot_op_number: 2,
        op_number: 3,
        commit_number: 3,
        applied_number: 2
    }

    assert {^primary,
            [
              {:send, 3,
               %Envelope{
                 payload: %NewState{
                   log: ^compacted_log,
                   snapshot: ^snapshot,
                   snapshot_op_number: 2,
                   log_suffix: [^third]
                 }
               }}
            ]} = peer_step(primary, 3, %GetState{view_number: 0, from_op_number: 1})
  end

  test "verified durable recovery can rejoin normal without a live peer quorum" do
    recovered = %{
      configuration_hash: Configuration.hash(configuration(2)),
      replica_id: 2,
      hard_state: %{view_number: 0, last_normal_view: 0, status: :normal},
      log: [],
      commit_number: 0,
      applied_number: 0,
      snapshot: nil,
      client_table: %{}
    }

    assert {normal, [{:schedule_timer, :primary, _, _}]} =
             Protocol.step(
               State.new(configuration(2)),
               {:storage_recovered, {:durable, recovered}}
             )

    assert normal.status == :normal
  end

  defp normal_state(replica_id), do: %{State.new(configuration(replica_id)) | status: :normal}

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

  defp single_configuration do
    Configuration.new!(
      group_id: :single,
      replica_id: 1,
      members: [%Member{id: 1, endpoint: :one}]
    )
  end

  defp entry(op_number) do
    %LogEntry{
      view_number: 0,
      op_number: op_number,
      client_id: :client,
      request_number: op_number,
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
