#!/usr/bin/env sh
set -eu

consumer="$(mktemp -d)"
trap 'rm -rf "$consumer"' EXIT

if [ -n "${LEGACY_PACKAGE_PATH:-}" ]; then
  mkdir "$consumer/packages"
  cp -R "$LEGACY_PACKAGE_PATH/concord" "$LEGACY_PACKAGE_PATH/ex_turso" "$consumer/packages/"
  LEGACY_PACKAGE_PATH="$consumer/packages"
  export LEGACY_PACKAGE_PATH
fi

cat >"$consumer/mix.exs" <<'EOF'
defmodule ConcordLegacyConsumer.MixProject do
  use Mix.Project

  def project do
    [app: :concord_legacy_consumer, version: "0.1.0", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    case System.get_env("LEGACY_PACKAGE_PATH") do
      nil ->
        [
          {:gsmlg_whois, "0.5.1"},
          {:concord, "~> 2.4.1"},
          {:ex_turso, "~> 0.3.2"}
        ]

      path ->
        [
          {:gsmlg_whois, "0.5.1"},
          {:concord, path: Path.join(path, "concord"), override: true},
          {:ex_turso, path: Path.join(path, "ex_turso"), override: true}
        ]
    end
  end
end
EOF

cat >"$consumer/probe.exs" <<'EOF'
{:ok, _} = Application.ensure_all_started(:ex_turso)
~c"2.4.1" = Application.spec(:concord, :vsn)
~c"0.3.2" = Application.spec(:ex_turso, :vsn)
~c"0.5.1" = Application.spec(:gsmlg_whois, :vsn)

path = Path.expand("probe.db")
{:ok, pool} = ExTurso.start_link(database: path, pool_size: 1)
{:ok, _} = ExTurso.execute(pool, "CREATE TABLE probe (id INTEGER PRIMARY KEY, value TEXT)")
{:ok, _} = ExTurso.execute(pool, "INSERT INTO probe VALUES (?, ?)", [1, "musl"])
{:ok, %ExTurso.Result{rows: [%{"value" => "musl"}]}} =
  ExTurso.query(pool, "SELECT value FROM probe WHERE id = ?", [1])
GenServer.stop(pool)

{:ok, reopened} = ExTurso.start_link(database: path, pool_size: 1)
{:ok, %ExTurso.Result{rows: [%{"value" => "musl"}]}} =
  ExTurso.query(reopened, "SELECT value FROM probe WHERE id = ?", [1])
GenServer.stop(reopened)
IO.puts("WHOIS 0.5.1 / Concord 2.4.1 / ExTurso 0.3.2 consumer and persistence checks passed")
EOF

cd "$consumer"
mix local.hex --force
mix local.rebar --force
attempt=1
until mix deps.get; do
  if [ "$attempt" -ge 12 ]; then
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 10
done
mix compile --warnings-as-errors
mix run --no-start probe.exs
