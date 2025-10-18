defmodule Concord.MixProject do
  use Mix.Project

  def project do
    [
      app: :concord,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix, :iex],
        plt_file: {:no_warn, "plts/dialyzer.plt"},
        ignore_warnings: ".dialyzer_ignore.exs",
        flags: [],
        list_unused_filters: false
      ],
      test_coverage: [summary: [threshold: 40]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Concord.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ra, "~> 2.6"},
      {:libcluster, "~> 3.3"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:plug_crypto, "~> 1.2"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.29", only: [:dev, :prod], runtime: false}
    ]
  end

  defp aliases do
    [
      test: "test --no-start"
    ]
  end
end
