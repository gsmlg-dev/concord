defmodule Concord.EventStream.Consumer do
  @moduledoc false
  # Internal GenStage consumer that filters events and forwards to subscribers

  use GenStage

  def init(state) do
    {:consumer, state}
  end

  def handle_events(events, _from, state) do
    %{subscriber: subscriber, key_pattern: pattern, event_types: types} = state

    events
    |> Enum.filter(&matches_filter?(&1, pattern, types))
    |> Enum.each(fn event ->
      send(subscriber, {:concord_event, event})
    end)

    {:noreply, [], state}
  end

  defp matches_filter?(event, pattern, types) do
    matches_pattern?(event, pattern) and matches_type?(event, types)
  end

  defp matches_pattern?(_event, nil), do: true

  defp matches_pattern?(%{key: key}, pattern) when is_binary(key) do
    Regex.match?(pattern, key)
  end

  defp matches_pattern?(%{keys: keys}, pattern) when is_list(keys) do
    Enum.any?(keys, &Regex.match?(pattern, &1))
  end

  defp matches_pattern?(_event, _pattern), do: true

  defp matches_type?(_event, nil), do: true
  defp matches_type?(%{type: type}, types), do: type in types
end
