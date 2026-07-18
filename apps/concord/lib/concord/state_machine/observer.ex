defmodule Concord.StateMachine.Observer do
  @moduledoc false

  alias Concord.StateMachine.Core
  alias Concord.StateMachine.Core.Context
  alias Concord.Sync.{Dispatcher, Event}

  @spec committed(Context.t(), term(), Core.State.t(), Core.State.t(), term()) :: :ok
  def committed(
        %Context{} = context,
        _command,
        %Core.State{} = previous,
        %Core.State{} = current,
        source_id
      ) do
    events =
      previous.current
      |> Map.keys()
      |> Kernel.++(Map.keys(current.current))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reduce([], fn key, events ->
        previous_record = Map.get(previous.current, key)
        current_record = Map.get(current.current, key)

        if previous_record == current_record do
          events
        else
          [event(key, previous_record, current_record, current) | events]
        end
      end)
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map(fn {event, index} ->
        %{event | id: {source_id, context.op_number, index}}
      end)

    if events != [] and Process.whereis(Dispatcher), do: Dispatcher.dispatch(events)
    :ok
  end

  defp event(key, previous_record, nil, state) do
    %Event{
      type: :delete,
      key: key,
      revision: state.revision,
      record: Map.get(state.history, {key, state.revision}),
      prev_record: previous_record
    }
  end

  defp event(key, previous_record, current_record, _state) do
    %Event{
      type: :put,
      key: key,
      revision: current_record.mod_revision,
      record: current_record,
      prev_record: previous_record
    }
  end
end
