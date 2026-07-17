defmodule Concord.MixProject do
  use Mix.Project

  def project do
    [
      app: :concord,
      version: "2.0.1",
      elixir: "~> 1.17",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
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
          "../../docs/v1/getting-started.md",
          "../../docs/v1/elixir-guide.md",
          "../../docs/v1/observability.md",
          "../../docs/v1/backup-restore.md",
          "../../docs/v1/configuration.md",
          "../../docs/v1/DESIGN.md",
          "CHANGELOG.md",
          "LICENSE"
        ],
        api_reference: false,
        groups_for_extras: [
          "Getting Started": [
            "README.md",
            "../../docs/v1/getting-started.md"
          ],
          Guides: [
            "../../docs/v1/elixir-guide.md",
            "../../docs/v1/observability.md",
            "../../docs/v1/backup-restore.md",
            "../../docs/v1/configuration.md"
          ],
          Architecture: [
            "../../docs/v1/DESIGN.md"
          ],
          "Release Notes": [
            "CHANGELOG.md",
            "LICENSE"
          ]
        ]
      ],
      test_coverage: [summary: [threshold: 50]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Concord.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:e2e_test), do: ["lib", "../../e2e_test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Package metadata for Hex.pm
  defp package do
    [
      description:
        "An embedded distributed key-value store for Elixir with Raft consensus. Think SQLite but replicated.",
      licenses: ["MIT"],
      files: [
        "lib",
        "mix.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
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
      {:ra, "~> 3.0"},
      {:libcluster, "~> 3.3"},
      {:telemetry, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:db_connection, "~> 2.10"},
      {:ex_turso, "~> 0.3"},
      # E2E testing (note: LocalCluster removed due to OTP 28 compatibility, using manual node spawning)
      {:http_fetch, "~> 0.10.0", only: [:e2e_test], runtime: false},
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
