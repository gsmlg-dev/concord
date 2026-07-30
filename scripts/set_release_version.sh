#!/usr/bin/env bash
set -euo pipefail

version="${1:-}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
  echo "invalid release version: $version" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_count=0

for mix_file in "$repo_root"/apps/*/mix.exs; do
  if ! grep -q '^  @version "[^"]*"$' "$mix_file"; then
    echo "missing @version in ${mix_file#"$repo_root"/}" >&2
    exit 1
  fi

  sed -i -E "s/^  @version \"[^\"]*\"$/  @version \"$version\"/" "$mix_file"
  app_count=$((app_count + 1))
done

concord_mix="$repo_root/apps/concord/mix.exs"

if grep -q '^  @ex_turso_version "[^"]*"$' "$concord_mix"; then
  sed -i -E \
    "s/^  @ex_turso_version \"[^\"]*\"$/  @ex_turso_version \"$version\"/" \
    "$concord_mix"
fi

if [[ "$app_count" -eq 0 ]]; then
  echo "no umbrella applications found" >&2
  exit 1
fi

for mix_file in "$repo_root"/apps/*/mix.exs; do
  if ! grep -q "^  @version \"$version\"$" "$mix_file"; then
    echo "failed to set ${mix_file#"$repo_root"/} to $version" >&2
    exit 1
  fi

  app_name="$(basename "$(dirname "$mix_file")")"
  echo "$app_name=$version"
done

if ! grep -q "^  @ex_turso_version \"$version\"$" "$concord_mix"; then
  echo "failed to set Concord's ex_turso dependency to $version" >&2
  exit 1
fi
