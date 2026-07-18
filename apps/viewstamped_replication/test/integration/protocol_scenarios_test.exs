defmodule ViewstampedReplication.Test.ProtocolScenariosTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ViewstampedReplication.{LogEntry, Request}

  alias ViewstampedReplication.Protocol.{
    Commit,
    Envelope,
    GetState,
    NewState,
    Prepare,
    PrepareOk,
    Recovery,
    StartView,
    StartViewChange
  }

  alias ViewstampedReplication.Test.{Linearizability, Simulator}
  alias ViewstampedReplication.Test.Simulator.{ClientReply, Message, Timer}

  test "three replicas commit and apply a register write in order" do
    simulator =
      Simulator.new(seed: 101)
      |> Simulator.submit_client_request(1, request(1, {:write, 10}))
      |> deliver_payload(Prepare, 2)
      |> deliver_payload(PrepareOk, 1)
      |> Simulator.deliver_all()

    assert Enum.all?(simulator.replicas, fn {_id, state} ->
             state.commit_number == 1 and state.applied_number == 1
           end)

    assert Enum.all?(simulator.machine_states, fn {_id, value} -> value == 10 end)
    assert Linearizability.linearizable?(simulator.history)
  end

  test "one unavailable backup does not prevent quorum commit" do
    simulator =
      Simulator.new(seed: 102)
      |> Simulator.crash_replica(3)
      |> Simulator.submit_client_request(1, request(1, {:write, 10}))
      |> Simulator.deliver_all()

    assert simulator.replicas[1].commit_number == 1
    assert simulator.replicas[2].commit_number == 1
    assert simulator.replicas[3].commit_number == 0
    assert simulator.machine_states[1] == 10
    assert simulator.machine_states[2] == 10
    assert Linearizability.linearizable?(simulator.history)
  end

  test "an isolated minority primary cannot commit" do
    simulator =
      Simulator.new(seed: 103)
      |> Simulator.partition(1, [2, 3])
      |> Simulator.submit_client_request(1, request(1, {:write, 10}))
      |> Simulator.deliver_all()

    assert simulator.replicas[1].op_number == 1
    assert simulator.replicas[1].commit_number == 0
    assert simulator.replicas[1].applied_number == 0
    refute Enum.any?(simulator.history, &(&1.type == :complete))
  end

  test "a lost reply is retried without applying the client request twice" do
    request = request(1, {:write, 10})

    simulator =
      Simulator.new(seed: 104)
      |> Simulator.submit_client_request(1, request)
      |> deliver_payload(Prepare, 2)
      |> deliver_payload(PrepareOk, 1)

    assert [%ClientReply{}] = Simulator.messages(simulator, &match?(%ClientReply{}, &1))

    simulator =
      simulator
      |> Simulator.drop_message(&match?(%ClientReply{}, &1))
      |> Simulator.submit_client_request(1, request)
      |> Simulator.deliver_all()

    assert Enum.count(simulator.history, &(&1.type == :retry)) == 1
    assert Enum.count(simulator.history, &(&1.type == :complete)) == 1

    assert Enum.all?(simulator.applied_history, fn {_replica_id, applied} ->
             length(applied) == 1
           end)

    assert Linearizability.linearizable?(simulator.history)
  end

  test "duplicated and reordered prepares preserve one committed prefix" do
    simulator =
      Simulator.new(seed: 105)
      |> Simulator.submit_client_request(1, request(1, {:write, 10}))
      |> Simulator.duplicate_message(&(payload?(&1, Prepare) and &1.to == 2))
      |> deliver_payload(Prepare, 3)
      |> deliver_payload(PrepareOk, 1)
      |> Simulator.deliver_all()

    assert Enum.all?(simulator.replicas, fn {_id, state} ->
             state.commit_number == 1 and state.applied_number == 1
           end)

    assert Enum.all?(simulator.applied_history, fn {_replica_id, applied} ->
             length(applied) == 1
           end)
  end

  test "two backups independently start a view change and the majority installs view one" do
    simulator =
      Simulator.new(seed: 106)
      |> Simulator.partition(1, [2, 3])
      |> put_primary_timer(2)
      |> put_primary_timer(3)
      |> Simulator.fire_timer(2, :primary)
      |> Simulator.fire_timer(3, :primary)
      |> Simulator.deliver_all()

    assert simulator.replicas[2].status == :normal
    assert simulator.replicas[2].view_number == 1
    assert simulator.replicas[3].status == :normal
    assert simulator.replicas[3].view_number == 1

    assert Enum.any?(simulator.history, fn
             %{type: :message_delivered, envelope: %Envelope{payload: %StartView{}}} -> true
             _event -> false
           end)

    healed =
      simulator
      |> Simulator.heal_partition()
      |> Simulator.deliver_all()

    assert healed.replicas[1].status == :normal
    assert healed.replicas[1].view_number == 1
  end

  test "a primary crash after one prepare cannot commit that operation without a quorum" do
    simulator =
      Simulator.new(seed: 107)
      |> Simulator.submit_client_request(1, request(1, {:write, 10}))
      |> deliver_payload(Prepare, 2)
      |> Simulator.crash_replica(1)
      |> Simulator.drop_message(&payload?(&1, PrepareOk))
      |> Simulator.deliver_all()

    assert simulator.replicas[1].commit_number == 0
    assert simulator.replicas[2].commit_number == 0
    assert simulator.replicas[3].commit_number == 0
    refute Enum.any?(simulator.history, &(&1.type == :complete))
  end

  test "a primary crash before request handling sends no prepare" do
    simulator =
      Simulator.new(seed: 112)
      |> Simulator.crash_replica(1)
      |> Simulator.submit_client_request(1, request(1, {:write, 10}))

    refute Enum.any?(Simulator.messages(simulator), &payload?(&1, Prepare))
    assert simulator.replicas[1].op_number == 0
    assert simulator.replicas[1].commit_number == 0
  end

  test "a primary failure after quorum commit is answered from the deduplication cache" do
    request = request(1, {:write, 10})

    simulator =
      Simulator.new(seed: 108)
      |> Simulator.submit_client_request(1, request)
      |> deliver_payload(Prepare, 2)
      |> deliver_payload(PrepareOk, 1)
      |> Simulator.drop_message(&match?(%ClientReply{}, &1))
      |> Simulator.crash_replica(1)
      |> Simulator.deliver_all()
      |> Simulator.fire_timer(2, :primary)
      |> Simulator.fire_timer(3, :primary)
      |> Simulator.deliver_all()
      |> Simulator.submit_client_request(2, request)
      |> Simulator.deliver_all()

    assert simulator.replicas[2].view_number == 1
    assert simulator.replicas[2].client_table[:client].status == :applied
    assert Enum.count(simulator.history, &(&1.type == :complete)) == 1
    assert Linearizability.linearizable?(simulator.history)

    assert Enum.all?(simulator.applied_history, fn {_replica_id, applied} ->
             length(applied) == 1
           end)
  end

  test "a recovering empty replica catches up from the current primary" do
    simulator =
      Simulator.new(seed: 109)
      |> Simulator.submit_client_request(1, request(1, {:write, 10}))
      |> Simulator.deliver_all()
      |> Simulator.crash_replica(3)
      |> Simulator.restart_replica(3)
      |> Simulator.recover_storage(3, {:empty, :recovery_109})

    assert simulator.replicas[3].status == :recovering
    assert Enum.any?(Simulator.messages(simulator), &payload?(&1, Recovery))

    recovered = Simulator.deliver_all(simulator)

    assert recovered.replicas[3].status == :normal
    assert recovered.replicas[3].commit_number == 1
    assert recovered.replicas[3].applied_number == 1
    assert recovered.machine_states[3] == 10
  end

  test "a recovering replica restores a snapshot before applying its log suffix" do
    simulator =
      Simulator.new(seed: 113)
      |> Simulator.submit_client_request(1, request(1, {:write, 10}))
      |> Simulator.deliver_all()
      |> Simulator.complete_snapshot(1, 1, 10)
      |> Simulator.submit_client_request(1, request(2, {:write, 20}))
      |> Simulator.deliver_all()
      |> Simulator.crash_replica(3)
      |> Simulator.restart_replica(3)
      |> Simulator.recover_storage(3, {:empty, :snapshot_recovery_113})
      |> Simulator.deliver_all()

    assert simulator.replicas[3].status == :normal
    assert simulator.replicas[3].log.base_op_number == 1
    assert simulator.replicas[3].snapshot_op_number == 1
    assert simulator.replicas[3].applied_number == 2
    assert simulator.machine_states[3] == 20

    snapshot_step =
      Enum.find_value(simulator.history, fn
        %{type: :snapshot_installed, replica_id: 3, step: step} -> step
        _event -> nil
      end)

    suffix_apply_step =
      simulator.history
      |> Enum.reverse()
      |> Enum.find_value(fn
        %{type: :state_machine_applied, replica_id: 3, entry: %{op_number: 2}, step: step} ->
          step

        _event ->
          nil
      end)

    assert is_integer(snapshot_step)
    assert is_integer(suffix_apply_step)
    assert snapshot_step < suffix_apply_step
  end

  test "a prospective primary failure advances the surviving majority to the next view" do
    simulator =
      Simulator.new(seed: 110)
      |> put_primary_timer(2)
      |> put_primary_timer(3)
      |> Simulator.fire_timer(2, :primary)
      |> Simulator.fire_timer(3, :primary)
      |> Simulator.crash_replica(2)
      |> Simulator.deliver_message(
        &(payload?(&1, StartViewChange) and &1.from == 2 and &1.to == 3)
      )
      |> Simulator.fire_timer(3, :view_change)
      |> Simulator.deliver_all()

    assert simulator.replicas[3].status == :normal
    assert simulator.replicas[3].view_number == 2
    assert simulator.replicas[1].status == :normal
    assert simulator.replicas[1].view_number == 2
  end

  test "an out-of-order prepare requests the missing state without appending a gap" do
    simulator = Simulator.new(seed: 111)

    entry = %LogEntry{
      view_number: 0,
      op_number: 2,
      client_id: :client,
      request_number: 2,
      operation: {:write, 20}
    }

    envelope = %Envelope{
      group_id: :test_group,
      configuration_hash:
        ViewstampedReplication.Configuration.hash(simulator.replicas[1].configuration),
      from: 1,
      payload: %Prepare{
        view_number: 0,
        op_number: 2,
        commit_number: 0,
        entry: entry
      }
    }

    message = %Message{id: 1, from: 1, to: 2, envelope: envelope}

    simulator =
      %{simulator | message_queue: [message], next_id: 2}
      |> Simulator.deliver_message(1)

    assert simulator.replicas[2].op_number == 0
    assert Enum.any?(Simulator.messages(simulator), &payload?(&1, GetState))

    assert Enum.any?(simulator.history, fn
             %{type: :effect, effect: {:request_state_transfer, 1, 1..2//1}} -> true
             _event -> false
           end)
  end

  test "a small gap transfers and merges only the missing log suffix" do
    simulator =
      Simulator.new(seed: 114)
      |> Simulator.submit_client_request(1, request(1, {:write, 10}))
      |> Simulator.deliver_all()
      |> Simulator.submit_client_request(1, request(2, {:write, 20}))
      |> Simulator.drop_message(&(payload?(&1, Prepare) and &1.to == 3))
      |> deliver_payload(Prepare, 2)
      |> deliver_payload(PrepareOk, 1)
      |> Simulator.drop_message(&(payload?(&1, Commit) and &1.to == 3))
      |> Simulator.deliver_all()
      |> Simulator.submit_client_request(1, request(3, {:write, 30}))
      |> deliver_payload(Prepare, 3)
      |> deliver_payload(GetState, 1)

    assert [
             %Message{
               envelope: %Envelope{
                 payload: %NewState{
                   snapshot: nil,
                   log: %{base_op_number: 1, entries: [second, third]}
                 }
               }
             }
           ] = Simulator.messages(simulator, &payload?(&1, NewState))

    assert second.op_number == 2
    assert third.op_number == 3

    caught_up =
      simulator
      |> deliver_payload(NewState, 3)
      |> Simulator.deliver_all()

    assert caught_up.replicas[3].log.base_op_number == 0
    assert caught_up.replicas[3].op_number == 3
    assert caught_up.replicas[3].commit_number == 3
    assert caught_up.replicas[3].applied_number == 3
    assert caught_up.machine_states[3] == 30
  end

  property "loss, duplication, delay, and reordering preserve simulator safety" do
    check all(
            actions <-
              list_of(member_of([:deliver, :drop, :duplicate, :delay]), max_length: 50)
          ) do
      simulator =
        Simulator.new(seed: :erlang.phash2(actions))
        |> Simulator.submit_client_request(1, request(1, {:write, 10}))

      final =
        Enum.reduce(actions, simulator, fn
          :deliver, acc -> Simulator.deliver_message(acc)
          :drop, acc -> Simulator.drop_message(acc)
          :duplicate, acc -> Simulator.duplicate_message(acc)
          :delay, acc -> Simulator.delay_message(acc, 1)
        end)

      assert final == Simulator.assert_safety!(final)
    end
  end

  defp request(request_number, operation) do
    %Request{
      client_id: :client,
      request_number: request_number,
      operation: operation
    }
  end

  defp deliver_payload(simulator, module, destination) do
    Simulator.deliver_message(
      simulator,
      &(payload?(&1, module) and &1.to == destination)
    )
  end

  defp payload?(%Message{envelope: %Envelope{payload: payload}}, module),
    do: payload.__struct__ == module

  defp payload?(_message, _module), do: false

  defp put_primary_timer(simulator, replica_id) do
    token = {:simulated_primary_timeout, replica_id}
    timer_id = simulator.next_id
    state = Map.fetch!(simulator.replicas, replica_id)

    timer = %Timer{
      id: timer_id,
      replica_id: replica_id,
      kind: :primary,
      token: token,
      timeout: 0
    }

    %{
      simulator
      | replicas:
          Map.put(
            simulator.replicas,
            replica_id,
            %{state | timer_tokens: Map.put(state.timer_tokens, :primary, token)}
          ),
        timer_queue: simulator.timer_queue ++ [timer],
        next_id: timer_id + 1
    }
  end
end
