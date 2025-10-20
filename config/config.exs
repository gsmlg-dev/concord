# config/config.exs
import Config

config :concord,
  cluster_name: :concord_cluster,
  data_dir: "./data",
  auth_enabled: false,
  ttl: %{
    default_seconds: 86_400,  # 24 hours
    cleanup_interval_seconds: 300,  # 5 minutes
    enabled: true
  }

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
