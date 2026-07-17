defmodule Concord.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      elixir: "~> 1.17",
      releases: releases(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix, :iex],
        plt_file: {:no_warn, "plts/dialyzer.plt"},
        ignore_warnings: ".dialyzer_ignore.exs",
        flags: [],
        list_unused_filters: false
      ]
    ]
  end

  defp releases do
    [
      concord: [
        version: {:from_app, :concord},
        include_executables_for: [:unix],
        applications: [concord: :permanent, runtime_tools: :permanent]
      ]
    ]
  end

  defp aliases do
    [
      test: "test --no-start",
      "test.e2e": "cmd ./e2e_test/scripts/run_e2e.sh",
      lint: ["credo --strict", "dialyzer --ignore-exit-status"]
    ]
  end
end
