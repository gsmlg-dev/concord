#!/usr/bin/env bash
set -euo pipefail

# Start N Concord release nodes for E2E testing.
# Usage: start_cluster.sh <release_bin> <data_base> <cookie> <node_count>

RELEASE_BIN="$1"
DATA_BASE="$2"
COOKIE="$3"
NODE_COUNT="${4:-3}"

GREEN='\033[0;32m'
NC='\033[0m'

# Ensure EPMD is running
epmd -daemon 2>/dev/null || true

# Clean previous data
rm -rf "$DATA_BASE"

# Build the cluster nodes list for Epmd discovery
CLUSTER_NODES=""
for i in $(seq 1 "$NODE_COUNT"); do
  if [ -n "$CLUSTER_NODES" ]; then
    CLUSTER_NODES="${CLUSTER_NODES},"
  fi
  CLUSTER_NODES="${CLUSTER_NODES}concord_e2e${i}@127.0.0.1"
done

for i in $(seq 1 "$NODE_COUNT"); do
  NODE_NAME="concord_e2e${i}@127.0.0.1"
  NODE_DATA="$DATA_BASE/node${i}"
  PID_FILE="$DATA_BASE/node${i}.pid"
  LOG_FILE="$DATA_BASE/node${i}.log"

  mkdir -p "$NODE_DATA"

  # Start the release as a daemon with cluster discovery env
  RELEASE_NODE="$NODE_NAME" \
  RELEASE_COOKIE="$COOKIE" \
  RELEASE_DISTRIBUTION=name \
  CONCORD_DATA_DIR="$NODE_DATA" \
  CONCORD_TURSO_ENABLED="true" \
  CONCORD_TURSO_DATABASE="$NODE_DATA/turso.db" \
  CONCORD_VSR_GROUP_ID="concord_cluster" \
  CONCORD_VSR_REPLICA_ID="$NODE_NAME" \
  CONCORD_VSR_MEMBERS="$CLUSTER_NODES" \
  CONCORD_VSR_TRANSPORT="distribution" \
  CONCORD_VSR_STORAGE="file" \
  CONCORD_VSR_BOOTSTRAP="true" \
  NODE_NAME="concord_e2e${i}" \
    "$RELEASE_BIN" daemon \
    > "$LOG_FILE" 2>&1

  # Give the node a moment to start
  sleep 1

  echo -e "${GREEN}✓${NC} Started $NODE_NAME"
done

# Wait for VSR cluster formation
echo "  Waiting for cluster formation..."
sleep 8
