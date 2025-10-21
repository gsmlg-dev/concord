import Config

config :concord,
  data_dir: {:system, "CONCORD_DATA_DIR", "/var/lib/concord"},
  auth_enabled: true,
  # Production HTTP API configuration
  api_port: {:system, "CONCORD_API_PORT", 8080},
  api_ip: {:system, "CONCORD_API_IP", {0, 0, 0, 0}}

config :logger, level: :info
