#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

vsr_package="$tmp_dir/viewstamped_replication"
concord_package="$tmp_dir/concord"
consumer="$tmp_dir/consumer"

(
  cd "$repo_root/apps/viewstamped_replication"
  mix hex.build --unpack --output "$vsr_package"
)

(
  cd "$repo_root/apps/concord"
  CONCORD_HEX_BUILD=1 mix hex.build --unpack --output "$concord_package"
)

grep -Fq '{<<"version">>,<<"0.2.0">>}.' \
  "$vsr_package/hex_metadata.config"
grep -Fq '{<<"requirement">>,<<"~> 0.2.0">>}' \
  "$concord_package/hex_metadata.config"

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
  export VSR_PACKAGE_PATH="$vsr_package"
  mix deps.get
  mix compile --warnings-as-errors
)
