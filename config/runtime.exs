import Config

# Read node name from environment variable for per-node data directories
node_name = System.get_env("NODE_NAME", "node")

# Data directory: only use /tmp for dev and test environments.
# Production must use a persistent directory.
data_dir =
  case config_env() do
    :prod ->
      System.get_env("CONCORD_DATA_DIR", "/var/lib/concord/data/#{node_name}")

    _dev_or_test ->
      Path.join(System.tmp_dir!(), "concord_data/#{node_name}")
  end

config :concord,
  cluster_name: :concord_cluster,
  data_dir: data_dir

# Ra needs its own data_dir for WAL segments and snapshots.
# In Ra 3.0+, the `systems` config auto-starts named systems on boot.
ra_data_dir = Path.join(data_dir, "ra")
File.mkdir_p!(ra_data_dir)

config :ra,
  data_dir: :erlang.binary_to_list(ra_data_dir),
  systems: [default: %{}]

# libcluster discovery strategy
# If CONCORD_CLUSTER_NODES is set (comma-separated), use Epmd strategy (deterministic).
# Otherwise, use Gossip strategy (multicast auto-discovery).
cluster_topology =
  case System.get_env("CONCORD_CLUSTER_NODES") do
    nil ->
      [
        concord_gossip: [
          strategy: Cluster.Strategy.Gossip
        ]
      ]

    nodes_str ->
      nodes =
        nodes_str
        |> String.split(",", trim: true)
        |> Enum.map(&String.to_atom(String.trim(&1)))

      [
        concord_epmd: [
          strategy: Cluster.Strategy.Epmd,
          config: [hosts: nodes]
        ]
      ]
  end

config :libcluster, topologies: cluster_topology
