defmodule Concord.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Attach telemetry handlers
    Concord.Telemetry.setup()

    children = [
      # Start telemetry poller for periodic metrics
      {Concord.Telemetry.Poller, []},
      # Start libcluster for automatic node discovery
      {Cluster.Supervisor, [topologies(), [name: Concord.ClusterSupervisor]]},
      # Start auth token manager
      Concord.Auth.TokenStore,
      # Start the Concord cluster after a brief delay
      {Task, fn -> init_cluster() end}
    ]

    opts = [strategy: :one_for_one, name: Concord.Supervisor]
    Supervisor.start_link(children, opts)
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
    machine = {:module, Concord.StateMachine, %{}}

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
