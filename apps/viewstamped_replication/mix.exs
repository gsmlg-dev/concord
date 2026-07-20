defmodule ViewstampedReplication.MixProject do
  use Mix.Project

  @source_url "https://github.com/gsmlg-dev/concord/tree/main/apps/viewstamped_replication"

  def project do
    [
      app: :viewstamped_replication,
      version: "0.2.0",
      elixir: "~> 1.17",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [summary: [threshold: 80]],
      description: "A protocol-generic Viewstamped Replication runtime for Elixir",
      source_url: @source_url,
      homepage_url: "https://github.com/gsmlg-dev/concord",
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md", "LICENSE"]
      ]
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
      {:stream_data, "~> 1.1", only: :test},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Jonathan Gao"],
      licenses: ["MIT"],
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      links: %{
        "GitHub" => @source_url,
        "Concord" => "https://github.com/gsmlg-dev/concord"
      }
    ]
  end
end
