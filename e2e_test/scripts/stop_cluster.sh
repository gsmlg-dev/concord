#!/usr/bin/env bash
set -euo pipefail

# Stop all E2E cluster nodes and clean up.
# Usage: stop_cluster.sh <data_base>

DATA_BASE="${1:-_build/e2e_data}"

YELLOW='\033[1;33m'
NC='\033[0m'

# Kill any concord_e2e nodes
pkill -f "concord_e2e[0-9]+@" 2>/dev/null || true

# Also try graceful shutdown via release if available
RELEASE_BIN="_build/prod/rel/concord/bin/concord"
if [ -f "$RELEASE_BIN" ]; then
  for pid_file in "$DATA_BASE"/node*.pid; do
    [ -f "$pid_file" ] || continue
    PID=$(cat "$pid_file" 2>/dev/null)
    if [ -n "$PID" ] && [ "$PID" != "unknown" ]; then
      kill "$PID" 2>/dev/null || true
    fi
  done
fi

# Wait for processes to die
sleep 1

# Force kill any remaining
pkill -9 -f "concord_e2e[0-9]+@" 2>/dev/null || true

# Clean up data
rm -rf "$DATA_BASE"

echo -e "${YELLOW}✓ Cluster stopped and cleaned up${NC}"
