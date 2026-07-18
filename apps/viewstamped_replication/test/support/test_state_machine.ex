defmodule ViewstampedReplication.Test.RegisterStateMachine do
  @moduledoc false

  import Kernel, except: [apply: 3]

  @behaviour ViewstampedReplication.StateMachine

  @impl true
  def init(opts), do: Keyword.get(opts, :value)

  @impl true
  def apply(_metadata, :read, value), do: {value, value}

  def apply(_metadata, {:write, replacement}, _value), do: {:ok, replacement}

  def apply(_metadata, {:compare_and_swap, expected, replacement}, expected),
    do: {true, replacement}

  def apply(_metadata, {:compare_and_swap, _expected, _replacement}, value),
    do: {false, value}

  @impl true
  def snapshot(value), do: {:ok, value}

  @impl true
  def restore(snapshot), do: {:ok, snapshot}

  @spec apply_operation(term(), term()) :: {term(), term()}
  def apply_operation(operation, state), do: apply(nil, operation, state)
end
