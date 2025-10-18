defmodule Concord.Telemetry do
  @moduledoc """
  Telemetry integration for Concord.
  Emits metrics for monitoring cluster health and performance.
  """

  require Logger

  def setup do
    events = [
      [:concord, :api, :put],
      [:concord, :api, :get],
      [:concord, :api, :delete],
      [:concord, :operation, :apply],
      [:concord, :state, :change],
      [:concord, :snapshot, :created],
      [:concord, :snapshot, :installed]
    ]

    :telemetry.attach_many(
      "concord-logger",
      events,
      &handle_event/4,
      nil
    )
  end

  def handle_event([:concord, :api, operation], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.debug(
      "API #{operation}: #{metadata.result} (#{duration_ms}ms)",
      operation: operation,
      result: metadata.result,
      duration_ms: duration_ms
    )
  end

  def handle_event([:concord, :operation, :apply], measurements, metadata, _config) do
    duration_us = System.convert_time_unit(measurements.duration, :native, :microsecond)

    Logger.debug(
      "Applied #{metadata.operation} at index #{metadata.index} (#{duration_us}μs)",
      operation: metadata.operation,
      index: metadata.index,
      duration_us: duration_us
    )
  end

  def handle_event([:concord, :state, :change], _measurements, metadata, _config) do
    Logger.info(
      "Node #{metadata.node} transitioned to #{metadata.status}",
      node: metadata.node,
      status: metadata.status
    )
  end

  def handle_event([:concord, :snapshot, :created], measurements, metadata, _config) do
    Logger.info(
      "Snapshot created on #{metadata.node}: #{measurements.size} entries",
      node: metadata.node,
      size: measurements.size
    )
  end

  def handle_event([:concord, :snapshot, :installed], measurements, metadata, _config) do
    Logger.info(
      "Snapshot installed on #{metadata.node}: #{measurements.size} entries",
      node: metadata.node,
      size: measurements.size
    )
  end

  # Telemetry Poller for periodic metrics
  defmodule Poller do
    use GenServer

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    def init(_) do
      schedule_poll()
      {:ok, %{}}
    end

    def handle_info(:poll, state) do
      emit_metrics()
      schedule_poll()
      {:noreply, state}
    end

    defp schedule_poll do
      Process.send_after(self(), :poll, 10_000)
    end

    defp emit_metrics do
      case Concord.status() do
        {:ok, status} ->
          :telemetry.execute(
            [:concord, :cluster, :status],
            %{
              storage_size: get_in(status, [:storage, :size]) || 0,
              storage_memory: get_in(status, [:storage, :memory]) || 0
            },
            %{node: node()}
          )

        _ ->
          :ok
      end
    end
  end
end
