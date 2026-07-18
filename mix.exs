defmodule Concord.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      apps: [:concord, :ex_turso, :viewstamped_replication],
      elixir: "~> 1.17",
      releases: releases(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix, :iex, :ex_turso],
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
      test: "cmd mix test",
      "test.e2e": "cmd ./e2e_test/scripts/run_e2e.sh",
      lint: ["credo --strict", "cmd --app concord mix dialyzer --ignore-exit-status"]
    ]
  end
end
