defmodule Concord.MixProject do
  use Mix.Project

  def project do
    [
      app: :concord,
      version: "1.1.0",
      elixir: "~> 1.15",
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
          "docs/getting-started.md",
          "docs/elixir-guide.md",
          "docs/observability.md",
          "docs/backup-restore.md",
          "docs/configuration.md",
          "docs/DESIGN.md",
          "CHANGELOG.md",
          "LICENSE"
        ],
        api_reference: false,
        groups_for_extras: [
          "Getting Started": [
            "README.md",
            "docs/getting-started.md"
          ],
          Guides: [
            "docs/elixir-guide.md",
            "docs/observability.md",
            "docs/backup-restore.md",
            "docs/configuration.md"
          ],
          Architecture: [
            "docs/DESIGN.md"
          ],
          "Release Notes": [
            "CHANGELOG.md",
            "LICENSE"
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
  defp elixirc_paths(:e2e_test), do: ["lib", "e2e_test/support"]
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
        "docs",
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
      {:ra, "~> 3.0"},
      {:libcluster, "~> 3.3"},
      {:telemetry, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.4"},
      # E2E testing (note: LocalCluster removed due to OTP 28 compatibility, using manual node spawning)
      {:httpoison, "~> 2.0", only: [:e2e_test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.29", only: [:dev, :prod], runtime: false}
    ]
  end

  defp aliases do
    [
      test: "test --no-start",
      "test.e2e": "cmd ./scripts/run_e2e_tests.sh e2e_test/",
      "test.e2e.distributed": "cmd ./scripts/run_e2e_tests.sh e2e_test/distributed/",
      "test.e2e.docker": "cmd ./scripts/run_e2e_tests.sh e2e_test/docker/",
      lint: ["credo --strict", "dialyzer --ignore-exit-status"]
    ]
  end
end
