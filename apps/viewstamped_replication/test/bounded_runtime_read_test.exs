defmodule ViewstampedReplication.BoundedRuntimeReadTest do
  use ExUnit.Case, async: false

  alias ViewstampedReplication.{Client, Configuration, Log, Member, Protocol, Replica}

  defmodule MapStateMachine do
    @behaviour ViewstampedReplication.StateMachine

    @impl true
    def init(_opts), do: %{}

    @impl true
    def apply(_metadata, {:put, key, value}, state), do: {:ok, Map.put(state, key, value)}

    @impl true
    def read(_metadata, {:get, key}, state), do: Map.fetch(state, key)

    @impl true
    def snapshot(state), do: {:ok, state}

    @impl true
    def restore(state), do: {:ok, state}
  end

  test "public singleton reads visit no retained history after ordinary writes" do
    configuration = configuration(1)
    replica = start_replica(configuration, true)
    writer = start_writer(configuration)

    rows =
      for {first, last} <- [{1, 128}, {129, 2_048}] do
        for _number <- first..last do
          assert {:ok, :ok} =
                   ViewstampedReplication.command(configuration.group_id, {:put, :key, :value},
                     client: writer
                   )
        end

        before_read = :sys.get_state(replica)

        {samples, protocol_reads} =
          trace_protocol_reads(replica, fn ->
            for _repetition <- 1..5 do
              {:reductions, before_count} = Process.info(replica, :reductions)
              assert read(configuration) == {:ok, {:ok, :value}}
              {:reductions, after_count} = Process.info(replica, :reductions)
              after_count - before_count
            end
          end)

        after_read = :sys.get_state(replica)
        assert before_read.protocol_state.log === after_read.protocol_state.log
        assert before_read.protocol_state.client_table === after_read.protocol_state.client_table
        assert before_read.state_machine_state === after_read.state_machine_state
        assert after_read.state_machine_state == %{key: :value}
        assert after_read.protocol_state.op_number == last
        assert after_read.protocol_state.commit_number == last
        assert after_read.protocol_state.applied_number == last
        assert after_read.protocol_state.log.base_op_number == 0
        assert length(Log.to_list(after_read.protocol_state.log)) == last

        %{entries: last, reductions: Enum.sort(samples), protocol_reads: protocol_reads}
      end

    assert Enum.all?(rows, &(&1.protocol_reads == 0)), inspect(rows)
    [%{reductions: [_, _, small, _, _]}, %{reductions: [_, _, large, _, _]}] = rows
    assert large < small * 3 + 1_000, inspect(rows)
  end

  test "recovering replicas retain the validated protocol read path" do
    configuration = configuration(3)
    replica = start_replica(configuration, false)
    assert {:ok, %{status: :recovering}} = Replica.status(configuration.group_id, 1)

    {result, calls} = trace_protocol_reads(replica, fn -> read(configuration) end)
    assert result == {:error, :recovering}
    assert calls == 1
  end

  test "multi-member reads retain the validated quorum path" do
    configuration = configuration(3)
    replica = start_replica(configuration, true)

    for member <- tl(configuration.members) do
      start_replica(%{configuration | replica_id: member.id}, true)
    end

    writer = start_writer(configuration)

    assert {:ok, :ok} =
             ViewstampedReplication.command(configuration.group_id, {:put, :key, :value},
               client: writer
             )

    {result, calls} = trace_protocol_reads(replica, fn -> read(configuration) end)
    assert result == {:ok, {:ok, :value}}
    assert calls == 1
  end

  defp trace_protocol_reads(replica, operation) do
    {:module, :trace} = Code.ensure_loaded(:trace)
    session = :trace.session_create(:bounded_runtime_read, self(), [])
    mfa = {Protocol, :step, 2}
    match = [{[:_, {:read_request, :_, :_}], [], []}]

    try do
      1 = :trace.function(session, mfa, match, [:local])
      1 = :trace.process(session, replica, true, [:call, :arity])
      result = operation.()
      reference = :trace.delivered(session, replica)
      assert_receive {:trace_delivered, ^replica, ^reference}
      {result, take_protocol_reads(replica, 0)}
    after
      try do
        1 = :trace.process(session, replica, false, [:call, :arity])
        1 = :trace.function(session, mfa, false, [:local])
        assert {:flags, []} = :trace.info(session, replica, :flags)
      after
        true = :trace.session_destroy(session)
      end
    end
  end

  defp take_protocol_reads(replica, count) do
    receive do
      {:trace, ^replica, :call, {Protocol, :step, 2}} ->
        take_protocol_reads(replica, count + 1)
    after
      0 -> count
    end
  end

  defp configuration(count) do
    group_id = {:bounded_runtime_read, System.unique_integer([:positive])}

    members =
      for id <- 1..count do
        %Member{id: id, endpoint: {:local, group_id, id}}
      end

    Configuration.new!(group_id: group_id, replica_id: 1, members: members)
  end

  defp start_replica(configuration, bootstrap) do
    start_supervised!(
      {Replica,
       configuration: configuration, state_machine: MapStateMachine, bootstrap: bootstrap}
    )
  end

  defp start_writer(configuration) do
    start_supervised!(
      {Client,
       group_id: configuration.group_id, client_id: :writer, replicas: configuration.members}
    )
  end

  defp read(configuration) do
    ViewstampedReplication.read(configuration.group_id, {:get, :key},
      replica_id: 1,
      replicas: configuration.members
    )
  end
end
