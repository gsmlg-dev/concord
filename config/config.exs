# config/config.exs
import Config

config :concord,
  cluster_name: :concord_cluster,
  data_dir: "./data",
  auth_enabled: false,
  max_batch_size: 500,
  # Default read consistency level: :eventual, :leader, or :strong
  default_read_consistency: :leader,
  ttl: [
    default_seconds: 86_400,  # 24 hours
    cleanup_interval_seconds: 300,  # 5 minutes
    enabled: true
  ],
  # Value compression configuration
  compression: [
    enabled: true,           # Enable automatic compression
    algorithm: :zlib,        # :zlib or :gzip
    threshold_bytes: 1024,   # Compress values larger than 1KB
    level: 6                 # Compression level 0-9 (0=none, 9=max)
  ],
  # HTTP API configuration
  api_port: 4000,
  api_ip: {127, 0, 0, 1},  # localhost
  # Prometheus metrics configuration
  prometheus_enabled: true,
  prometheus_port: 9568

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
