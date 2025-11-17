# End-to-End (E2E) Tests for Concord

This directory contains end-to-end tests for Concord that verify distributed behavior across multiple nodes in realistic scenarios.

## Overview

The e2e tests are **completely separate** from unit tests (`test/`) and focus on:

- **Multi-node Raft consensus** (leader election, log replication)
- **Network partition scenarios** (split-brain, quorum behavior)
- **Node failure and recovery** (crash tolerance, data consistency)
- **Distributed data consistency** (replication, concurrent writes, TTL)

### Why Separate E2E Tests?

1. **Different execution environment**: Uses `MIX_ENV=e2e_test` with LocalCluster for actual multi-node testing
2. **Longer execution time**: E2E tests take 5-15 minutes vs. unit tests ~1-2 minutes
3. **Resource intensive**: Spawns multiple Erlang VMs (3-5 nodes per test)
4. **Different CI strategy**: Run on schedule/manual trigger rather than every commit

## Directory Structure

```
e2e_test/
├── README.md                          # This file
├── test_helper.exs                    # E2E test configuration
├── support/
│   └── e2e_cluster_helper.ex          # Multi-node cluster management utilities
├── distributed/
│   ├── leader_election_test.exs       # Leader election scenarios
│   ├── network_partition_test.exs     # Network partition handling
│   ├── data_consistency_test.exs      # Replication and consistency
│   └── node_failure_test.exs          # Node crash and recovery
└── docker/                            # Docker-based integration tests (future)
```

## Running E2E Tests

### Prerequisites

- Elixir 1.18+ and OTP 28+
- EPMD (Erlang Port Mapper Daemon) running
- At least 4GB RAM available for multi-node clusters

### Local Development

```bash
# Run all e2e tests
mix test.e2e

# Run only distributed tests
mix test.e2e.distributed

# Run specific test file
MIX_ENV=e2e_test mix test e2e_test/distributed/leader_election_test.exs

# Run with verbose output
MIX_ENV=e2e_test mix test e2e_test/ --trace

# Run specific test by line number
MIX_ENV=e2e_test mix test e2e_test/distributed/leader_election_test.exs:15
```

### First Time Setup

```bash
# Install e2e test dependencies
MIX_ENV=e2e_test mix deps.get

# Compile e2e tests
MIX_ENV=e2e_test mix compile

# Start EPMD if not running
epmd -daemon
```

### CI/CD Execution

E2E tests run automatically in GitHub Actions:

- **On every push/PR**: Distributed tests (`e2e-distributed` job)
- **Nightly (2 AM UTC)**: Full test suite including Docker tests
- **Manual trigger**: Use "Run workflow" button in GitHub Actions

See `.github/workflows/e2e-test.yml` for details.

## Test Categories

### 1. Leader Election Tests (`distributed/leader_election_test.exs`)

Tests Raft leader election behavior:

- ✅ Cluster elects a leader on startup
- ✅ New leader elected after current leader dies
- ✅ Data remains consistent after leader change

**Example:**
```bash
MIX_ENV=e2e_test mix test e2e_test/distributed/leader_election_test.exs
```

### 2. Network Partition Tests (`distributed/network_partition_test.exs`)

Tests cluster behavior during network partitions:

- ✅ Majority partition continues to serve requests (3-2 split)
- ✅ Minority partition cannot serve writes (no quorum)
- ✅ Cluster recovers after partition heals
- ✅ No split-brain after partition heals

**Example:**
```bash
MIX_ENV=e2e_test mix test e2e_test/distributed/network_partition_test.exs
```

### 3. Data Consistency Tests (`distributed/data_consistency_test.exs`)

Tests data replication and consistency:

- ✅ Writes are replicated to all nodes
- ✅ Concurrent writes maintain consistency (100 concurrent ops)
- ✅ Bulk operations maintain consistency (50 keys)
- ✅ TTL expiration is consistent across nodes
- ✅ Delete operations are replicated

**Example:**
```bash
MIX_ENV=e2e_test mix test e2e_test/distributed/data_consistency_test.exs
```

### 4. Node Failure Tests (`distributed/node_failure_test.exs`)

Tests node crash and recovery scenarios:

- ✅ Cluster continues operating with one node down
- ✅ Node catches up after restart (log replay)
- ✅ Cluster handles rapid node failures

**Example:**
```bash
MIX_ENV=e2e_test mix test e2e_test/distributed/node_failure_test.exs
```

## Writing New E2E Tests

### Test Template

```elixir
defmodule Concord.E2E.YourTest do
  use ExUnit.Case, async: false
  alias Concord.E2E.ClusterHelper

  @moduletag :e2e
  @moduletag :distributed

  setup do
    # Start cluster before each test
    {:ok, nodes} = ClusterHelper.start_cluster(nodes: 3)

    # Clean up after test
    on_exit(fn ->
      ClusterHelper.stop_cluster(nodes)
    end)

    %{nodes: nodes}
  end

  describe "Your Feature" do
    test "your scenario", %{nodes: nodes} do
      # Find leader
      leader = ClusterHelper.find_leader(nodes)

      # Perform operations via RPC
      :ok = :rpc.call(leader, Concord, :put, ["test:key", "value"])

      # Assert expected behavior
      {:ok, "value"} = :rpc.call(leader, Concord, :get, ["test:key"])
    end
  end
end
```

### Best Practices

1. **Use `async: false`**: E2E tests spawn actual nodes, can't run in parallel
2. **Clean up in `on_exit`**: Always stop clusters to free resources
3. **Add delays for stabilization**: Network operations need time (1-3 seconds)
4. **Use descriptive tags**: Tag tests as `:e2e`, `:distributed`, `:docker`, etc.
5. **Test one scenario per test**: Keep tests focused and debuggable
6. **Use `IO.puts` for progress**: Helps debug long-running tests

### Cluster Helper Functions

```elixir
# Start cluster
{:ok, nodes} = ClusterHelper.start_cluster(nodes: 5, prefix: "my_test")

# Find current leader
leader = ClusterHelper.find_leader(nodes)

# Create network partition (3-2 split)
{majority, minority} = ClusterHelper.partition_network(nodes, {3, 2})

# Heal partition
ClusterHelper.heal_partition(nodes)

# Kill a node
ClusterHelper.kill_node(node)

# Restart a node
{:ok, restarted} = ClusterHelper.restart_node("prefix", index)

# Wait for node to sync
:ok = ClusterHelper.wait_for_sync(node, timeout_ms)

# Stop cluster
ClusterHelper.stop_cluster(nodes)
```

## Troubleshooting

### Common Issues

**Problem: `epmd: Cannot connect to local epmd`**
```bash
# Solution: Start EPMD
epmd -daemon
```

**Problem: Tests timeout or hang**
```bash
# Solution: Clean up orphaned nodes
pkill -9 beam.smp
rm -rf data/e2e_test/
rm -rf concord_e2e_*
```

**Problem: Port already in use**
```bash
# Solution: Check for running Erlang nodes
epmd -names
# Kill specific node
epmd -kill
```

**Problem: Out of memory**
```bash
# Solution: Reduce node count or run fewer tests in parallel
MIX_ENV=e2e_test mix test e2e_test/distributed/leader_election_test.exs
```

### Debug Mode

Run with verbose output to see cluster formation:

```bash
MIX_ENV=e2e_test mix test e2e_test/ --trace --max-failures 1
```

### Clean State

If tests are failing due to dirty state:

```bash
# Clean all test data
rm -rf data/e2e_test/
rm -rf concord_e2e_*
rm -rf nonode@nohost/

# Restart EPMD
epmd -kill
epmd -daemon
```

## Performance Expectations

| Test Suite | Duration | Nodes | Memory |
|------------|----------|-------|--------|
| Leader Election | ~30s | 3 | ~500MB |
| Network Partition | ~60s | 5 | ~800MB |
| Data Consistency | ~45s | 3 | ~600MB |
| Node Failure | ~90s | 3 | ~700MB |
| **Full E2E Suite** | **~5min** | **3-5** | **~1GB** |

## CI/CD Integration

### GitHub Actions Workflow

```yaml
# .github/workflows/e2e-test.yml
jobs:
  e2e-distributed:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.18'
          otp-version: '28'
      - run: epmd -daemon
      - run: MIX_ENV=e2e_test mix deps.get
      - run: MIX_ENV=e2e_test mix test e2e_test/distributed/
```

### Local Pre-Push Hook

Add to `.git/hooks/pre-push`:

```bash
#!/bin/bash
echo "Running e2e tests before push..."
MIX_ENV=e2e_test mix test e2e_test/distributed/
```

## Future Enhancements

Planned additions to the e2e test suite:

- [ ] **Docker-based tests**: True network isolation with Testcontainers
- [ ] **HTTP API e2e tests**: Test REST API across multi-node cluster
- [ ] **Chaos testing**: Random failure injection (Jepsen-style)
- [ ] **Property-based tests**: Use PropCheck for distributed properties
- [ ] **Load testing**: Concurrent client stress tests
- [ ] **Kubernetes tests**: Helm chart deployment testing

## Resources

- [Concord Documentation](../README.md)
- [LocalCluster Library](https://hexdocs.pm/local_cluster/)
- [Raft Consensus Algorithm](https://raft.github.io/)
- [Distributed Systems Testing Patterns](https://jepsen.io/)

## Contributing

When adding new e2e tests:

1. Create test file in appropriate directory (`distributed/`, `docker/`, etc.)
2. Use the test template above
3. Add tags: `@moduletag :e2e` and category tag
4. Document the test scenario in this README
5. Ensure tests clean up resources in `on_exit`
6. Run locally before pushing: `mix test.e2e`

## License

Same as Concord project - see [LICENSE](../LICENSE)
