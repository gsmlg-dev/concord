defmodule Turso.MixProject do
  use Mix.Project

  @source_url "https://github.com/gsmlg-dev/concord/tree/main/apps/ex_turso"

  def project do
    [
      app: :ex_turso,
      version: "0.4.1",
      elixir: "~> 1.18",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      start_permanent: Mix.env() == :prod,
      description: "DBConnection-backed Elixir wrapper for Turso/libSQL via Rustler",
      source_url: @source_url,
      package: package(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rustler_precompiled, "~> 0.9", runtime: false},
      {:rustler, "~> 0.38", optional: true, runtime: false},
      {:db_connection, "~> 2.7"},
      {:ecto_sql, "~> 3.14", optional: true},
      {:jason, "~> 1.4", optional: true}
    ]
  end

  defp package do
    [
      maintainers: ["Jonathan Gao"],
      licenses: ["MIT"],
      files: [
        ".formatter.exs",
        "lib",
        "mix.exs",
        "checksum-*.exs",
        "native/ex_turso/Cargo.lock",
        "native/ex_turso/Cargo.toml",
        "native/ex_turso/src",
        "README.md",
        "LICENSE",
        "THIRD_PARTY_NOTICES.md"
      ],
      links: %{"GitHub" => @source_url}
    ]
  end
end
