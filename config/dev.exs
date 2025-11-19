import Config

config :concord,
  data_dir: "./data/dev",
  auth_enabled: false,
  http: [
    enabled: true,
    port: 4000,
    ip: {127, 0, 0, 1}
  ]

config :logger, level: :debug
