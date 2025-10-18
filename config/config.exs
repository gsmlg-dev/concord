# config/config.exs
import Config

config :concord,
  cluster_name: :concord_cluster,
  data_dir: "./data",
  auth_enabled: false

config :libcluster,
  topologies: [
    concord: [
      strategy: Cluster.Strategy.Gossip
    ]
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :operation, :node]

import_config "#{config_env()}.exs"
