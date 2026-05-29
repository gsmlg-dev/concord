defmodule Concord.Application do
  @moduledoc """
  Application supervisor for Concord embedded key-value store.
  Starts and manages the Raft consensus cluster, telemetry, TTL cleanup, and node discovery.
  """
  use Application
  require Logger

  alias Concord.{StateMachine, Telemetry, TTL}
  alias Concord.Sync.{Dispatcher, WatchHub}

  @impl true
  def start(_type, _args) do
    Telemetry.setup()

    children = [
      {Telemetry.Poller, []},
      {Cluster.Supervisor, [topologies(), [name: Concord.ClusterSupervisor]]},
      {TTL, []},
      {Dispatcher, []},
      {WatchHub, []},
      {Task, fn -> init_cluster() end}
    ]

    opts = [strategy: :one_for_one, name: Concord.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  def prometheus_enabled? do
    Application.get_env(:concord, :prometheus_enabled, false)
  end

  defp topologies do
    [
      concord: [
        strategy: Cluster.Strategy.Gossip
      ]
    ]
  end

  defp init_cluster do
    case wait_for_ra_system() do
      :ok ->
        start_cluster()

      {:error, reason} ->
        Logger.error("Failed to start Concord cluster: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp start_cluster do
    wait_for_peers()

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

    Logger.info(
      "Starting Raft with #{length(nodes)} members: #{inspect(Enum.map(nodes, &to_string/1))}"
    )

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

  # Wait for libcluster to discover peer nodes. If CONCORD_CLUSTER_NODES is set,
  # we know how many peers to expect. Otherwise, proceed after a short delay.
  defp wait_for_peers do
    case System.get_env("CONCORD_CLUSTER_NODES") do
      nil ->
        # Gossip mode: give discovery a chance
        Process.sleep(2000)

      nodes_str ->
        expected =
          nodes_str
          |> String.split(",", trim: true)
          |> Enum.map(&String.to_atom(String.trim(&1)))
          |> Enum.reject(&(&1 == node()))
          |> length()

        wait_for_peer_count(expected, 30)
    end
  end

  defp wait_for_peer_count(0, _attempts), do: :ok

  defp wait_for_peer_count(_expected, 0) do
    Logger.warning("Peer discovery timed out, starting with #{length(Node.list())} peers")
  end

  defp wait_for_peer_count(expected, attempts) do
    if length(Node.list()) >= expected do
      Logger.info("All #{expected} peers discovered")
      :ok
    else
      Process.sleep(1000)
      wait_for_peer_count(expected, attempts - 1)
    end
  end

  defp node_id do
    {Application.get_env(:concord, :cluster_name, :concord_cluster), node()}
  end

  defp wait_for_ra_system(attempts \\ 10)
  defp wait_for_ra_system(0), do: {:error, :ra_system_not_started}

  defp wait_for_ra_system(attempts) do
    case ensure_ra_system_ready() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Ra default system not ready: #{inspect(reason)}, retrying...")
        Process.sleep(500)
        wait_for_ra_system(attempts - 1)
    end
  end

  defp ensure_ra_system_ready do
    with {:ok, _started} <- Application.ensure_all_started(:ra),
         :ok <- ensure_default_ra_system_started(),
         true <- ra_system_ready?() do
      :ok
    else
      false -> {:error, :ra_system_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_default_ra_system_started do
    if ra_system_ready?() do
      :ok
    else
      case :ra_system.start_default() do
        {:ok, _} ->
          Logger.info("Ra default system started explicitly")
          :ok

        {:error, {:already_started, _}} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ra_system_ready? do
    case :ra_system.lookup_name(:default, :server_sup) do
      {:ok, server_sup} -> Process.whereis(server_sup) != nil
      {:error, :system_not_started} -> false
    end
  end
end
