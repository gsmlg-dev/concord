#!/usr/bin/env bash
set -e

# Script to run e2e tests with proper distributed Erlang setup
# This ensures the test runner node is started as a distributed node

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Set MIX_ENV
export MIX_ENV=e2e_test

# Function to clean up orphan node processes
cleanup() {
    echo -e "\n${YELLOW}Cleaning up e2e processes...${NC}"
    # Use specific pattern to only kill node processes (concord_e2e1@, concord_e2e2@, etc.)
    pkill -9 -f "concord_e2e[0-9]+@" 2>/dev/null || true
    rm -rf ./data/e2e_test 2>/dev/null || true
}

# Trap to ensure cleanup on exit/interrupt
trap cleanup EXIT INT TERM

# Clean up orphans before starting
cleanup
sleep 1

echo -e "${YELLOW}=== Starting E2E Test Suite ===${NC}"

# Pre-compile to avoid build lock contention
echo -e "${YELLOW}Pre-compiling...${NC}"
mix compile --force

# Parse arguments
TEST_PATH="${1:-e2e_test/}"
NODE_NAME="${NODE_NAME:-test@127.0.0.1}"
COOKIE="${COOKIE:-test_cookie}"

echo -e "${GREEN}✓${NC} MIX_ENV: $MIX_ENV"
echo -e "${GREEN}✓${NC} Test Path: $TEST_PATH"
echo -e "${GREEN}✓${NC} Node Name: $NODE_NAME"
echo -e "${GREEN}✓${NC} Cookie: $COOKIE"

# Ensure EPMD is running (Erlang Port Mapper Daemon)
if ! pgrep -x "epmd" > /dev/null; then
    echo -e "${YELLOW}⚠${NC}  Starting EPMD daemon..."
    epmd -daemon
    sleep 1
fi

echo -e "${GREEN}✓${NC} EPMD is running"

# Run the tests with distributed Erlang
echo -e "\n${YELLOW}Running tests...${NC}\n"

elixir \
  --name "$NODE_NAME" \
  --cookie "$COOKIE" \
  -S mix test "$TEST_PATH" --no-start

TEST_EXIT_CODE=$?

echo -e "\n${YELLOW}=== E2E Test Suite Complete ===${NC}"

exit $TEST_EXIT_CODE
