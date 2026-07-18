defmodule ViewstampedReplication.Test.LinearizabilityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ViewstampedReplication.Test.{Linearizability, RegisterStateMachine}

  test "accepts a sequential register and compare-and-swap history" do
    history = [
      invoke(:writer, 1, {:write, 10}),
      complete(:writer, 1, :ok),
      invoke(:reader, 1, :read),
      complete(:reader, 1, 10),
      invoke(:cas, 1, {:compare_and_swap, 10, 20}),
      complete(:cas, 1, true),
      invoke(:reader, 2, :read),
      complete(:reader, 2, 20)
    ]

    assert {:ok, _linearization} = Linearizability.check(history)
  end

  test "uses invocation and completion intervals rather than completion order" do
    history = [
      invoke(:writer, 1, {:write, 10}),
      invoke(:reader, 1, :read),
      complete(:reader, 1, nil),
      complete(:writer, 1, :ok)
    ]

    assert Linearizability.linearizable?(history)
  end

  test "rejects a result that violates an established real-time order" do
    history = [
      invoke(:writer, 1, {:write, 10}),
      complete(:writer, 1, :ok),
      invoke(:reader, 1, :read),
      complete(:reader, 1, nil)
    ]

    refute Linearizability.linearizable?(history)
  end

  test "ignores an invocation that has no completion" do
    history = [
      invoke(:writer, 1, {:write, 10}),
      complete(:writer, 1, :ok),
      invoke(:pending, 1, {:write, 20})
    ]

    assert Linearizability.linearizable?(history)
  end

  test "may complete a pending operation when it explains a completed result" do
    history = [
      invoke(:writer, 1, {:write, 10}),
      invoke(:reader, 1, :read),
      complete(:reader, 1, 10)
    ]

    assert Linearizability.linearizable?(history)
  end

  property "all sequential model executions are linearizable" do
    check all(operations <- list_of(operation(), max_length: 30)) do
      {_state, history} =
        operations
        |> Enum.with_index(1)
        |> Enum.reduce({nil, []}, fn {operation, request_number}, {state, history} ->
          {result, next_state} = RegisterStateMachine.apply_operation(operation, state)

          next_history =
            history ++
              [
                invoke(:property_client, request_number, operation),
                complete(:property_client, request_number, result)
              ]

          {next_state, next_history}
        end)

      assert Linearizability.linearizable?(history)
    end
  end

  defp operation do
    value = member_of([nil, 0, 1, 2])

    one_of([
      constant(:read),
      map(value, &{:write, &1}),
      map({value, value}, fn {expected, replacement} ->
        {:compare_and_swap, expected, replacement}
      end)
    ])
  end

  defp invoke(client_id, request_number, operation) do
    %{
      type: :invoke,
      call_id: {client_id, request_number},
      operation: operation
    }
  end

  defp complete(client_id, request_number, result) do
    %{
      type: :complete,
      call_id: {client_id, request_number},
      result: result
    }
  end
end
