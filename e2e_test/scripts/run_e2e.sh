#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Concord E2E Test Orchestrator
#
# Builds an OTP release, starts a 3-node cluster with Gossip
# discovery, waits for Raft leader election, runs RPC-based
# ExUnit tests against the cluster, then tears everything down.
# ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
E2E_DIR="$SCRIPT_DIR/.."

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

COOKIE="concord_e2e_secret"
NODE_COUNT=3
DATA_BASE="$PROJECT_DIR/_build/e2e_data"

cleanup() {
  echo -e "\n${YELLOW}Stopping cluster...${NC}"
  "$SCRIPT_DIR/stop_cluster.sh" "$DATA_BASE" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

echo -e "${YELLOW}═══════════════════════════════════════${NC}"
echo -e "${YELLOW}  Concord E2E Test Suite (Release Mode)${NC}"
echo -e "${YELLOW}═══════════════════════════════════════${NC}"

# ── Step 1: Build release ──────────────────────────────────
echo -e "\n${YELLOW}[1/4] Building OTP release...${NC}"
cd "$PROJECT_DIR"

# Use MIX_CMD from env if set, else default to mix in PATH
MIX_CMD="${MIX_CMD:-mix}"
ELIXIR_CMD="${ELIXIR_CMD:-elixir}"

MIX_ENV=prod $MIX_CMD release concord --overwrite --quiet 2>&1
RELEASE_BIN="$PROJECT_DIR/_build/prod/rel/concord/bin/concord"

if [ ! -f "$RELEASE_BIN" ]; then
  echo -e "${RED}✗ Release build failed${NC}"
  exit 1
fi
echo -e "${GREEN}✓ Release built${NC}"

# ── Step 2: Start cluster ─────────────────────────────────
echo -e "\n${YELLOW}[2/4] Starting ${NODE_COUNT}-node cluster...${NC}"
"$SCRIPT_DIR/start_cluster.sh" "$RELEASE_BIN" "$DATA_BASE" "$COOKIE" "$NODE_COUNT"
echo -e "${GREEN}✓ Cluster started${NC}"

# ── Step 3: Wait for Raft leader ───────────────────────────
echo -e "\n${YELLOW}[3/4] Waiting for Raft leader election...${NC}"

MAX_WAIT=60
ELAPSED=0
LEADER_FOUND=false

while [ $ELAPSED -lt $MAX_WAIT ]; do
  # Use 'rpc' to query the running node (not 'eval' which starts a new VM)
  RESULT=$(RELEASE_NODE="concord_e2e1@127.0.0.1" RELEASE_COOKIE="$COOKIE" \
    "$RELEASE_BIN" rpc "
      case :ra.members({:concord_cluster, node()}) do
        {:ok, _, {_, _}} -> IO.puts(\"leader_ready\")
        _ -> IO.puts(\"waiting\")
      end
    " 2>/dev/null || echo "error")

  if echo "$RESULT" | grep -q "leader_ready"; then
    LEADER_FOUND=true
    break
  fi

  sleep 2
  ELAPSED=$((ELAPSED + 2))
  echo -n "."
done
echo ""

if [ "$LEADER_FOUND" = false ]; then
  echo -e "${RED}✗ Raft leader not elected within ${MAX_WAIT}s${NC}"
  # Show node1 state for debugging
  echo -e "${YELLOW}Debug: Node1 state:${NC}"
  RELEASE_NODE="concord_e2e1@127.0.0.1" RELEASE_COOKIE="$COOKIE" \
    "$RELEASE_BIN" rpc "IO.inspect(Node.list(), label: :peers); IO.inspect(:ra.members({:concord_cluster, node()}), label: :ra)" 2>&1 || true
  exit 1
fi
echo -e "${GREEN}✓ Raft leader elected (${ELAPSED}s)${NC}"

# ── Step 4: Run tests ─────────────────────────────────────
echo -e "\n${YELLOW}[4/4] Running E2E tests via RPC...${NC}\n"

cd "$PROJECT_DIR"

# The test runner connects as a distributed node and runs ExUnit
# tests that use :rpc.call to exercise the cluster.
$ELIXIR_CMD \
  --name "e2e_tester@127.0.0.1" \
  --cookie "$COOKIE" \
  -e "
    # Start ExUnit first (before loading test files)
    ExUnit.start(trace: true, max_failures: 5, timeout: 60_000)

    # Connect to all cluster nodes
    nodes = [
      :\"concord_e2e1@127.0.0.1\",
      :\"concord_e2e2@127.0.0.1\",
      :\"concord_e2e3@127.0.0.1\"
    ]
    Enum.each(nodes, &Node.connect/1)
    Process.sleep(1000)

    # Load support and test files
    Code.require_file(\"$E2E_DIR/support/e2e_cluster.ex\")
    Code.require_file(\"$E2E_DIR/tests/cluster_basics_test.exs\")
    Code.require_file(\"$E2E_DIR/tests/v2_kv_test.exs\")
    Code.require_file(\"$E2E_DIR/tests/v2_txn_test.exs\")
    Code.require_file(\"$E2E_DIR/tests/v2_lease_test.exs\")
    Code.require_file(\"$E2E_DIR/tests/engine_modes_test.exs\")

    ExUnit.run()
    |> case do
      %{failures: 0} -> System.halt(0)
      _ -> System.halt(1)
    end
  "

EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
  echo -e "${GREEN}═══════════════════════════════════${NC}"
  echo -e "${GREEN}  ✓ All E2E tests passed!${NC}"
  echo -e "${GREEN}═══════════════════════════════════${NC}"
else
  echo -e "${RED}═══════════════════════════════════${NC}"
  echo -e "${RED}  ✗ E2E tests failed${NC}"
  echo -e "${RED}═══════════════════════════════════${NC}"
fi

exit $EXIT_CODE
