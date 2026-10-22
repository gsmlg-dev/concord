defmodule ViewstampedReplication.BoundedRuntimeWriteTest do
  use ExUnit.Case, async: false

  alias ViewstampedReplication.{Configuration, Log, Member, Protocol, Replica, Reply, Request}

  defmodule MapStateMachine do
    @behaviour ViewstampedReplication.StateMachine

    @impl true
    def init(_opts), do: %{}

    @impl true
    def apply(_metadata, {:put, key, value}, state), do: {:ok, Map.put(state, key, value)}

    @impl true
    def snapshot(state), do: {:ok, state}

    @impl true
    def restore(state), do: {:ok, state}
  end

  test "ordinary singleton writes preserve all history without revisiting unrelated entries" do
    configuration = configuration()

    replica =
      start_supervised!(
        {Replica, configuration: configuration, state_machine: MapStateMachine, bootstrap: true}
      )

    assert {:ok, %{status: :normal}} = Replica.status(configuration.group_id, 1)

    {rows, _last} =
      Enum.map_reduce([1_000, 2_000, 4_000], 0, fn count, previous ->
        for number <- (previous + 1)..count, do: write(replica, number)

        samples =
          for number <- (count + 1)..(count + 30) do
            {:reductions, before_count} = Process.info(replica, :reductions)
            write(replica, number)
            {:reductions, after_count} = Process.info(replica, :reductions)
            after_count - before_count
          end

        last = count + 31
        calls = trace_write(replica, last)
        runtime = :sys.get_state(replica)
        protocol = runtime.protocol_state
        assert protocol.op_number == last
        assert protocol.commit_number == last
        assert protocol.applied_number == last
        assert protocol.applying_number == nil
        assert protocol.log.base_op_number == 0
        assert length(Log.to_list(protocol.log)) == last
        assert length(Log.to_list(runtime.storage_state.log)) == last
        assert runtime.state_machine_state == %{key: :value}
        assert Protocol.assert_invariants!(protocol) == protocol

        write(replica, last)
        retry = :sys.get_state(replica)
        assert retry.protocol_state.log === protocol.log
        assert retry.protocol_state.applied_number == last

        {%{entries: count, reductions: Enum.sort(samples), history_calls: calls}, last}
      end)

    assert Enum.all?(rows, &Enum.all?(&1.history_calls, fn {_function, count} -> count == 0 end)),
           inspect(rows)

    [small, _middle, large] = rows

    assert Enum.at(large.reductions, 15) < Enum.at(small.reductions, 15) * 3 + 1_000,
           inspect(rows)
  end

  defp trace_write(replica, number) do
    {:module, :trace} = Code.ensure_loaded(:trace)
    session = :trace.session_create(:bounded_runtime_write, self(), [])

    functions = [
      {Protocol, :step, 2},
      {Protocol, :assert_invariants!, 1},
      {Protocol, :index_applied_requests, 3},
      {Protocol, :retained_prefix_mismatch, 4},
      {Log, :canonical, 1}
    ]

    try do
      for mfa <- functions, do: 1 = :trace.function(session, mfa, true, [:local])
      1 = :trace.process(session, replica, true, [:call, :arity])
      write(replica, number)
      reference = :trace.delivered(session, replica)
      assert_receive {:trace_delivered, ^replica, ^reference}
      take_calls(replica, Map.new(functions, &{&1, 0}))
    after
      try do
        1 = :trace.process(session, replica, false, [:call, :arity])
        for mfa <- functions, do: 1 = :trace.function(session, mfa, false, [:local])
        assert {:flags, []} = :trace.info(session, replica, :flags)
      after
        true = :trace.session_destroy(session)
      end
    end
  end

  defp take_calls(replica, calls) do
    receive do
      {:trace, ^replica, :call, mfa} -> take_calls(replica, Map.update!(calls, mfa, &(&1 + 1)))
    after
      0 -> calls
    end
  end

  defp write(replica, number) do
    reference = make_ref()

    request = %Request{
      client_id: :stable_writer,
      request_number: number,
      operation: {:put, :key, :value}
    }

    assert :ok = Replica.submit(replica, {self(), reference}, request)
    assert_receive {^reference, %Reply{request_number: ^number, result: :ok}}
    assert {:ok, _status} = GenServer.call(replica, :status)
  end

  defp configuration do
    Configuration.new!(
      group_id: {:bounded_runtime_write, System.unique_integer([:positive])},
      replica_id: 1,
      members: [%Member{id: 1, endpoint: :local_write}]
    )
  end
end
