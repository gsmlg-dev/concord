defmodule Concord.Application do
  @moduledoc """
  Application supervisor for Concord embedded key-value store.
  Starts and manages the Raft consensus cluster, telemetry, TTL cleanup, and node discovery.
  """
  use Application
  require Logger

  alias Concord.{StateMachine, Telemetry, TTL}

  @impl true
  def start(_type, _args) do
    Telemetry.setup()

    children = [
      {Telemetry.Poller, []},
      {Cluster.Supervisor, [topologies(), [name: Concord.ClusterSupervisor]]},
      {TTL, []},
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
    wait_for_ra_system()

    node_id = node_id()
    cluster_name = :concord_cluster
    machine = {:module, StateMachine, %{}}

    nodes = [Node.self() | Node.list()]
    server_ids = Enum.map(nodes, &{cluster_name, &1})

    data_dir = Application.get_env(:concord, :data_dir, "./data/#{node()}")
    File.mkdir_p!(data_dir)

    uid = "#{cluster_name}_#{node()}" |> String.replace("@", "_") |> String.replace(".", "_")

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

    case :ra.start_server(:default, server_config) do
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

  defp wait_for_ra_system(attempts \\ 10)
  defp wait_for_ra_system(0), do: :ok

  defp wait_for_ra_system(attempts) do
    case :ra_system.fetch(:default) do
      %{} ->
        :ok

      _ ->
        Process.sleep(200)
        wait_for_ra_system(attempts - 1)
    end
  end
end
