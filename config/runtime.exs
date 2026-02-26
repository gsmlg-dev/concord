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

# libcluster discovery strategy
config :libcluster,
  topologies: [
    concord_gossip: [
      strategy: Cluster.Strategy.Gossip
    ]
  ]
