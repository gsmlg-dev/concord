defmodule Concord.Engine.Local do
  @moduledoc """
  Node-local Concord KV engine.

  This engine runs the protocol-independent state-machine core without starting
  a replication protocol. It is intentionally local to the current BEAM node:
  data is not replicated and does not participate in quorum writes.

  Basic KV values and conditional expected values may contain transient PIDs.
  Command metadata, transactions, and backup export remain deterministic.
  """

  use GenServer

  @behaviour Concord.Engine

  alias Concord.{CommandSchema, QuerySchema, StateMachine, StorageScope, Validation}
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
    with :ok <- validate_command(command) do
      call({:command, command}, opts)
    end
  end

  @impl Concord.Engine
  def query(query, opts \\ []) do
    with :ok <- validate_query(query) do
      call({:query, query}, opts)
    end
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
    case validate_command(command) do
      :ok -> apply_command(CommandSchema.normalize_emission(command), state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:query, query}, _from, %__MODULE__{} = state) do
    case validate_query(query) do
      :ok ->
        result =
          Core.query(query, state.machine_state, %{
            timestamp_ms: System.system_time(:millisecond)
          })

        {:reply, query_reply(query, result), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
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

  defp apply_command(command, state) do
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

  defp validate_command(command) do
    with :ok <- Validation.validate_command_size(command) do
      case local_value_command(command) do
        {structural_command, values} ->
          with :ok <- CommandSchema.validate_emission(structural_command) do
            validate_local_values(values)
          end

        :strict ->
          CommandSchema.validate_emission(command)
      end
    end
  end

  # Validate the complete original command's size above, each actual value
  # below, and the remaining command fields with the frozen writer schema.
  # Values are never replaced in the command applied to the in-memory Core.
  defp local_value_command({:put, key, value}), do: {{:put, key, nil}, [value]}

  defp local_value_command({:put, key, value, options}),
    do: {{:put, key, nil, options}, [value]}

  defp local_value_command({:put_if, key, value, expiry, expected}),
    do: {{:put_if, key, nil, expiry, nil}, [value, expected]}

  defp local_value_command({:delete_if, key, expected, condition}),
    do: {{:delete_if, key, nil, condition}, [expected]}

  defp local_value_command({:put_many, operations}) when is_list(operations) do
    case local_batch_values(operations, [], []) do
      {structural_operations, values} -> {{:put_many, structural_operations}, values}
      :strict -> :strict
    end
  end

  defp local_value_command(_command), do: :strict

  defp local_batch_values([], operations, values),
    do: {Enum.reverse(operations), Enum.reverse(values)}

  defp local_batch_values([{key, value} | rest], operations, values),
    do: local_batch_values(rest, [{key, nil} | operations], [value | values])

  defp local_batch_values([{key, value, expiry} | rest], operations, values),
    do: local_batch_values(rest, [{key, nil, expiry} | operations], [value | values])

  defp local_batch_values(_operations, _structural, _values), do: :strict

  defp validate_local_values(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case Validation.validate_value(value, engine: __MODULE__) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_command, reason}}}
      end
    end)
  end

  defp query_reply(:backup_snapshot, {:ok, snapshot} = result) do
    case Validation.validate_term(snapshot) do
      :ok -> {:ok, result}
      {:error, reason} -> {:error, {:invalid_snapshot, reason}}
    end
  end

  defp query_reply(_query, result), do: {:ok, result}

  defp validate_query(query) do
    with :ok <- validate_safe_query(query),
         :ok <- QuerySchema.validate(query) do
      :ok
    end
  end

  defp validate_safe_query(query) do
    case Validation.validate_term(query) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_query, reason}}
    end
  end

  defp clear_ets(table) do
    case :ets.whereis(table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(table)
    end
  end

  defp with_local_scope(fun), do: StorageScope.with_scope(:local, fun)
end
