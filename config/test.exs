import Config

config :concord,
  data_dir: "./data/test",
  auth_enabled: false,
  http: [enabled: false]

config :logger, level: :warning
