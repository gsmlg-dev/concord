# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Concord is a distributed, strongly-consistent **embedded** key-value store built in Elixir using the Raft consensus algorithm. It's a CP (Consistent + Partition-tolerant) system designed to be included as a dependency in Elixir applications, providing distributed coordination, configuration management, and service discovery with microsecond-level performance (600K-870K ops/sec).

**Key Design Philosophy**: Concord is an embedded database that starts with your application - no separate infrastructure needed. Think SQLite for distributed coordination.

## Development Commands

### Building and Testing
```bash
# Compile the project
mix compile

# Run all tests
mix test

# Run specific test file
mix test test/concord_test.exs

# Run specific test by line number
mix test test/concord_test.exs:42

# Run with coverage
mix test --cover

# Run linting
mix credo

# Run type checking (first run generates PLT file - slow)
mix dialyzer

# Start HTTP API server in development
mix start

# Start HTTP API server with specific port
CONCORD_API_PORT=8080 mix start
```

### Cluster Management
```bash
# Start multiple nodes (separate terminals)
iex --name n1@127.0.0.1 --cookie secret -S mix
iex --name n2@127.0.0.1 --cookie secret -S mix
iex --name n3@127.0.0.1 --cookie secret -S mix

# Check cluster status
mix concord.cluster status

# List cluster members
mix concord.cluster members

# Create authentication token
mix concord.cluster token create

# Revoke a token
mix concord.cluster token revoke <token>

# Generate self-signed TLS certificates for development
mix concord.gen.cert

# Generate with custom options
mix concord.gen.cert --out priv/cert --host myhost.local --days 730
```

### TLS/HTTPS Configuration
```bash
# Enable HTTPS in config/dev.exs or config/prod.exs
config :concord, :tls,
  enabled: true,
  certfile: "priv/cert/selfsigned.pem",
  keyfile: "priv/cert/selfsigned_key.pem"

# For production, use CA-signed certificates:
config :concord, :tls,
  enabled: true,
  certfile: "/etc/letsencrypt/live/yourdomain.com/fullchain.pem",
  keyfile: "/etc/letsencrypt/live/yourdomain.com/privkey.pem",
  cacertfile: "/etc/letsencrypt/live/yourdomain.com/chain.pem"  # Optional: for client cert verification
```

### Testing with Multiple Nodes
The test suite is configured with `--no-start` alias to avoid automatic cluster startup, allowing proper multi-node testing scenarios.

### Code Quality
- **Linting**: Credo is configured with a custom ruleset in `.credo.exs` with max line length of 120
- **Type Checking**: Dialyzer is configured for static analysis with PLT files in `plts/dialyzer.plt`
- **Coverage**: Test coverage threshold is set to 40% with detailed summaries

## Architecture Overview

### Core Components
- **Concord** (`lib/concord.ex`) - Main client API module with all public functions
- **Concord.Application** - Supervisor tree starting Ra cluster, HTTP server, telemetry, etc.
- **Concord.StateMachine** - Raft state machine (`:ra_machine` behavior) implementing KV store
  - Version 2 (includes secondary index support)
  - Stores data in ETS table `:concord_store`
  - State format: `{:concord_kv, %{indexes: map()}}`
  - Handles compression/decompression transparently
- **Concord.Auth** - Token-based authentication with ETS token store
- **Concord.Telemetry** - Metrics emission for all operations
- **Concord.Prometheus** - Prometheus metrics exporter (port 9568)
- **Concord.Tracing** - OpenTelemetry distributed tracing integration
- **Concord.AuditLog** - Immutable compliance audit logging
- **Concord.Compression** - Automatic value compression (zlib/gzip)
- **Concord.TTL** - Time-to-live key expiration management
- **Concord.Backup** - Snapshot-based backup and restore
- **Concord.Query** - Advanced query language (pattern matching, ranges, predicates)
- **Concord.Index** - Secondary indexes for value-based lookups
- **Concord.EventStream** - Real-time CDC event streaming with GenStage
- **Concord.Web** - HTTP/HTTPS API with OpenAPI/Swagger (Plug + Bandit)
  - TLS/HTTPS support with configurable certificates
  - Secure cipher suites (TLS 1.2 and 1.3)
  - Optional client certificate verification

### Key Dependencies
- **ra** - Raft consensus algorithm implementation
- **libcluster** - Automatic node discovery via gossip protocol
- **telemetry** - Metrics and observability framework
- **jason** - JSON serialization for data storage
- **plug_crypto** - Cryptographic utilities for secure token generation

### Data Flow
1. **Write Operations**:
   - Client API (`Concord.put/3`) → Auth verification → Command validation
   - → `:ra.process_command({:concord_cluster, node()}, command, timeout)`
   - → Raft leader → Quorum replication → `StateMachine.apply_command/3`
   - → ETS insert + Index updates + Telemetry events

2. **Read Operations**:
   - Client API (`Concord.get/2`) → Auth verification
   - → `:ra.consistent_query` or `:ra.local_query` (based on consistency level)
   - → `StateMachine.query/2` → ETS lookup → Decompress → Return value

3. **Cluster Management**:
   - libcluster gossip → Automatic node discovery → Raft cluster membership
   - Ra handles leader election, log replication, and snapshots automatically

### Critical Implementation Details

**State Machine Behavior:**
- All operations must go through Raft consensus (via `process_command`) for writes
- Reads use `consistent_query` (linearizable) or `local_query` (eventual consistency)
- Server ID format: `{:concord_cluster, node()}` - NOT `{Concord.StateMachine, node()}`
- Query functions return `{:ok, result}`, which Ra wraps as `{:ok, {:ok, result}, leader_info}`
- Always unwrap the nested result when calling Ra queries

**Compression:**
- Values are compressed before storage if > threshold (default 1KB)
- State machine decompresses automatically via `Concord.Compression.decompress/1`
- Index extractors receive decompressed values

**Index Updates:**
- Indexes update automatically on put/delete in state machine
- Each index has its own ETS table: `:concord_index_#{index_name}`
- Index definitions stored in state: `%{indexes: %{name => extractor_fn}}`

### State Machine Details
The `Concord.StateMachine` implements the `:ra_machine` behavior and uses:
- ETS table `:concord_store` for in-memory storage
- Telemetry events for all operations
- Snapshot support for recovery
- Query functions for reads (bypass Raft log for performance)

### Authentication System
- Token-based authentication using secure crypto
- ETS-based token store for fast lookups
- Per-environment configuration
- Token creation and revocation operations

## Configuration

The configuration follows standard Elixir patterns with environment-specific files:
- `config/config.exs` - Base configuration with cluster name and libcluster topology
- `config/dev.exs` - Development settings with auth disabled and local data directory
- `config/test.exs` - Test configuration with `--no-start` alias for multi-node testing
- `config/prod.exs` - Production settings with auth enabled and environment variables
- `config/runtime.exs` - Runtime configuration loaded at startup

### Development (config/dev.exs)
- Auth disabled by default
- Local data directory: `./data/dev`
- Debug logging enabled

### Production (config/prod.exs)
- Auth enabled by default
- Environment variable configuration
- Info logging level

## Testing Strategy

Test categories:
- **Unit Tests**: Basic CRUD operations, validation (e.g., `test/concord_test.exs`)
- **Feature Tests**: TTL, compression, bulk operations, queries, indexes
- **Auth Tests**: Token management, authorization flows
- **Telemetry Tests**: Event emission verification
- **Integration Tests**: Multi-node scenarios, HTTP API
- **Performance Tests**: Benchmarks in `test/performance/`

**Important Testing Notes:**
- Tests use `Concord.TestHelper.start_test_cluster()` to initialize Ra cluster
- Each test should clean up data in setup block to avoid pollution
- Some tests may need `Process.sleep/1` to wait for cluster initialization
- The `--no-start` alias prevents automatic application startup during tests
- State machine version changes require cluster restart or data cleanup
- Tests run with `async: false` to avoid Ra cluster conflicts

**Running Performance Benchmarks:**
```bash
# Run all benchmarks
mix run run_benchmarks.exs

# Run specific benchmark
mix run test/performance/kv_operations_benchmark.exs
```

## Operational Notes

### Performance Characteristics
- **Writes**: ~5-20ms (requires quorum)
- **Reads**: ~1-5ms (leader query + ETS lookup)
- **Storage**: In-memory only (limited by RAM)
- **Keys**: Max 1024 bytes
- **Values**: No hard limit (consider memory usage)

### Common Troubleshooting
- Check Erlang cookie consistency across nodes
- Verify network connectivity between nodes
- Monitor Raft commit index for cluster health
- Track leader changes via telemetry events

### Important File Locations
- Raft logs and snapshots: `{data_dir}/` (default: `./data/dev` in development)
- Ra data directory: `nonode@nohost/` (gitignored - test artifacts)
- ETS tables: `:concord_store` (main KV), `:concord_index_*` (per-index)
- Telemetry events: `[:concord, :api, :*]`, `[:concord, :operation, :*]`, `[:concord, :state, :*]`
- Cluster management tasks: `lib/mix/tasks/concord.ex`
- HTTP API: `lib/concord/web/` (router, controllers, OpenAPI spec)
- Audit logs: `audit_logs/` directory (JSONL format)

## Feature-Specific Guidance

### Adding New Features

When implementing new features in Concord, follow this pattern:

1. **API Module** (`lib/concord/feature.ex`):
   - Public API functions with proper typespecs
   - Validate inputs before sending to state machine
   - Use `@cluster_name` constant for server ID
   - Call `:ra.process_command` for writes, `:ra.consistent_query` for reads
   - Handle Ra's nested result tuples: `{:ok, {:ok, result}, leader_info}`

2. **State Machine Commands** (`lib/concord/state_machine.ex`):
   - Add `apply_command/3` clause for new commands
   - Update state carefully (it's replicated via Raft)
   - Emit telemetry events with timing and metadata
   - Return format: `{{:concord_kv, new_state}, result, effects}`

3. **State Machine Queries** (`lib/concord/state_machine.ex`):
   - Add `query/2` clause for read operations
   - Queries don't modify state, bypass Raft log
   - Return format: `{:ok, result}`

4. **Tests**:
   - Create `test/concord/feature_test.exs`
   - Use `Concord.TestHelper.start_test_cluster()` in setup
   - Clean up data between tests
   - Mark as `async: false`

5. **Documentation**:
   - Add section to README.md with examples
   - Update module documentation
   - Consider adding to HTTP API if applicable

### Working with Secondary Indexes (WIP)

Current status: Core functionality implemented, some test failures remain.

**Known Issues:**
- 18/22 tests failing due to query result unwrapping
- Need to handle `{:ok, {:ok, result}, _}` pattern consistently

**To Fix:**
- Check all `:ra.consistent_query` calls in `lib/concord/index.ex`
- Ensure proper pattern matching for nested `{:ok, ...}` tuples
- Test with `MIX_ENV=test mix test test/concord/index_test.exs`

### Committing Changes

**Semantic Commit Messages:**
- `feat:` - New features
- `fix:` - Bug fixes
- `docs:` - Documentation updates
- `chore:` - Maintenance tasks
- `test:` - Test additions/fixes
- `refactor:` - Code restructuring

**IMPORTANT**: User has requested NOT to include:
- "Generated with [Claude Code]" footer
- "Co-Authored-By: Claude" trailers