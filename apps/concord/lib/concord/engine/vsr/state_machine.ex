defmodule Concord.Engine.VSR.StateMachine do
  @moduledoc false

  @behaviour ViewstampedReplication.StateMachine

  alias Concord.CommandEnvelope
  alias Concord.CommandSchema
  alias Concord.QuerySchema
  alias Concord.StateMachine.Core
  alias Concord.StateMachine.Core.Context
  alias Concord.StateMachine.Observer
  alias Concord.Validation
  alias ViewstampedReplication.ApplyMetadata

  @impl true
  def init(opts) do
    state = Core.init(opts)
    Concord.StateMachine.materialize(state)
    state
  end

  @impl true
  def apply(
        %ApplyMetadata{} = metadata,
        operation,
        state
      )
      when is_tuple(operation) and tuple_size(operation) > 0 and
             elem(operation, 0) == :concord_query do
    case execute_query(metadata, operation, state) do
      {:ok, result} -> {result, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  def apply(
        %ApplyMetadata{group_id: group_id, op_number: op_number},
        operation,
        state
      ) do
    with {:ok, version, timestamp_ms, command} <- CommandEnvelope.unwrap(operation),
         :ok <- CommandSchema.validate_replay(version, command) do
      context = %Context{op_number: op_number, timestamp_ms: timestamp_ms}
      {result, next_state} = apply_versioned(version, context, command, state)
      Concord.StateMachine.materialize(next_state)
      Observer.committed(context, command, state, next_state, {:vsr, group_id})
      {result, next_state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  @impl true
  def read(
        %ApplyMetadata{} = metadata,
        operation,
        state
      ) do
    case execute_query(metadata, operation, state) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
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

  defp execute_query(
         %ApplyMetadata{op_number: op_number},
         operation,
         state
       ) do
    with {:ok, timestamp_ms, query} <- QuerySchema.unwrap(operation),
         :ok <- validate_query(query),
         :ok <- QuerySchema.validate(query) do
      context = %Context{op_number: op_number, timestamp_ms: timestamp_ms}
      {:ok, Core.query(query, state, context)}
    end
  end

  defp validate_query(query) do
    case Validation.validate_term(query) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_query, reason}}
    end
  end

  defp apply_versioned(0, context, command, state),
    do: Core.apply_legacy(context, command, state)

  defp apply_versioned(1, context, command, state), do: Core.apply(context, command, state)
end
