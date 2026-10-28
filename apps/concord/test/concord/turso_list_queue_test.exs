defmodule Concord.Turso.ListQueueTest do
  use ExUnit.Case, async: false

  alias Concord.Turso.ListQueue

  @tasks ListQueue.Tasks
  @admission ListQueue.Admission

  setup context do
    opts = Map.get(context, :queue_options, max_children: 1)
    supervisor = start_supervised!({ListQueue, opts})
    %{supervisor: supervisor}
  end

  test "callback runs under supervision with a monitor of the original caller" do
    owner = self()

    assert {:ok, :finished} =
             ListQueue.run(deadline(1_000), fn caller, monitor ->
               assert caller == owner
               assert is_reference(monitor)
               refute self() == caller
               assert {:monitors, monitors} = Process.info(self(), :monitors)
               assert {:process, caller} in monitors
               assert self() in Task.Supervisor.children(@tasks)
               {:ok, :finished}
             end)

    wait_until_empty(@tasks)
    assert {:messages, []} = Process.info(self(), :messages)
  end

  @tag queue_options: []
  test "default capacity is finite and root child specification is supervised" do
    assert %{max_children: 64} = :sys.get_state(@tasks)
    assert %{type: :supervisor} = ListQueue.child_spec([])
  end

  @tag queue_options: [
         name: ListQueueTest.CustomSupervisor,
         tasks_name: ListQueueTest.CustomTasks,
         admission_name: ListQueueTest.CustomAdmission,
         max_children: 2
       ]
  test "static supervisor names and capacity can be configured" do
    assert %{max_children: 2} = :sys.get_state(ListQueueTest.CustomTasks)

    assert :custom =
             ListQueue.run(
               deadline(1_000),
               fn _caller, _monitor -> :custom end,
               ListQueueTest.CustomAdmission
             )
  end

  test "unbounded or nonpositive capacity is rejected before starting processes" do
    for capacity <- [:infinity, 0, -1, nil] do
      assert_raise ArgumentError, "list queue max_children must be a positive integer", fn ->
        ListQueue.start_link(name: ListQueueTest.InvalidSupervisor, max_children: capacity)
      end
    end
  end

  test "expired budgets and missing admission fail without running callbacks" do
    owner = self()
    callback = fn _caller, _monitor -> send(owner, :unexpected_callback) end
    assert {:error, :timeout} = ListQueue.run(deadline(0), callback)

    assert {:error, :engine_not_started} =
             ListQueue.run(deadline(1_000), callback, ListQueueTest.MissingAdmission)

    refute_receive :unexpected_callback
    assert Task.Supervisor.children(@tasks) == []
  end

  test "suspended admission cannot extend the caller deadline or run a late callback" do
    owner = self()
    :ok = :sys.suspend(@admission)

    try do
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               ListQueue.run(deadline(20), fn _caller, _monitor ->
                 send(owner, :unexpected_callback)
               end)

      assert System.monotonic_time(:millisecond) - started < 200
    after
      :ok = :sys.resume(@admission)
    end

    assert @tasks == :sys.get_state(@admission)
    wait_until_empty(@tasks)
    refute_receive :unexpected_callback
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "a delayed task start cannot extend admission or execute an expired callback" do
    owner = self()
    :ok = :sys.suspend(@tasks)

    try do
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               ListQueue.run(deadline(20), fn _caller, _monitor ->
                 send(owner, :unexpected_callback)
               end)

      assert System.monotonic_time(:millisecond) - started < 200
    after
      :ok = :sys.resume(@tasks)
    end

    assert @tasks == :sys.get_state(@admission)
    wait_until_empty(@tasks)
    refute_receive :unexpected_callback
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "timeout keeps running callback capacity occupied and suppresses its late reply" do
    owner = self()

    assert {:error, :timeout} =
             ListQueue.run(deadline(20), fn _caller, _monitor ->
               send(owner, {:native_started, self()})

               receive do
                 :release -> :finished
               end
             end)

    assert_receive {:native_started, worker}
    assert Process.alive?(worker)
    assert [^worker] = Task.Supervisor.children(@tasks)

    assert {:error, :overloaded} =
             ListQueue.run(deadline(1_000), fn _caller, _monitor ->
               send(owner, :unexpected_callback)
             end)

    monitor = Process.monitor(worker)
    send(worker, :release)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    wait_until_empty(@tasks)
    refute_receive :unexpected_callback
    assert {:messages, []} = Process.info(self(), :messages)
    assert :recovered = ListQueue.run(deadline(1_000), fn _caller, _monitor -> :recovered end)
  end

  test "caller death promptly releases a waiting worker through its supplied monitor" do
    owner = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        ListQueue.run(deadline(5_000), fn caller, monitor ->
          send(owner, {:queued, self()})

          receive do
            {:DOWN, ^monitor, :process, ^caller, _reason} -> :caller_gone
          end
        end)
      end)

    assert_receive {:queued, worker}, 1_000
    worker_monitor = Process.monitor(worker)
    started = System.monotonic_time(:millisecond)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 1_000
    assert System.monotonic_time(:millisecond) - started < 500
    wait_until_empty(@tasks)
    assert :recovered = ListQueue.run(deadline(1_000), fn _caller, _monitor -> :recovered end)
  end

  @tag capture_log: true
  test "worker exit is reported explicitly and does not hang or kill the caller" do
    assert {:error, {:list_worker_exit, :expected_worker_exit}} =
             ListQueue.run(deadline(1_000), fn _caller, _monitor ->
               exit(:expected_worker_exit)
             end)

    wait_until_empty(@tasks)
    assert :recovered = ListQueue.run(deadline(1_000), fn _caller, _monitor -> :recovered end)
    assert {:messages, []} = Process.info(self(), :messages)
  end

  defp wait_until_empty(tasks), do: wait_until_empty(tasks, deadline(1_000))

  defp wait_until_empty(tasks, deadline) do
    if Task.Supervisor.children(tasks) == [] do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(1)
      wait_until_empty(tasks, deadline)
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
end
