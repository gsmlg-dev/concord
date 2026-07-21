#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

concord_package="$tmp_dir/concord"
ex_turso_package="$tmp_dir/ex_turso"
vsr_package="$tmp_dir/viewstamped_replication"
consumer="$tmp_dir/consumer"

release_version="$(sed -n 's/^  @version "\([^"]*\)"$/\1/p' "$repo_root/apps/concord/mix.exs")"
test -n "$release_version"

for app_dir in "$repo_root"/apps/*; do
  mix_file="$app_dir/mix.exs"
  test -f "$mix_file" || continue

  app_name="$(basename "$app_dir")"
  app_version="$(sed -n 's/^  @version "\([^"]*\)"$/\1/p' "$mix_file")"

  if [[ "$app_version" != "$release_version" ]]; then
    echo "$app_name version $app_version does not match Concord $release_version" >&2
    exit 1
  fi

  (
    cd "$app_dir"
    CONCORD_HEX_BUILD=1 mix hex.build --unpack --output "$tmp_dir/$app_name"
  )

  grep -Fq "{<<\"version\">>,<<\"$release_version\">>}." \
    "$tmp_dir/$app_name/hex_metadata.config"
done

same_version_requirement="{<<\"requirement\">>,<<\"$release_version\">>}"
same_version_dependency_count="$(grep -Fc "$same_version_requirement" \
  "$concord_package/hex_metadata.config" || true)"

if [[ "$same_version_dependency_count" -ne 2 ]]; then
  echo "Concord does not require both umbrella packages at $release_version" >&2
  exit 1
fi

mkdir -p "$consumer/lib"

cat >"$consumer/mix.exs" <<'EOF'
defmodule ConcordHexConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :concord_hex_consumer,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:concord, path: System.fetch_env!("CONCORD_PACKAGE_PATH")},
      {:ex_turso, path: System.fetch_env!("EX_TURSO_PACKAGE_PATH"), override: true},
      {:viewstamped_replication,
       path: System.fetch_env!("VSR_PACKAGE_PATH"), override: true}
    ]
  end
end
EOF

cat >"$consumer/lib/concord_hex_consumer.ex" <<'EOF'
defmodule ConcordHexConsumer do
  def read_probe do
    ViewstampedReplication.read(:package_check, :probe,
      replica_id: :replica,
      replicas: []
    )
  end
end

defmodule ConcordHexConsumer.StateMachine do
  @behaviour ViewstampedReplication.StateMachine

  @impl true
  def init(_opts), do: %{}

  @impl true
  def apply(_metadata, operation, state), do: {operation, state}

  @impl true
  def read(_metadata, operation, _state), do: operation

  @impl true
  def snapshot(state), do: {:ok, state}

  @impl true
  def restore(snapshot), do: {:ok, snapshot}
end
EOF

(
  cd "$consumer"
  export CONCORD_HEX_BUILD=1
  export CONCORD_PACKAGE_PATH="$concord_package"
  export EX_TURSO_PACKAGE_PATH="$ex_turso_package"
  export VSR_PACKAGE_PATH="$vsr_package"
  mix deps.get
  mix compile --warnings-as-errors
)
