defmodule ViewstampedReplication.Test.Linearizability do
  @moduledoc false

  alias ViewstampedReplication.Test.RegisterStateMachine

  @type event :: %{
          required(:type) => :invoke | :complete,
          required(:call_id) => term(),
          optional(:operation) => term(),
          optional(:result) => term()
        }

  @spec linearizable?([event()], keyword()) :: boolean()
  def linearizable?(history, opts \\ []) do
    match?({:ok, _linearization}, check(history, opts))
  end

  @spec check([event()], keyword()) :: :ok | {:error, term()}
  def check(history, opts \\ []) do
    state_machine = Keyword.get(opts, :state_machine, RegisterStateMachine)
    initial_state = Keyword.get_lazy(opts, :initial_state, fn -> state_machine.init([]) end)

    with {:ok, operations} <- operations(history) do
      predecessors = real_time_predecessors(operations)

      case linearize(operations, predecessors, initial_state, state_machine, MapSet.new()) do
        {:ok, _order} = result -> result
        :error -> {:error, :not_linearizable}
      end
    end
  end

  defp operations(history) do
    {invocations, completions} =
      history
      |> Enum.with_index()
      |> Enum.reduce({%{}, %{}}, fn
        {%{type: :invoke, call_id: call_id} = event, index}, {invocations, completions} ->
          invocation = %{operation: Map.fetch!(event, :operation), invoked_at: index}
          {Map.put(invocations, call_id, invocation), completions}

        {%{type: :complete, call_id: call_id} = event, index}, {invocations, completions} ->
          completion = %{result: Map.fetch!(event, :result), completed_at: index}
          {invocations, Map.put(completions, call_id, completion)}

        {_event, _index}, acc ->
          acc
      end)

    case Enum.find(Map.keys(completions), &(not Map.has_key?(invocations, &1))) do
      nil ->
        operations =
          Map.new(invocations, fn {call_id, invocation} ->
            operation =
              case Map.fetch(completions, call_id) do
                {:ok, completion} ->
                  invocation
                  |> Map.merge(completion)
                  |> Map.put(:required?, true)

                :error ->
                  invocation
                  |> Map.put(:completed_at, nil)
                  |> Map.put(:required?, false)
              end

            {call_id, Map.put(operation, :call_id, call_id)}
          end)

        {:ok, operations}

      call_id ->
        {:error, {:completion_without_invocation, call_id}}
    end
  end

  defp real_time_predecessors(operations) do
    Map.new(operations, fn {call_id, operation} ->
      predecessors =
        for {other_id, other} <- operations,
            other_id != call_id,
            is_integer(other.completed_at),
            other.completed_at < operation.invoked_at,
            into: MapSet.new(),
            do: other_id

      {call_id, predecessors}
    end)
  end

  defp linearize(operations, predecessors, state, state_machine, seen) do
    if Enum.all?(operations, fn {_call_id, operation} -> not operation.required? end) do
      {:ok, []}
    else
      do_linearize(operations, predecessors, state, state_machine, seen)
    end
  end

  defp do_linearize(operations, predecessors, state, state_machine, seen) do
    cache_key = {operations |> Map.keys() |> MapSet.new(), state}

    if MapSet.member?(seen, cache_key) do
      :error
    else
      next_seen = MapSet.put(seen, cache_key)

      operations
      |> Enum.filter(fn {call_id, _operation} ->
        predecessors
        |> Map.fetch!(call_id)
        |> MapSet.disjoint?(Map.keys(operations) |> MapSet.new())
      end)
      |> Enum.reduce_while(:error, fn {call_id, operation}, :error ->
        {result, next_state} = state_machine.apply_operation(operation.operation, state)

        if not operation.required? or result == operation.result do
          case linearize(
                 Map.delete(operations, call_id),
                 predecessors,
                 next_state,
                 state_machine,
                 next_seen
               ) do
            {:ok, suffix} -> {:halt, {:ok, [call_id | suffix]}}
            :error -> {:cont, :error}
          end
        else
          {:cont, :error}
        end
      end)
    end
  end
end
