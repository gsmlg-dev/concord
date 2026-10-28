#!/usr/bin/env bash
set -euo pipefail

# Restart an existing E2E node without deleting its durable storage.
RELEASE_BIN="$1"
DATA_BASE="$2"
COOKIE="$3"
NODE_NAME="$4"

if [[ ! "$NODE_NAME" =~ ^concord_e2e([1-3])@127\.0\.0\.1$ ]]; then
  echo "Invalid E2E node: $NODE_NAME" >&2
  exit 1
fi

NODE_NUMBER="${BASH_REMATCH[1]}"
NODE_DATA="$DATA_BASE/node${NODE_NUMBER}"
test -d "$NODE_DATA"
CLUSTER_NODES="concord_e2e1@127.0.0.1,concord_e2e2@127.0.0.1,concord_e2e3@127.0.0.1"

RELEASE_NODE="$NODE_NAME" \
RELEASE_COOKIE="$COOKIE" \
RELEASE_DISTRIBUTION=name \
CONCORD_DATA_DIR="$NODE_DATA" \
CONCORD_TURSO_ENABLED=true \
CONCORD_TURSO_DATABASE="$NODE_DATA/turso.db" \
CONCORD_VSR_GROUP_ID=concord_cluster \
CONCORD_VSR_REPLICA_ID="$NODE_NAME" \
CONCORD_VSR_MEMBERS="$CLUSTER_NODES" \
CONCORD_VSR_TRANSPORT=distribution \
CONCORD_VSR_STORAGE=file \
CONCORD_VSR_BOOTSTRAP=false \
CONCORD_VSR_COMMAND_VERSION="${CONCORD_VSR_COMMAND_VERSION:-0}" \
NODE_NAME="concord_e2e${NODE_NUMBER}" \
  "$RELEASE_BIN" daemon >> "$DATA_BASE/node${NODE_NUMBER}.log" 2>&1
