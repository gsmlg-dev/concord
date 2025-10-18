import Config

config :concord,
  data_dir: {:system, "CONCORD_DATA_DIR", "/var/lib/concord"},
  auth_enabled: true

config :logger, level: :info
