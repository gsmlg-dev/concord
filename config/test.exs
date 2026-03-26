import Config

config :concord,
  data_dir: "./data/test",
  http: [enabled: false],
  ets_access_mode: :public

config :logger, level: :warning
