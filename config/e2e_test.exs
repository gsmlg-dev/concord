import Config

# E2E test configuration
config :concord,
  cluster_name: :concord_cluster,
  data_dir: "./data/e2e_test",
  auth_enabled: false

# Libcluster configuration - gossip strategy for multi-node testing
config :libcluster,
  topologies: [
    concord: [
      strategy: Cluster.Strategy.Gossip
    ]
  ]

config :logger, level: :warning

# HTTP API configuration for e2e tests
config :concord, :http,
  enabled: true,
  port: 4000

# Telemetry configuration
config :concord, :telemetry, enabled: true

# Prometheus exporter
config :concord, :prometheus,
  enabled: false

# Disable OpenTelemetry tracing in e2e tests
config :opentelemetry,
  traces_exporter: :none,
  processors: []

config :opentelemetry, :resource,
  service: [
    name: "concord-e2e-test"
  ]
