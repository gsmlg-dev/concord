defmodule Concord.Application do
  @moduledoc """
  Application supervisor for Concord embedded key-value store.
  Starts and manages the configured replication engine, telemetry, TTL cleanup,
  and node discovery.
  """
  use Application

  alias Concord.{Engine, Telemetry, TTL, Turso}
  alias Concord.Sync.{Dispatcher, WatchHub}

  @impl true
  def start(_type, _args) do
    Telemetry.setup()

    opts = [strategy: :one_for_one, name: Concord.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  @doc false
  def children do
    ([{Telemetry.Poller, []}] ++
       turso_children() ++ [{Engine.Local, []}] ++ cluster_children())
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  def cluster_enabled? do
    Application.get_env(:concord, :cluster_enabled, true)
  end

  @doc false
  def prometheus_enabled? do
    Application.get_env(:concord, :prometheus_enabled, false)
  end

  defp cluster_children do
    if cluster_enabled?() do
      [
        {TTL, []},
        {Dispatcher, []},
        {WatchHub, []},
        {Engine.VSR.Supervisor, []}
      ]
    else
      []
    end
  end

  defp turso_children do
    if Turso.enabled?(), do: [{Turso, []}], else: []
  end
end
