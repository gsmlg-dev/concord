defmodule ViewstampedReplication.RuntimeWriteFailuresTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias ViewstampedReplication.{Configuration, Member, Replica, Reply, Request}
  alias ViewstampedReplication.Storage.Memory

  defmodule Storage do
    @behaviour ViewstampedReplication.Storage

    @impl true
    def open(opts) do
      with {:ok, memory} <- Memory.open(opts) do
        {:ok,
         %{memory: memory, owner: Keyword.fetch!(opts, :owner), fail: Keyword.get(opts, :fail)}}
      end
    end

    @impl true
    def recover(state) do
      with {:ok, recovered, memory} <- Memory.recover(state.memory),
           do: {:ok, recovered, %{state | memory: memory}}
    end

    @impl true
    def persist_hard_state(state, hard), do: delegate(state, :persist_hard_state, [hard])

    @impl true
    def append(state, entry), do: stage(state, :append, :append, [entry])

    @impl true
    def set_commit_number(state, number), do: stage(state, :commit, :set_commit_number, [number])

    @impl true
    def set_applied(state, number, clients),
      do: stage(state, :applied, :set_applied, [number, clients])

    @impl true
    def truncate_suffix(state, number), do: delegate(state, :truncate_suffix, [number])

    @impl true
    def write_snapshot(state, snapshot), do: delegate(state, :write_snapshot, [snapshot])

    @impl true
    def install_snapshot(state, snapshot), do: delegate(state, :install_snapshot, [snapshot])

    @impl true
    def install_snapshot_state(state, snapshot, durable),
      do: delegate(state, :install_snapshot_state, [snapshot, durable])

    @impl true
    def install_state(state, durable), do: delegate(state, :install_state, [durable])

    @impl true
    def close(_state), do: :ok

    defp stage(state, stage, function, args) do
      send(state.owner, {:stage, stage})

      if state.fail == stage,
        do: {:error, {:injected, stage}},
        else: delegate(state, function, args)
    end

    defp delegate(state, function, args) do
      with {:ok, memory} <- apply(Memory, function, [state.memory | args]),
           do: {:ok, %{state | memory: memory}}
    end
  end

  defmodule StateMachine do
    @behaviour ViewstampedReplication.StateMachine

    @impl true
    def init(opts), do: %{owner: Keyword.fetch!(opts, :owner), fail: Keyword.get(opts, :fail)}

    @impl true
    def apply(_metadata, :write, state) do
      send(state.owner, {:stage, :apply})
      if state.fail == :apply, do: raise("injected apply failure")
      {:ok, state}
    end

    @impl true
    def snapshot(state), do: {:ok, state}

    @impl true
    def restore(state), do: {:ok, state}
  end

  for {failure, expected} <- [
        append: [:append],
        commit: [:append, :commit],
        apply: [:append, :commit, :apply],
        applied: [:append, :commit, :apply, :applied]
      ] do
    @failure failure
    @expected expected
    test "#{failure} failure stops before a successful reply" do
      replica = replica(@failure)
      monitor = Process.monitor(replica)
      reference = make_ref()

      capture_log(fn ->
        assert :ok = Replica.submit(replica, {self(), reference}, request())
        assert_receive {:DOWN, ^monitor, :process, ^replica, _reason}
      end)

      for stage <- @expected, do: assert_receive({:stage, ^stage})
      refute_receive {:stage, _unexpected}
      refute_receive {^reference, %Reply{result: :ok}}
    end
  end

  test "success persists append, commit and applied result before replying" do
    replica = replica(nil)
    reference = make_ref()
    assert :ok = Replica.submit(replica, {self(), reference}, request())

    messages =
      for _number <- 1..5 do
        assert_receive message
        message
      end

    assert [
             {:stage, :append},
             {:stage, :commit},
             {:stage, :apply},
             {:stage, :applied},
             {^reference, %Reply{result: :ok}}
           ] = messages

    state = :sys.get_state(replica)
    assert state.storage_state.memory.applied_number == 1
    assert state.protocol_state.applied_number == 1
  end

  defp request, do: %Request{client_id: :writer, request_number: 1, operation: :write}

  defp replica(failure) do
    configuration =
      Configuration.new!(
        group_id: {:write_failure, System.unique_integer([:positive])},
        replica_id: 1,
        members: [%Member{id: 1, endpoint: :local_failure}]
      )

    child =
      Supervisor.child_spec(
        {Replica,
         configuration: configuration,
         bootstrap: true,
         state_machine: StateMachine,
         state_machine_opts: [owner: self(), fail: failure],
         storage: {Storage, owner: self(), fail: failure}},
        restart: :temporary
      )

    replica = start_supervised!(child)
    assert {:ok, %{status: :normal}} = Replica.status(configuration.group_id, 1)
    replica
  end
end
