defmodule Concord.Turso.ListQueue do
  @moduledoc false

  use Supervisor

  @supervisor __MODULE__.Supervisor
  @tasks __MODULE__.Tasks
  @admission __MODULE__.Admission
  @default_max_children 64

  def start_link(opts \\ []) do
    max_children = Keyword.get(opts, :max_children, @default_max_children)

    unless is_integer(max_children) and max_children > 0 do
      raise ArgumentError, "list queue max_children must be a positive integer"
    end

    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @supervisor))
  end

  @impl true
  def init(opts) do
    tasks = Keyword.get(opts, :tasks_name, @tasks)
    admission = Keyword.get(opts, :admission_name, @admission)
    max_children = Keyword.get(opts, :max_children, @default_max_children)

    children = [
      {Task.Supervisor, name: tasks, max_children: max_children},
      {__MODULE__.Admission, {tasks, admission}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def run(deadline, fun, admission \\ @admission)
      when is_integer(deadline) and is_function(fun, 2) do
    if remaining(deadline) == 0 do
      {:error, :timeout}
    else
      reply = :erlang.alias()

      try do
        case GenServer.call(admission, {:admit, reply, deadline, fun}, remaining(deadline)) do
          {:ok, pid} -> await_worker(pid, reply, deadline)
          {:error, reason} -> {:error, reason}
        end
      catch
        :exit, {:timeout, _call} -> {:error, :timeout}
        :exit, {:noproc, _call} -> {:error, :engine_not_started}
        :exit, reason -> {:error, {:list_queue_exit, reason}}
      after
        :erlang.unalias(reply)
        flush_reply(reply)
      end
    end
  end

  defp await_worker(pid, reply, deadline) do
    monitor = Process.monitor(pid)
    send(pid, {reply, :run})

    try do
      result =
        receive do
          {^reply, result} -> result
          {:DOWN, ^monitor, :process, ^pid, reason} -> {:error, {:list_worker_exit, reason}}
        after
          remaining(deadline) -> {:error, :timeout}
        end

      if remaining(deadline) > 0, do: result, else: {:error, :timeout}
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp flush_reply(reply) do
    receive do
      {^reply, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defmodule Admission do
    @moduledoc false

    use GenServer

    # The separate admission call is timed: Task.Supervisor.start_child/2 itself
    # waits indefinitely, so it must never run in the deadline-bound caller.
    def start_link({tasks, name}), do: GenServer.start_link(__MODULE__, tasks, name: name)

    @impl true
    def init(tasks), do: {:ok, tasks}

    @impl true
    def handle_call({:admit, reply, deadline, fun}, {caller, _tag}, tasks) do
      result =
        if remaining(deadline) > 0 and Process.alive?(caller) do
          case Task.Supervisor.start_child(tasks, fn -> worker(caller, reply, deadline, fun) end) do
            {:ok, pid} -> {:ok, pid}
            {:error, :max_children} -> {:error, :overloaded}
            {:error, reason} -> {:error, {:list_queue_start, reason}}
          end
        else
          {:error, :timeout}
        end

      {:reply, result, tasks}
    end

    defp worker(caller, reply, deadline, fun) do
      monitor = Process.monitor(caller)

      try do
        receive do
          {^reply, :run} ->
            result =
              if remaining(deadline) > 0 and Process.alive?(caller),
                do: fun.(caller, monitor),
                else: {:error, :timeout}

            send(reply, {reply, result})

          {:DOWN, ^monitor, :process, ^caller, _reason} ->
            :ok
        after
          remaining(deadline) -> send(reply, {reply, {:error, :timeout}})
        end
      after
        Process.demonitor(monitor, [:flush])
      end
    end

    defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
