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
- **RBAC Tests**: Role management, ACL rules, permission checking (`test/concord/rbac_test.exs` - 34 tests)
- **Multi-Tenancy Tests**: Tenant lifecycle, quotas, usage tracking (`test/concord/multi_tenancy_test.exs` - 41 tests)
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
- ETS tables:
  - `:concord_store` - Main KV storage
  - `:concord_index_*` - Per-index tables
  - `:concord_roles`, `:concord_role_grants`, `:concord_acls` - RBAC tables
  - `:concord_tenants` - Multi-tenancy table
  - `:concord_tokens` - Authentication tokens
- Telemetry events: `[:concord, :api, :*]`, `[:concord, :operation, :*]`, `[:concord, :state, :*]`
- Cluster management tasks: `lib/mix/tasks/concord.ex`
- HTTP API: `lib/concord/web/` (router, controllers, OpenAPI spec)
- Audit logs: `audit_logs/` directory (JSONL format)
- RBAC module: `lib/concord/rbac.ex`
- Multi-tenancy: `lib/concord/multi_tenancy.ex`, `lib/concord/multi_tenancy/rate_limiter.ex`

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

### Working with RBAC (Role-Based Access Control)

Concord includes a comprehensive RBAC system for fine-grained access control.

**Core Concepts:**
- **Roles**: Collections of permissions (admin, editor, viewer, none, or custom)
- **Permissions**: Individual capabilities (read, write, delete, admin, *)
- **ACL Rules**: Per-key pattern restrictions (e.g., "users:*" for namespace isolation)
- **Token-Role Mapping**: Many-to-many relationship between tokens and roles

**Predefined Roles:**
```elixir
:admin   -> [:*]                      # All permissions
:editor  -> [:read, :write, :delete]  # Standard CRUD
:viewer  -> [:read]                   # Read-only access
:none    -> []                        # No permissions
```

**Usage Examples:**

```elixir
# Create custom role
:ok = Concord.RBAC.create_role(:developer, [:read, :write])

# Grant role to token
{:ok, token} = Concord.Auth.create_token()
:ok = Concord.RBAC.grant_role(token, :developer)

# Check permission
:ok = Concord.RBAC.check_permission(token, :write, "config:app")

# Create ACL for namespace isolation
:ok = Concord.RBAC.create_acl("users:*", :viewer, [:read])

# Multiple roles grant additive permissions
:ok = Concord.RBAC.grant_role(token, :viewer)  # Read access
:ok = Concord.RBAC.grant_role(token, :editor) # Now has read+write+delete

# Revoke role
:ok = Concord.RBAC.revoke_role(token, :editor)
```

**CLI Commands:**
```bash
# Create custom role
mix concord.cluster role create developer read,write

# Grant role to token
mix concord.cluster role grant <token> developer

# List all roles
mix concord.cluster role list

# Create ACL for key pattern
mix concord.cluster acl create "users:*" viewer read

# List all ACLs
mix concord.cluster acl list
```

**ACL Behavior:**
- When ACLs exist for a role, they RESTRICT access to matching patterns only
- Multiple ACLs for same role are combined with OR logic
- Wildcard patterns: `*` matches any characters (`"tenant1:*"` matches all tenant1 keys)
- For multi-tenant isolation, each tenant should have its own role

**Implementation Details:**
- Located in `lib/concord/rbac.ex`
- ETS tables: `:concord_roles`, `:concord_role_grants`, `:concord_acls`
- 34 comprehensive tests in `test/concord/rbac_test.exs`
- Backward compatible with simple token permissions

### Working with Multi-Tenancy

Concord provides complete multi-tenancy support with resource isolation and quotas.

**Key Features:**
- Automatic namespace isolation via RBAC
- Resource quotas (keys, storage, rate limits)
- Real-time usage tracking
- Per-tenant metrics and billing data

**Tenant Structure:**
```elixir
%{
  id: :acme,                           # Unique tenant identifier
  name: "ACME Corporation",            # Display name
  namespace: "acme:*",                 # Key namespace pattern
  role: :tenant_acme,                  # Auto-created RBAC role
  quotas: %{
    max_keys: 10_000,                  # Maximum keys
    max_storage_bytes: 100_000_000,    # 100MB storage limit
    max_ops_per_sec: 1_000             # Rate limit
  },
  usage: %{
    key_count: 0,                      # Current key count
    storage_bytes: 0,                  # Current storage usage
    ops_last_second: 0                 # Current rate (resets every second)
  },
  created_at: ~U[2025-10-29 12:00:00Z],
  updated_at: ~U[2025-10-29 12:00:00Z]
}
```

**Usage Examples:**

```elixir
# Create tenant with quotas
{:ok, tenant} = Concord.MultiTenancy.create_tenant(:acme,
  name: "ACME Corporation",
  max_keys: 10_000,
  max_storage_bytes: 100_000_000,  # 100MB
  max_ops_per_sec: 1_000
)

# Create token and grant tenant access
{:ok, token} = Concord.Auth.create_token()
:ok = Concord.RBAC.grant_role(token, :tenant_acme)

# Check quota before operation
:ok = Concord.MultiTenancy.check_quota(:acme, :write, value_size: 256)

# Perform operation (with automatic namespace)
:ok = Concord.put("acme:users:123", %{name: "Alice"}, token: token)

# Record operation for usage tracking
:ok = Concord.MultiTenancy.record_operation(:acme, :write,
  key_delta: 1,
  storage_delta: 256
)

# Get usage statistics
{:ok, usage} = Concord.MultiTenancy.get_usage(:acme)
# => %{key_count: 1, storage_bytes: 256, ops_last_second: 1}

# Update quotas
{:ok, _} = Concord.MultiTenancy.update_quota(:acme, :max_keys, 20_000)

# Extract tenant from key
{:ok, :acme} = Concord.MultiTenancy.tenant_from_key("acme:users:123")
```

**CLI Commands:**
```bash
# Create tenant
mix concord.cluster tenant create acme \
  --name="ACME Corporation" \
  --max-keys=10000 \
  --max-storage=100000000 \
  --max-ops=1000

# List all tenants with usage
mix concord.cluster tenant list

# Show tenant usage statistics
mix concord.cluster tenant usage acme

# Update quota
mix concord.cluster tenant quota acme max_keys 20000

# Delete tenant (keeps keys in storage)
mix concord.cluster tenant delete acme
```

**Quota Enforcement:**
- Quotas are checked BEFORE operations via `check_quota/3`
- Operations return `{:error, :quota_exceeded}` when limits reached
- Rate limiting uses sliding 1-second window (auto-reset by GenServer)
- Set quotas to `:unlimited` to disable limits

**Multi-Tenant Isolation Pattern:**
```elixir
# Each tenant gets unique role
{:ok, tenant1} = MultiTenancy.create_tenant(:tenant1)  # Creates :tenant_tenant1 role
{:ok, tenant2} = MultiTenancy.create_tenant(:tenant2)  # Creates :tenant_tenant2 role

# Tokens can only access their tenant's namespace
{:ok, token1} = Auth.create_token()
:ok = RBAC.grant_role(token1, :tenant_tenant1)

{:ok, token2} = Auth.create_token()
:ok = RBAC.grant_role(token2, :tenant_tenant2)

# Token1 can access tenant1:* but NOT tenant2:*
:ok = RBAC.check_permission(token1, :write, "tenant1:data")
{:error, :forbidden} = RBAC.check_permission(token1, :write, "tenant2:data")
```

**Implementation Details:**
- Located in `lib/concord/multi_tenancy.ex` and `lib/concord/multi_tenancy/rate_limiter.ex`
- ETS table: `:concord_tenants`
- Rate limiter GenServer resets counters every second
- 41 comprehensive tests in `test/concord/multi_tenancy_test.exs`
- Integrates with RBAC for automatic role/ACL creation

### Working with Secondary Indexes

**Status**: ✅ Fully implemented and tested (22 tests passing)

Secondary indexes enable value-based lookups with custom extractor functions.

**Usage Examples:**
```elixir
# Create index with extractor function
extractor = fn value -> Map.get(value, :email) end
:ok = Concord.Index.create_index(:user_email, extractor)

# Put data (index updates automatically)
:ok = Concord.put("user:1", %{name: "Alice", email: "alice@example.com"})

# Query by indexed value
{:ok, ["user:1"]} = Concord.Index.query_index(:user_email, "alice@example.com")
```

**Implementation:**
- Located in `lib/concord/index.ex`
- Each index has its own ETS table: `:concord_index_#{name}`
- Indexes update automatically on put/delete operations
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