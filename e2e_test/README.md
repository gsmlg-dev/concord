# End-to-End (E2E) Tests for Concord

This directory contains release-mode E2E tests that verify distributed behavior
across a real 3-node OTP release cluster.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    run_e2e.sh                                │
│                                                             │
│  1. mix release concord          (build OTP release)        │
│  2. start_cluster.sh             (3 daemon nodes)           │
│  3. wait for Raft leader         (rpc health check)         │
│  4. elixir --name tester@...     (ExUnit via RPC)           │
│  5. stop_cluster.sh              (cleanup)                  │
└─────────────────────────────────────────────────────────────┘
```

**Key design decisions:**
- **Release mode**: Tests run against real `_build/prod/rel/concord` binaries
- **RPC-based**: Test runner connects as a 4th distributed node, uses `:rpc.call`
- **Epmd discovery**: `CONCORD_CLUSTER_NODES` env var provides deterministic peer discovery
- **No LocalCluster**: Avoids OTP 28+ compatibility issues

## Running

```bash
# Run all E2E tests (builds release automatically)
./e2e_test/scripts/run_e2e.sh

# Or via mix alias
mix test.e2e
```

### Prerequisites

- Elixir 1.18+ / OTP 28+
- EPMD running (`epmd -daemon`)
- ~1GB RAM for 3-node cluster

## Test Suite (20 tests)

### Cluster Basics (`tests/cluster_basics_test.exs`)
- All 3 nodes connected
- Raft leader elected
- Writes replicate to all nodes
- Concurrent writes (50 ops) maintain consistency
- Deletes replicate
- Bulk `put_many` replicates

### MVCC / KV (`tests/v2_kv_test.exs`)
- Cluster revision consistency across nodes
- MVCC version tracking on updates
- Tombstone deletes are consistent
- Prefix list returns correct records
- Pagination with `limit` and `has_more`

### Transactions (`tests/v2_txn_test.exs`)
- Atomic create-if-absent
- Concurrent race — exactly 1 of 10 wins
- Multi-key atomic transfer
- Prefix delete in transaction
- Failed compare prevents mutation

### Leases (`tests/v2_lease_test.exs`)
- Grant lease replicates
- Revoke lease cascades key deletion
- Keep-alive refreshes lease TTL
- List leases returns active leases

## Directory Structure

```
e2e_test/
├── scripts/
│   ├── run_e2e.sh           # Orchestrator: build → start → test → stop
│   ├── start_cluster.sh     # Start 3 release nodes as daemons
│   └── stop_cluster.sh      # Kill nodes and clean data
├── support/
│   └── e2e_cluster.ex       # RPC helpers (find_leader, wait_replicated, etc.)
├── tests/
│   ├── cluster_basics_test.exs
│   ├── v2_kv_test.exs
│   ├── v2_txn_test.exs
│   └── v2_lease_test.exs
└── README.md
```

## CI/CD

The E2E workflow (`.github/workflows/e2e-test.yml`) runs on:
- Every push to `main` / `develop`
- Pull requests to `main`
- Nightly at 2 AM UTC
- Manual trigger

## Troubleshooting

**Orphaned nodes:**
```bash
pkill -9 -f "concord_e2e"
rm -rf _build/e2e_data
```

**EPMD not running:**
```bash
epmd -daemon
```

**Leader election timeout:**
Check node logs in `_build/e2e_data/node*.log`
