defmodule Concord.MultiTenancy.RateLimiter do
  @moduledoc """
  GenServer that periodically resets rate limit counters for all tenants.

  This process runs every second and resets the `ops_last_second` counter
  for all tenants, enabling sliding-window rate limiting.
  """

  use GenServer
  alias Concord.MultiTenancy
  require Logger

  @reset_interval 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.debug("MultiTenancy.RateLimiter started")
    schedule_reset()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reset_counters, state) do
    MultiTenancy.reset_rate_counters()
    schedule_reset()
    {:noreply, state}
  end

  defp schedule_reset do
    Process.send_after(self(), :reset_counters, @reset_interval)
  end
end
