defmodule Concord.TTL do
  @moduledoc """
  TTL (Time-To-Live) management for Concord.

  This module provides periodic cleanup of expired keys and
  configuration management for TTL-related settings.
  """

  use GenServer
  require Logger

  @cluster_name :concord_cluster

  defstruct [:cleanup_interval, :default_ttl, :timer_ref]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the current TTL configuration.
  """
  def config do
    GenServer.call(__MODULE__, :config)
  end

  @doc """
  Updates the cleanup interval.
  """
  def update_cleanup_interval(interval_seconds) when is_integer(interval_seconds) and interval_seconds > 0 do
    GenServer.call(__MODULE__, {:update_cleanup_interval, interval_seconds})
  end

  @doc """
  Triggers an immediate cleanup of expired keys.
  """
  def cleanup_now do
    GenServer.call(__MODULE__, :cleanup_now)
  end

  @doc """
  Calculates the expiration timestamp for a given TTL in seconds.
  """
  def calculate_expiration(ttl_seconds) when is_integer(ttl_seconds) and ttl_seconds > 0 do
    System.system_time(:second) + ttl_seconds
  end

  def calculate_expiration(nil), do: nil
  def calculate_expiration(:infinity), do: nil

  @doc """
  Validates a TTL value.
  """
  def validate_ttl(nil), do: :ok
  def validate_ttl(:infinity), do: :ok
  def validate_ttl(ttl) when is_integer(ttl) and ttl > 0, do: :ok
  def validate_ttl(_), do: {:error, :invalid_ttl}

  # GenServer Callbacks

  @impl true
  def init(opts) do
    # Get configuration from application environment
    cleanup_interval = Keyword.get(opts, :cleanup_interval, default_cleanup_interval())
    default_ttl = Keyword.get(opts, :default_ttl, default_ttl())

    state = %__MODULE__{
      cleanup_interval: cleanup_interval,
      default_ttl: default_ttl
    }

    Logger.info("Starting Concord TTL manager with cleanup interval: #{cleanup_interval}s")

    # Schedule first cleanup
    timer_ref = schedule_cleanup(cleanup_interval)

    {:ok, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_call(:config, _from, state) do
    {:reply, %{cleanup_interval: state.cleanup_interval, default_ttl: state.default_ttl}, state}
  end

  def handle_call({:update_cleanup_interval, interval_seconds}, _from, state) do
    # Cancel existing timer
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    # Schedule new cleanup
    timer_ref = schedule_cleanup(interval_seconds)

    new_state = %{state | cleanup_interval: interval_seconds, timer_ref: timer_ref}
    Logger.info("Updated TTL cleanup interval to #{interval_seconds}s")

    {:reply, :ok, new_state}
  end

  def handle_call(:cleanup_now, _from, state) do
    result = perform_cleanup()
    {:reply, result, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    _result = perform_cleanup()

    # Schedule next cleanup
    timer_ref = schedule_cleanup(state.cleanup_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def terminate(reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    Logger.info("Concord TTL manager stopping: #{inspect(reason)}")
    :ok
  end

  # Private functions

  defp perform_cleanup do
    start_time = System.monotonic_time()
    server_id = {@cluster_name, node()}

    case :ra.process_command(server_id, :cleanup_expired, 10_000) do
      {:ok, {:ok, deleted_count}, _leader} ->
        duration = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        # Emit telemetry event
        :telemetry.execute(
          [:concord, :ttl, :cleanup],
          %{
            duration: duration,
            duration_ms: duration_ms,
            deleted_count: deleted_count
          },
          %{
            node: node()
          }
        )

        if deleted_count > 0 do
          Logger.info("TTL cleanup completed: deleted #{deleted_count} expired keys in #{duration_ms}ms")
        end

        {:ok, deleted_count}

      {:timeout, _} ->
        Logger.warning("TTL cleanup operation timed out")
        {:error, :timeout}

      {:error, :noproc} ->
        Logger.warning("TTL cleanup failed - cluster not ready")
        {:error, :cluster_not_ready}

      {:error, reason} ->
        Logger.error("TTL cleanup failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp schedule_cleanup(interval_seconds) do
    Process.send_after(self(), :cleanup, interval_seconds * 1000)
  end

  defp default_cleanup_interval do
    Application.get_env(:concord, :ttl, [])
    |> Keyword.get(:cleanup_interval_seconds, 300)  # 5 minutes default
  end

  defp default_ttl do
    Application.get_env(:concord, :ttl, [])
    |> Keyword.get(:default_seconds, 86_400)  # 24 hours default
  end
end