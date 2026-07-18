defmodule Concord.Engine.Local do
  @moduledoc """
  Node-local Concord KV engine.

  This engine runs the protocol-independent state-machine core without starting
  a replication protocol. It is intentionally local to the current BEAM node:
  data is not replicated and does not participate in quorum writes.
  """

  use GenServer

  @behaviour Concord.Engine

  alias Concord.{StateMachine, StorageScope}
  alias Concord.StateMachine.Core
  alias Concord.StateMachine.Core.Context
  alias Concord.StateMachine.Observer

  @timeout 5_000

  defstruct [:machine_state, applied_index: 0]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    machine_state =
      with_local_scope(fn ->
        state = Core.init()
        StateMachine.materialize(state)
        state
      end)

    {:ok, %__MODULE__{machine_state: machine_state}}
  end

  @impl Concord.Engine
  def command(command, opts \\ []) do
    call({:command, command}, opts)
  end

  @impl Concord.Engine
  def query(query, opts \\ []) do
    call({:query, query}, opts)
  end

  @impl Concord.Engine
  def status(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    case query(:stats, timeout: timeout) do
      {:ok, {:ok, stats}} ->
        {:ok,
         %{
           cluster: %{engine: :kv_local, members: [node()]},
           storage: stats,
           engine: :kv_local,
           node: node()
         }}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Concord.Engine
  def members(_opts \\ []) do
    {:ok, [{:kv_local, node()}]}
  end

  @doc false
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def handle_call({:command, command}, _from, %__MODULE__{} = state) do
    next_index = state.applied_index + 1

    context =
      Context.new!(
        op_number: next_index,
        timestamp_ms: System.system_time(:millisecond)
      )

    {result, machine_state} =
      with_local_scope(fn ->
        previous_state = state.machine_state
        {result, machine_state} = Core.apply(context, command, previous_state)
        StateMachine.materialize(machine_state)
        Observer.committed(context, command, previous_state, machine_state, :local)
        {result, machine_state}
      end)

    {:reply, {:ok, result}, %{state | machine_state: machine_state, applied_index: next_index}}
  end

  def handle_call({:query, query}, _from, %__MODULE__{} = state) do
    result =
      Core.query(query, state.machine_state, %{
        timestamp_ms: System.system_time(:millisecond)
      })

    {:reply, {:ok, result}, state}
  end

  def handle_call(:reset, _from, %__MODULE__{}) do
    machine_state =
      with_local_scope(fn ->
        clear_ets(StorageScope.table(:store))
        clear_ets(StorageScope.table(:current))
        clear_ets(StorageScope.table(:history))
        clear_ets(StorageScope.table(:leases))

        state = Core.init()
        StateMachine.materialize(state)
        state
      end)

    {:reply, :ok, %__MODULE__{machine_state: machine_state}}
  end

  defp call(message, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :engine_not_started}
      _pid -> GenServer.call(__MODULE__, message, timeout)
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  defp clear_ets(table) do
    case :ets.whereis(table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(table)
    end
  end

  defp with_local_scope(fun), do: StorageScope.with_scope(:local, fun)
end
