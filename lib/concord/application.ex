defmodule Concord.Application do
  @moduledoc """
  Application supervisor for Concord distributed key-value store.
  Starts and manages all the necessary processes including clustering,
  telemetry, authentication, HTTP API, and the Raft consensus algorithm.
  """
  use Application
  require Logger

  alias Concord.{
    AuditLog,
    Auth,
    EventStream,
    MultiTenancy,
    Prometheus,
    RBAC,
    StateMachine,
    Telemetry,
    TTL,
    Web
  }

  alias Concord.Tracing.TelemetryBridge

  @impl true
  def start(_type, _args) do
    # Initialize RBAC tables
    RBAC.init_tables()

    # Initialize multi-tenancy tables
    MultiTenancy.init_tables()

    # Attach telemetry handlers
    Telemetry.setup()

    # Attach OpenTelemetry telemetry bridge if tracing is enabled
    if Application.get_env(:concord, :tracing_enabled, false) do
      TelemetryBridge.attach()
    end

    # Attach audit log telemetry handler if enabled
    if audit_log_enabled?() do
      AuditLog.TelemetryHandler.attach()
    end

    # Attach event stream telemetry handler if enabled
    if event_stream_enabled?() do
      EventStream.TelemetryHandler.attach()
    end

    # Build children list conditionally
    children = [
      # Start telemetry poller for periodic metrics
      {Telemetry.Poller, []},
      # Start libcluster for automatic node discovery
      {Cluster.Supervisor, [topologies(), [name: Concord.ClusterSupervisor]]},
      # Start auth token manager
      Auth.TokenStore,
      # Start TTL manager for periodic cleanup
      {TTL, []},
      # Start multi-tenancy rate limiter
      MultiTenancy.RateLimiter,
      # Start the Concord cluster after a brief delay
      {Task, fn -> init_cluster() end}
    ]

    # Add HTTP API web server if enabled
    children =
      if http_api_enabled?() do
        # Insert Web.Supervisor before the cluster init task
        List.insert_at(children, -1, Web.Supervisor)
      else
        children
      end

    # Add Prometheus exporter if enabled
    children =
      if prometheus_enabled?() do
        children ++ [Prometheus.child_spec([])]
      else
        children
      end

    # Add Audit Log GenServer if enabled
    children =
      if audit_log_enabled?() do
        children ++ [AuditLog]
      else
        children
      end

    # Add Event Stream GenStage producer if enabled
    children =
      if event_stream_enabled?() do
        children ++ [EventStream]
      else
        children
      end

    opts = [strategy: :one_for_one, name: Concord.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp http_api_enabled? do
    Application.get_env(:concord, :http, [])
    |> Keyword.get(:enabled, false)
  end

  defp prometheus_enabled? do
    Application.get_env(:concord, :prometheus_enabled, true)
  end

  defp audit_log_enabled? do
    Application.get_env(:concord, :audit_log, [])
    |> Keyword.get(:enabled, false)
  end

  defp event_stream_enabled? do
    Application.get_env(:concord, :event_stream, [])
    |> Keyword.get(:enabled, false)
  end

  defp topologies do
    [
      concord: [
        strategy: Cluster.Strategy.Gossip
      ]
    ]
  end

  defp init_cluster do
    Process.sleep(1000)

    node_id = node_id()
    cluster_name = :concord_cluster
    machine = {:module, StateMachine, %{}}

    nodes = [Node.self() | Node.list()]
    server_ids = Enum.map(nodes, &{cluster_name, &1})

    data_dir = Application.get_env(:concord, :data_dir, "./data/#{node()}")
    File.mkdir_p!(data_dir)

    # Create a proper uid from the node tuple
    uid = node_id |> Tuple.to_list() |> Enum.join("_") |> String.replace("@", "_")

    server_config = %{
      id: node_id,
      uid: uid,
      cluster_name: cluster_name,
      machine: machine,
      log_init_args: %{
        uid: uid,
        data_dir: data_dir
      },
      initial_members: server_ids
    }

    case :ra.start_server(server_config) do
      :ok ->
        Logger.info("Concord cluster started on #{node()}")
        :ra.trigger_election(node_id)
        :ok

      {:ok, _} ->
        Logger.info("Concord cluster started on #{node()}")
        :ok

      {:error, {:already_started, _}} ->
        Logger.info("Concord cluster already running on #{node()}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to start Concord cluster: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp node_id do
    {Application.get_env(:concord, :cluster_name, :concord_cluster), node()}
  end
end
