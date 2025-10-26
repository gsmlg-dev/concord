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
      package: package(),
      name: "Concord",
      source_url: "https://github.com/gsmlg-dev/concord",
      homepage_url: "https://github.com/gsmlg-dev/concord",
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "API_DESIGN.md",
          "PERFORMANCE_SUMMARY.md",
          "PERFORMANCE_ANALYSIS.md",
          "CHANGELOG.md",
          "LICENSE"
        ],
        api_reference: false,
        groups_for_extras: [
          "Getting Started": [
            "README.md",
            "LICENSE"
          ],
          "API Documentation": [
            "API_DESIGN.md"
          ],
          Performance: [
            "PERFORMANCE_SUMMARY.md",
            "PERFORMANCE_ANALYSIS.md"
          ],
          "Release Notes": [
            "CHANGELOG.md"
          ]
        ]
      ],
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

  # Package metadata for Hex.pm
  defp package do
    [
      description:
        "A high-performance embedded distributed key-value store for Elixir applications with 600K+ ops/sec and REST API",
      licenses: ["MIT"],
      files: [
        "lib",
        "mix.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        "API_DESIGN.md",
        "PERFORMANCE_SUMMARY.md",
        "PERFORMANCE_ANALYSIS.md",
        "openapi.json",
        "run_benchmarks.exs",
        "config",
        "test"
      ],
      links: %{
        "GitHub" => "https://github.com/gsmlg-dev/concord",
        "Documentation" => "https://hexdocs.pm/concord",
        "Performance Benchmarks" => "https://github.com/gsmlg-dev/concord#performance-benchmarks",
        "API Reference" => "https://hexdocs.pm/concord/api-reference.html"
      }
    ]
  end

  defp deps do
    [
      {:ra, "~> 2.6"},
      {:libcluster, "~> 3.3"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:telemetry_metrics_prometheus, "~> 1.1"},
      {:jason, "~> 1.4"},
      {:plug_crypto, "~> 1.2"},
      {:plug, "~> 1.15"},
      {:bandit, "~> 1.5"},
      {:plug_cowboy, "~> 2.6"},
      # OpenTelemetry distributed tracing
      {:opentelemetry_api, "~> 1.3"},
      {:opentelemetry, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.7"},
      {:opentelemetry_telemetry, "~> 1.1"},
      # Event streaming with GenStage
      {:gen_stage, "~> 1.2"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.29", only: [:dev, :prod], runtime: false}
    ]
  end

  defp aliases do
    [
      test: "test --no-start",
      lint: ["credo --strict", "dialyzer --ignore-exit-status"]
    ]
  end
end
