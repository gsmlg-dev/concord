#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Concord E2E Test Orchestrator
#
# Builds an OTP release, starts a 3-node VSR cluster, waits for
# readiness, runs RPC-based
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
DATA_BASE="$PROJECT_DIR/_build/e2e_data/vsr"

cleanup() {
  echo -e "\n${YELLOW}Stopping cluster...${NC}"
  "$SCRIPT_DIR/stop_cluster.sh" "$DATA_BASE" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

echo -e "${YELLOW}═══════════════════════════════════════${NC}"
echo -e "${YELLOW}  Concord VSR E2E Test Suite (Release Mode)${NC}"
echo -e "${YELLOW}═══════════════════════════════════════${NC}"

# ── Step 1: Build release ──────────────────────────────────
echo -e "\n${YELLOW}[1/4] Building OTP release...${NC}"
cd "$PROJECT_DIR"

# Use MIX_CMD from env if set, else default to mix in PATH
MIX_CMD="${MIX_CMD:-mix}"
ELIXIR_CMD="${ELIXIR_CMD:-elixir}"

rm -rf "$PROJECT_DIR/_build/prod/rel/concord"
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

# ── Step 3: Wait for VSR readiness ─────────────────────────
echo -e "\n${YELLOW}[3/4] Waiting for VSR readiness...${NC}"

MAX_WAIT=60
ELAPSED=0
PRIMARY_FOUND=false

while [ $ELAPSED -lt $MAX_WAIT ]; do
  # Use 'rpc' to query the running node (not 'eval' which starts a new VM)
  CHECK='
    case Concord.status() do
      {:ok, %{engine: :vsr, cluster: %{status: :normal}}} -> IO.puts("engine_ready")
      _ -> IO.puts("waiting")
    end
  '

  RESULT=$(RELEASE_NODE="concord_e2e1@127.0.0.1" RELEASE_COOKIE="$COOKIE" \
    "$RELEASE_BIN" rpc "$CHECK" 2>/dev/null || echo "error")

  if echo "$RESULT" | grep -q "engine_ready"; then
    PRIMARY_FOUND=true
    break
  fi

  sleep 2
  ELAPSED=$((ELAPSED + 2))
  echo -n "."
done
echo ""

if [ "$PRIMARY_FOUND" = false ]; then
  echo -e "${RED}✗ VSR did not become ready within ${MAX_WAIT}s${NC}"
  # Show node1 state for debugging
  echo -e "${YELLOW}Debug: Node1 state:${NC}"
  RELEASE_NODE="concord_e2e1@127.0.0.1" RELEASE_COOKIE="$COOKIE" \
    "$RELEASE_BIN" rpc "IO.inspect(Node.list(), label: :peers); IO.inspect(Concord.status(), label: :concord)" 2>&1 || true
  exit 1
fi
echo -e "${GREEN}✓ VSR ready (${ELAPSED}s)${NC}"

# ── Step 4: Run tests ─────────────────────────────────────
echo -e "\n${YELLOW}[4/4] Running E2E tests via RPC...${NC}\n"

cd "$PROJECT_DIR"

# The test runner connects as a distributed node and runs ExUnit
# tests that use :rpc.call to exercise the cluster.
set +e

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

if [ $EXIT_CODE -eq 0 ]; then
  $ELIXIR_CMD \
    --name "e2e_failover_tester@127.0.0.1" \
    --cookie "$COOKIE" \
    -e "
      ExUnit.start(trace: true, max_failures: 1, timeout: 60_000)
      nodes = [
        :\"concord_e2e1@127.0.0.1\",
        :\"concord_e2e2@127.0.0.1\",
        :\"concord_e2e3@127.0.0.1\"
      ]
      Enum.each(nodes, &Node.connect/1)
      Code.require_file(\"$E2E_DIR/support/e2e_cluster.ex\")
      Code.require_file(\"$E2E_DIR/tests/vsr_cluster_test.exs\")

      ExUnit.run()
      |> case do
        %{failures: 0} -> System.halt(0)
        _ -> System.halt(1)
      end
    "

  EXIT_CODE=$?
fi

set -e

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
