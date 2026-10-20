defmodule ViewstampedReplication.Protocol.BoundedReadTest do
  use ExUnit.Case, async: false

  alias ViewstampedReplication.{Configuration, Log, LogEntry, Member, Protocol, Request}
  alias ViewstampedReplication.Protocol.{Envelope, GetState, State}

  @read {:read_request, :route, {:get, :key}}

  test "storage recovery derives an index and singleton reads preserve the exact state and effects" do
    state = recovered_state(4)
    assert state.applied_request_index == %{writer: %{1 => 1, 2 => 2, 3 => 3, 4 => 4}}
    assert_read(state)
    assert Protocol.assert_invariants!(state) === state
    assert Protocol.assert_transition!(state, state) === state
  end

  test "missing, malformed, or stale metadata falls back without changing valid states" do
    state = recovered_state(4)

    for index <- [nil, :invalid, [], %{}, %{writer: nil}, %{writer: %{1 => 3}}] do
      candidate = %{state | applied_request_index: index}
      assert_read(candidate)
      assert Protocol.assert_invariants!(candidate) === candidate
      assert Protocol.assert_transition!(candidate, candidate) === candidate
    end

    assert_read(Map.delete(state, :applied_request_index))
  end

  test "copied states and valid index supersets are rechecked without requiring provenance" do
    state = recovered_state(4)
    index = Map.put(state.applied_request_index, :unused, %{999 => 999})
    state = %{state | applied_request_index: index}
    copied = state |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    assert copied === state
    assert_read(copied)
    assert Protocol.assert_invariants!(copied) === copied
  end

  test "numeric client and request map keys retain exact equality semantics" do
    state = recovered_state(4)
    [first, second, third, fourth] = state.log.entries

    entries = [
      %{first | client_id: 1, request_number: 1},
      %{second | client_id: 1.0, request_number: 1},
      %{third | client_id: 1, request_number: 1.0},
      %{fourth | client_id: 1.0, request_number: 1.0}
    ]

    index = %{1 => %{1 => 1, 1.0 => 3}, 1.0 => %{1 => 2, 1.0 => 4}}
    state = %{state | log: %{state.log | entries: entries}, applied_request_index: index}
    assert_read(state)
    assert_read(%{state | applied_request_index: nil})

    [first, second, third, fourth] = entries
    entries = [first, second, third, %{fourth | client_id: 1, request_number: 1}]
    invalid = %{state | log: %{state.log | entries: entries}}

    assert_raise ArgumentError, ~r/client_request_applied_more_than_once/, fn ->
      Protocol.step(invalid, @read)
    end
  end

  test "nonadjacent duplicates fail with either coordinated index position" do
    state = recovered_state(4)
    [first, second, third, fourth] = state.log.entries
    log = %{state.log | entries: [first, second, third, %{fourth | request_number: 1}]}

    for position <- [1, 4] do
      invalid = %{
        state
        | log: log,
          applied_request_index: %{writer: %{1 => position, 2 => 2, 3 => 3}}
      }

      assert_raise ArgumentError, ~r/client_request_applied_more_than_once/, fn ->
        Protocol.step(invalid, @read)
      end
    end
  end

  test "uniqueness covers only the retained applied prefix across compaction boundaries" do
    state = recovered_state(4)
    [first, second, third, fourth] = state.log.entries
    log = %{state.log | entries: [first, second, third, %{fourth | request_number: 3}]}

    pending = %{
      state
      | log: log,
        commit_number: 3,
        applied_number: 3,
        applied_request_index: %{writer: %{1 => 1, 2 => 2, 3 => 3}}
    }

    # An unapplied duplicate does not invalidate the already-applied prefix.
    assert_read(pending)
    committing = %{pending | commit_number: 4, applying_number: 4}

    assert_raise ArgumentError, ~r/client_request_applied_more_than_once/, fn ->
      Protocol.step(committing, {:state_machine_applied, 4, :ok})
    end

    snapshot = %{last_op_number: 3, state_machine: :snapshot}
    {compacted, _effects} = Protocol.step(pending, {:snapshot_completed, 3, snapshot})
    assert compacted.applied_request_index == %{}
    assert_read(compacted)

    # The canonical contract excludes compacted entries from this check.
    committing = %{compacted | commit_number: 4, applying_number: 4}
    {applied, _effects} = Protocol.step(committing, {:state_machine_applied, 4, :ok})
    assert applied.applied_request_index == %{writer: %{3 => 4}}
    assert_read(applied)
  end

  test "coordinated log and index tampering cannot hide duplicate applied requests" do
    state = recovered_state(4)
    [first, second | rest] = state.log.entries
    log = %{state.log | entries: [first, %{second | request_number: first.request_number} | rest]}

    for index <- [nil, %{}, state.applied_request_index, %{writer: %{1 => 2, 3 => 3, 4 => 4}}] do
      invalid = %{state | log: log, applied_request_index: index}

      for check <- [
            fn -> Protocol.step(invalid, @read) end,
            fn -> Protocol.assert_invariants!(invalid) end,
            fn -> Protocol.assert_transition!(invalid, invalid) end
          ] do
        assert_raise ArgumentError, ~r/client_request_applied_more_than_once/, check
      end
    end
  end

  test "ready singleton reads retain every structural input check" do
    state = recovered_state(4)
    [first, second, third, fourth] = state.log.entries
    rest = [third, fourth]

    for {invalid, error} <- [
          {%{state | status: :invalid}, "invalid_status"},
          {%{state | view_number: -1}, "view_number"},
          {%{state | last_normal_view: 1}, "last_normal_view_ahead"},
          {%{state | applied_number: 5}, "invalid_operation_numbers"},
          {%{state | op_number: 5}, "log_op_number_mismatch"},
          {%{state | snapshot_op_number: 1}, "log_snapshot_mismatch"},
          {%{state | applying_number: 2}, "invalid_applying_number"},
          {%{state | log: %{state.log | entries: [first, second, third]}},
           "log_op_number_mismatch"},
          {%{state | log: %{state.log | entries: [first, third, fourth]}}, "non_contiguous_log"},
          {%{
             state
             | log: %{state.log | entries: [first, second, third, %{fourth | op_number: 5}]}
           }, "log_op_number_mismatch"},
          {%{state | log: %{state.log | entries: [first, %{second | op_number: 3} | rest]}},
           "non_contiguous_log"}
        ] do
      assert_raise ArgumentError, ~r/#{error}/, fn -> Protocol.step(invalid, @read) end
    end
  end

  test "append, apply, compaction and restart maintain only the retained applied index" do
    state = recovered_state(2)
    request = %Request{client_id: :writer, request_number: 3, operation: {:put, :key, :value}}
    {pending, effects} = Protocol.step(state, {:client_request, :write_route, request})
    assert pending.applying_number == 3
    assert pending.applied_request_index == state.applied_request_index
    assert Enum.any?(effects, &match?({:apply, %LogEntry{op_number: 3}}, &1))

    {applied, _effects} = Protocol.step(pending, {:state_machine_applied, 3, :ok})
    assert applied.applied_request_index == %{writer: %{1 => 1, 2 => 2, 3 => 3}}
    assert_read(applied)

    snapshot = %{last_op_number: 2, state_machine: :snapshot}

    assert {compacted, [{:persist, {:install_snapshot_state, ^snapshot, persisted}}]} =
             Protocol.step(applied, {:snapshot_completed, 2, snapshot})

    assert compacted.applied_request_index == %{writer: %{3 => 3}}
    refute Map.has_key?(persisted, :applied_request_index)
    assert_read(compacted)

    {restarted, _effects} =
      Protocol.step(State.new(state.configuration), {
        :storage_recovered,
        Map.merge(persisted, %{
          replica_id: :replica,
          hard_state: %{view_number: 0, last_normal_view: 0, status: :normal},
          # Durable/wire metadata must never be treated as a certificate.
          applied_request_index: %{writer: %{3 => :forged}}
        })
      })

    assert restarted.applied_request_index == compacted.applied_request_index
    assert_read(restarted)
  end

  test "peer snapshot installation rebuilds the index without transferring derived metadata" do
    members = [%Member{id: :replica, endpoint: :first}, %Member{id: :backup, endpoint: :second}]
    state = recovered_state(3)
    primary_configuration = %{state.configuration | members: members}
    primary = %{state | configuration: primary_configuration}
    snapshot = %{last_op_number: 2, state_machine: :snapshot}
    {primary, _effects} = Protocol.step(primary, {:snapshot_completed, 2, snapshot})

    request = %GetState{view_number: 0, from_op_number: 1}
    assert {^primary, [{:send, :backup, transfer}]} = peer_step(primary, :backup, request)
    refute Map.has_key?(transfer.payload, :applied_request_index)

    backup_configuration = %{primary_configuration | replica_id: :backup}
    backup = State.new(backup_configuration)
    {installed, effects} = Protocol.step(backup, {:peer_message, :replica, transfer})
    assert installed.applied_number == 2
    assert installed.applying_number == 3
    assert installed.applied_request_index == %{}

    assert [{:persist, {:install_snapshot_state, ^snapshot, persisted}} | _] = effects
    refute Map.has_key?(persisted, :applied_request_index)

    {applied, _effects} = Protocol.step(installed, {:state_machine_applied, 3, :ok})
    assert applied.applied_request_index == %{writer: %{3 => 3}}
    assert Protocol.assert_invariants!(applied) === applied
  end

  test "storage recovery cannot certify duplicate requests with supplied index metadata" do
    state = recovered_state(2)
    [first, second] = state.log.entries

    recovered = %{
      replica_id: :replica,
      log: %{state.log | entries: [first, %{second | request_number: 1}]},
      commit_number: 2,
      applied_number: 2,
      client_table: state.client_table,
      hard_state: %{view_number: 0, last_normal_view: 0, status: :normal},
      applied_request_index: %{writer: %{1 => 2}}
    }

    assert_raise ArgumentError, ~r/client_request_applied_more_than_once/, fn ->
      Protocol.step(State.new(state.configuration), {:storage_recovered, recovered})
    end
  end

  test "public transition checks still reject committed replacement with matching derived metadata" do
    state = recovered_state(2)
    [first, second] = state.log.entries
    changed = %{first | client_id: :other}

    candidate = %{
      state
      | log: %{state.log | entries: [changed, second]},
        applied_request_index: %{other: %{1 => 1}, writer: %{2 => 2}}
    }

    assert_raise ArgumentError, ~r/committed_entry_replaced/, fn ->
      Protocol.assert_transition!(state, candidate)
    end
  end

  test "whole singleton read allocation stays bounded as retained history grows" do
    fixtures = Enum.map([1_000, 2_000, 4_000], &recovered_state/1)
    Enum.each(fixtures, &assert_read/1)
    samples = read_allocations(fixtures)

    # Whole step/2, including all invariant checks and untraced callees. This
    # bounds process-heap allocation, not CPU, retained index memory, or latency.
    assert Enum.max(samples) <= 1_024
    assert Enum.max(samples) - Enum.min(samples) <= 128
  end

  defp peer_step(state, sender, payload) do
    envelope = %Envelope{
      group_id: state.group_id,
      configuration_hash: Configuration.hash(state.configuration),
      from: sender,
      payload: payload
    }

    Protocol.step(state, {:peer_message, sender, envelope})
  end

  defp assert_read(state) do
    assert Protocol.step(state, @read) === {state, [{:read, :route, {:get, :key}}]}
  end

  defp recovered_state(count) do
    configuration =
      Configuration.new!(
        group_id: :bounded_reads,
        replica_id: :replica,
        members: [%Member{id: :replica, endpoint: :fixture}]
      )

    entries =
      for number <- 1..count do
        %LogEntry{
          view_number: 0,
          op_number: number,
          client_id: :writer,
          request_number: number,
          operation: {:put, :key, :value}
        }
      end

    {state, _effects} =
      Protocol.step(State.new(configuration), {
        :storage_recovered,
        %{
          replica_id: :replica,
          log: %Log{entries: entries},
          commit_number: count,
          applied_number: count,
          client_table: %{writer: %{request_number: count, status: :applied, result: :ok}},
          hard_state: %{view_number: 0, last_normal_view: 0, status: :normal}
        }
      })

    state
  end

  defp read_allocations(fixtures) do
    {:module, :trace} = Code.ensure_loaded(:trace)
    owner = self()
    mfa = {Protocol, :step, 2}

    {tracer, monitor} =
      spawn_monitor(fn ->
        receive do
          :stop -> :ok
        end
      end)

    try do
      session = :trace.session_create(:bounded_read_allocation, tracer, [])

      try do
        1 = :trace.function(session, mfa, true, [:call_memory])
        1 = :trace.process(session, owner, true, [:call, :silent])

        for state <- fixtures, _repetition <- 1..5 do
          1 = :trace.function(session, mfa, :restart, [:call_memory])
          result = Protocol.step(state, @read)
          1 = :trace.function(session, mfa, :pause, [:call_memory])
          {:call_memory, [{^owner, 1, words}]} = :trace.info(session, mfa, :call_memory)
          assert result === {state, [{:read, :route, {:get, :key}}]}
          words
        end
      after
        try do
          1 = :trace.process(session, owner, false, [:call, :silent])
          1 = :trace.function(session, mfa, false, [:call_memory])
          assert {:flags, []} = :trace.info(session, owner, :flags)
          assert {:call_memory, false} = :trace.info(session, mfa, :call_memory)
        after
          true = :trace.session_destroy(session)
        end
      end
    after
      send(tracer, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^tracer, :normal}, 1_000
    end
  end
end
