defmodule Concord.Engine.VSR.StateMachine do
  @moduledoc false

  @behaviour ViewstampedReplication.StateMachine

  alias Concord.StateMachine.Core
  alias Concord.StateMachine.Core.Context
  alias Concord.StateMachine.Observer
  alias ViewstampedReplication.ApplyMetadata

  @impl true
  def init(opts) do
    state = Core.init(opts)
    Concord.StateMachine.materialize(state)
    state
  end

  @impl true
  def apply(
        %ApplyMetadata{group_id: group_id, op_number: op_number},
        {:concord_command, timestamp_ms, command},
        state
      ) do
    context = %Context{op_number: op_number, timestamp_ms: timestamp_ms}
    {result, next_state} = Core.apply(context, command, state)
    Concord.StateMachine.materialize(next_state)
    Observer.committed(context, command, state, next_state, {:vsr, group_id})
    {result, next_state}
  end

  def apply(
        %ApplyMetadata{op_number: op_number},
        {:concord_query, timestamp_ms, query},
        state
      ) do
    context = %Context{op_number: op_number, timestamp_ms: timestamp_ms}
    {Core.query(query, state, context), state}
  end

  @impl true
  def read(
        %ApplyMetadata{op_number: op_number},
        {:concord_query, timestamp_ms, query},
        state
      ) do
    context = %Context{op_number: op_number, timestamp_ms: timestamp_ms}
    Core.query(query, state, context)
  end

  @impl true
  def snapshot(state), do: Core.snapshot(state)

  @impl true
  def restore(snapshot) do
    with {:ok, state} <- Core.restore(snapshot) do
      Concord.StateMachine.materialize(state)
      {:ok, state}
    end
  end
end
