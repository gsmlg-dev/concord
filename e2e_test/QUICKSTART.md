# E2E Test Quick Start Guide

Get up and running with Concord's end-to-end tests in under 2 minutes.

## Prerequisites

- ✅ Elixir 1.18+ and OTP 28+ installed
- ✅ At least 4GB free RAM
- ✅ 5-10 minutes for initial setup

## One-Time Setup (30 seconds)

```bash
# 1. Start EPMD (Erlang Port Mapper Daemon)
epmd -daemon

# 2. Install e2e test dependencies
MIX_ENV=e2e_test mix deps.get

# 3. Compile e2e tests
MIX_ENV=e2e_test mix compile
```

✅ **Setup complete!** You're ready to run e2e tests.

## Run Your First E2E Test (30 seconds)

```bash
# Run a simple leader election test (requires named node for LocalCluster)
elixir --name test@127.0.0.1 --cookie test_cookie -S mix test e2e_test/distributed/leader_election_test.exs --trace
```

**Important**: E2E tests require the test node to be a distributed Erlang node (using `--name` flag) because LocalCluster spawns child nodes.

You should see output like:

```
Starting 3-node cluster with prefix 'concord_e2e'...
Started nodes: [:"concord_e2e_1@127.0.0.1", :"concord_e2e_2@127.0.0.1", :"concord_e2e_3@127.0.0.1"]
Initializing Concord on concord_e2e_1@127.0.0.1...
Initializing Concord on concord_e2e_2@127.0.0.1...
Initializing Concord on concord_e2e_3@127.0.0.1...
✓ Cluster ready with 3 nodes

  Leader Election
    ✓ cluster elects a leader on startup (1.2s)
    ✓ new leader elected after current leader dies (8.5s)
    ✓ data remains consistent after leader change (7.3s)

Finished in 17.5 seconds
3 tests, 0 failures
```

🎉 **Success!** Your first e2e test passed.

## Run All E2E Tests (5 minutes)

```bash
# Run all distributed e2e tests
mix test.e2e.distributed
```

This runs:
- ✅ 3 leader election tests
- ✅ 4 network partition tests
- ✅ 5 data consistency tests
- ✅ 3 node failure tests

**Total: ~15 tests in ~5 minutes**

## Common Commands

```bash
# Quick test (single file)
MIX_ENV=e2e_test mix test e2e_test/distributed/leader_election_test.exs

# Full e2e suite
mix test.e2e

# Run with verbose output
MIX_ENV=e2e_test mix test e2e_test/ --trace

# Run specific test by name
MIX_ENV=e2e_test mix test e2e_test/distributed/ --only "cluster elects a leader"
```

## Troubleshooting

### ❌ "epmd: Cannot connect to local epmd"

**Fix:**
```bash
epmd -daemon
```

### ❌ Tests hang or timeout

**Fix:** Clean up orphaned nodes
```bash
pkill -9 beam.smp
rm -rf data/e2e_test/
rm -rf concord_e2e_*
epmd -daemon
```

### ❌ Port already in use

**Fix:**
```bash
epmd -kill
epmd -daemon
```

## Next Steps

- 📖 Read the full documentation: `e2e_test/README.md`
- 🔧 Write your own e2e tests (see template in README)
- 🚀 Run e2e tests in CI (already configured in `.github/workflows/e2e-test.yml`)

## Quick Reference

| Command | Description | Duration |
|---------|-------------|----------|
| `mix test.e2e.distributed` | Run all distributed tests | ~5 min |
| `MIX_ENV=e2e_test mix test e2e_test/distributed/leader_election_test.exs` | Single test file | ~30 sec |
| `MIX_ENV=e2e_test mix test e2e_test/ --trace` | All tests with verbose output | ~5 min |
| `epmd -daemon` | Start Erlang port mapper | Instant |

---

**Need Help?** See the full documentation in `e2e_test/README.md`
