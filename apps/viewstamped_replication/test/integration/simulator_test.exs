defmodule ViewstampedReplication.Test.SimulatorTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Log, LogEntry, Request}
  alias ViewstampedReplication.Protocol.{Commit, Envelope}
  alias ViewstampedReplication.Test.Simulator
  alias ViewstampedReplication.Test.Simulator.{Message, Timer}

  test "deterministically drops, duplicates, and delays queued messages" do
    simulator = with_messages(Simulator.new(seed: 41), [message(1, 1, 2), message(2, 1, 3)])

    duplicated = Simulator.duplicate_message(simulator, 1)
    assert [%Message{id: 1}, %Message{id: 2}, %Message{id: copy_id}] = duplicated.message_queue
    assert copy_id > 2

    delayed = Simulator.delay_message(duplicated, 2, 50)
    assert %Message{delay: 50} = Enum.find(delayed.message_queue, &(&1.id == 2))
    assert Enum.any?(Simulator.deliver_all(delayed).message_queue, &(&1.id == 2))

    dropped = Simulator.drop_message(delayed, 1)
    refute Enum.any?(dropped.message_queue, &(&1.id == 1))
    assert Enum.any?(dropped.history, &(&1.type == :message_dropped))
  end

  test "a partition blocks delivery until it is healed" do
    simulator =
      Simulator.new(seed: 42)
      |> with_messages([message(1, 1, 2)])
      |> Simulator.partition(1, [2, 3])
      |> Simulator.deliver_message(1)

    assert [%Message{id: 1}] = simulator.message_queue
    assert %{type: :message_blocked, seed: 42} = List.last(simulator.history)

    healed =
      simulator
      |> Simulator.heal_partition(1, [2, 3])
      |> Simulator.deliver_message(1)

    assert [] = healed.message_queue
    assert Enum.any?(healed.history, &(&1.type == :message_delivered))
  end

  test "crashed replicas ignore client events and resume after restart" do
    request = %Request{client_id: :client, request_number: 1, operation: {:write, 10}}

    crashed =
      Simulator.new(seed: 43)
      |> Simulator.crash_replica(1)
      |> Simulator.submit_client_request(1, request)

    assert MapSet.member?(crashed.crashed, 1)
    assert Enum.any?(crashed.history, &(&1.type == :event_ignored_crashed))

    restarted = Simulator.restart_replica(crashed, 1)
    refute MapSet.member?(restarted.crashed, 1)
    assert restarted.replicas[1].status == :recovering
  end

  test "fires the exact timer token emitted into the timer queue" do
    simulator = Simulator.new(seed: 44)
    timer = %Timer{id: 99, replica_id: 2, kind: :view_change, token: make_ref(), timeout: 10}
    simulator = %{simulator | timer_queue: [timer]}

    fired = Simulator.fire_timer(simulator, 2, :view_change)

    assert [] = fired.timer_queue

    assert Enum.any?(fired.history, fn
             %{type: :timer_fired, timer_id: 99, token: token} -> token == timer.token
             _event -> false
           end)
  end

  test "cluster safety assertions include the reproducible seed" do
    simulator = Simulator.new(seed: 45)
    first = entry(1, {:write, :first})
    conflicting = entry(1, {:write, :conflicting})

    replicas =
      simulator.replicas
      |> Map.update!(1, &committed(&1, first))
      |> Map.update!(2, &committed(&1, conflicting))

    assert_raise RuntimeError, ~r/seed=45.*distinct committed operations/s, fn ->
      Simulator.assert_safety!(%{simulator | replicas: replicas})
    end
  end

  test "cluster safety rejects a normal primary commit without quorum evidence" do
    simulator = Simulator.new(seed: 46)

    unsafe_history = [
      %{
        type: :normal_commit,
        acknowledgers: MapSet.new([1]),
        quorum_size: 2
      }
    ]

    assert_raise RuntimeError, ~r/seed=46.*committed without a quorum/s, fn ->
      Simulator.assert_safety!(%{simulator | history: unsafe_history})
    end
  end

  test "cluster safety rejects different snapshots at one operation" do
    simulator = Simulator.new(seed: 47)
    entry = entry(1, {:write, :value})

    replicas =
      simulator.replicas
      |> Map.update!(1, &snapshotted(&1, entry, :first_snapshot))
      |> Map.update!(2, &snapshotted(&1, entry, :conflicting_snapshot))

    assert_raise RuntimeError, ~r/seed=47.*different snapshots at operation 1/s, fn ->
      Simulator.assert_safety!(%{simulator | replicas: replicas})
    end
  end

  defp with_messages(simulator, messages), do: %{simulator | message_queue: messages, next_id: 3}

  defp message(id, from, to) do
    configuration_hash =
      Simulator.new()
      |> Map.fetch!(:replicas)
      |> Map.fetch!(from)
      |> Map.fetch!(:configuration)
      |> ViewstampedReplication.Configuration.hash()

    envelope = %Envelope{
      group_id: :test_group,
      configuration_hash: configuration_hash,
      from: from,
      payload: %Commit{view_number: 0, commit_number: 0}
    }

    %Message{id: id, from: from, to: to, envelope: envelope}
  end

  defp entry(op_number, operation) do
    %LogEntry{
      view_number: 0,
      op_number: op_number,
      client_id: {:client, operation},
      request_number: 1,
      operation: operation
    }
  end

  defp committed(state, entry) do
    %{state | log: Log.append!(state.log, entry), op_number: 1, commit_number: 1}
  end

  defp snapshotted(state, entry, snapshot) do
    state = %{committed(state, entry) | applied_number: 1}
    {:ok, compacted_log} = Log.compact(state.log, 1)
    %{state | log: compacted_log, snapshot: snapshot, snapshot_op_number: 1}
  end
end
