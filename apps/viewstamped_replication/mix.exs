defmodule ViewstampedReplication.MixProject do
  use Mix.Project

  def project do
    [
      app: :viewstamped_replication,
      version: "0.1.0",
      elixir: "~> 1.17",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [summary: [threshold: 80]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :telemetry],
      mod: {ViewstampedReplication.Application, []}
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
