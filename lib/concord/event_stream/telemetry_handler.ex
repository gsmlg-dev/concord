defmodule Concord.EventStream.TelemetryHandler do
  @moduledoc false
  # Telemetry handler that captures Concord operations and publishes them to EventStream

  alias Concord.EventStream

  @stream_events [
    [:concord, :api, :put],
    [:concord, :api, :get],
    [:concord, :api, :delete],
    [:concord, :api, :put_many],
    [:concord, :api, :get_many],
    [:concord, :api, :delete_many],
    [:concord, :api, :touch],
    [:concord, :api, :touch_many]
  ]

  @doc """
  Attaches the telemetry handler to capture events.
  """
  def attach do
    if EventStream.enabled?() do
      :telemetry.attach_many(
        "concord-event-stream-handler",
        @stream_events,
        &handle_event/4,
        nil
      )
    end

    :ok
  end

  @doc """
  Detaches the telemetry handler.
  """
  def detach do
    if EventStream.enabled?() do
      :telemetry.detach("concord-event-stream-handler")
    end

    :ok
  end

  ## Private Functions

  defp handle_event(event_name, _measurements, metadata, _config) do
    operation = extract_operation(event_name)
    event = build_event(operation, metadata)
    EventStream.publish(event)
  end

  defp extract_operation([:concord, :api, operation]), do: operation

  defp build_event(operation, metadata) when operation in [:put, :delete, :get, :touch] do
    %{
      type: operation,
      key: Map.get(metadata, :key),
      value: extract_value(operation, metadata),
      timestamp: DateTime.utc_now(),
      node: node(),
      metadata: extract_metadata(metadata)
    }
  end

  defp build_event(operation, metadata)
       when operation in [:put_many, :delete_many, :get_many, :touch_many] do
    %{
      type: operation,
      keys: extract_keys(metadata),
      timestamp: DateTime.utc_now(),
      node: node(),
      metadata: extract_metadata(metadata)
    }
  end

  defp extract_value(:put, metadata), do: Map.get(metadata, :value)
  defp extract_value(:get, metadata), do: Map.get(metadata, :result)
  defp extract_value(_operation, _metadata), do: nil

  defp extract_keys(metadata) do
    cond do
      Map.has_key?(metadata, :keys) -> Map.get(metadata, :keys)
      Map.has_key?(metadata, :pairs) -> Map.get(metadata, :pairs) |> Map.keys()
      true -> []
    end
  end

  defp extract_metadata(metadata) do
    metadata
    |> Map.take([:ttl, :compress, :consistency, :result, :count])
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end
end
