# Concord Constitution

<!--
Sync Impact Report
==================
Version change: 1.1.0 → 2.0.0
Rewrite rationale: Concord's identity was unclear — the constitution
described a distributed coordination *service* with auth, RBAC,
multi-tenancy, audit logging, compliance (PCI-DSS, HIPAA, GDPR),
HTTP API, OpenTelemetry, Prometheus, event streaming, etc.

Concord is none of that. Concord is an **embedded database** — a
library dependency like SQLite, CubDB, or Mnesia. The host application
owns every concern above the storage API.

This rewrite strips the constitution to match that identity.

Removed:
  - Principle V (old): Secure Defaults (auth, RBAC, TLS, audit)
  - Principle IV (old): Observability as Infrastructure (demoted —
    telemetry events are emitted but no observability stack ships)
  - All references to auth/RBAC/multi-tenancy/audit in invariants
  - HTTP API as a core concern
  - Prometheus, OpenTelemetry, event streaming as principles
  - Compliance references (PCI-DSS, HIPAA, GDPR, SOC 2)

Added:
  - Principle IV: Explicit Durability Model
  - Principle V: Minimal Surface Area (what Concord is NOT)
  - Scope Exclusions table

Follow-up TODOs (code removal):
  - Delete: lib/concord/auth.ex, lib/concord/rbac.ex,
    lib/concord/multi_tenancy/, lib/concord/audit_log/,
    lib/concord/tracing/, lib/concord/tracing.ex,
    lib/concord/prometheus.ex, lib/concord/event_stream/,
    lib/concord/event_stream.ex, lib/concord/web/
  - Strip from StateMachine state: tokens, roles, role_grants, acls,
    tenants — and all apply_command clauses that handle them
  - Remove deps: plug, bandit, plug_crypto, opentelemetry_*,
    telemetry_metrics_prometheus, gen_stage, httpoison
  - Keep deps: ra, libcluster, telemetry, telemetry_poller, jason
  - Remove config: auth_enabled, http, tls, prometheus_*, tracing_*,
    audit_log, event_stream, opentelemetry sections
  - Rewrite README.md from scratch
  - Update mix.exs package description
  - Delete: openapi.json, priv/openapi.json, grafana-dashboard.json,
    demo_api.sh, docs/API_DESIGN.md, docs/API_USAGE_EXAMPLES.md,
    docs/deployment.md, docs/observability.md
  - Update: CLAUDE.md, skills/concord-database/SKILL.md
-->

## Core Principles

### I. Embedded Database, Not a Service

Concord is a **library dependency** — like SQLite, CubDB, or Mnesia.
It starts inside your application's supervision tree. There is no
separate process to operate, no HTTP API to expose, no auth layer to
configure.

- Add `{:concord, "~> 0.x"}` to `mix.exs`, call `Concord.put/get/delete`
- Application lifecycle controls Concord lifecycle
- Configuration via standard Elixir config files
- Zero operational overhead for single-node use

**Rationale**: The simpler Concord is, the more useful it is. Every
feature that doesn't serve "embedded KV store with Raft" is a
liability — more code to maintain, more surface area to break, more
concepts for users to learn.

### II. Consistency via Raft

All write operations go through Raft consensus (Ra library). Concord
is a CP system:

- Writes require quorum acknowledgment before returning success
- Reads support configurable consistency: `:eventual`, `:leader`
  (default), `:strong`
- During network partitions, the minority partition becomes
  unavailable rather than serving stale data

**Rationale**: Concord stores data that multiple nodes must agree on —
configuration, feature flags, coordination state. Incorrect data is
worse than unavailable data.

### III. Performance Without Compromise

- Read operations: target <10μs (ETS lookups)
- Write operations: target <20ms (quorum commits)
- Throughput: 600K+ ops/sec for reads under load
- No blocking operations on the hot path

**Rationale**: An embedded store that introduces latency becomes a
bottleneck in the host application.

### IV. Explicit Durability Model

Concord is an **in-memory store with periodic disk flush**. Data
persistence works as follows:

- ETS is the live data store (fast reads/writes)
- Ra writes the Raft log to disk; the flush interval is configurable
  (default: 1 second, configurable in milliseconds)
- **Data written since the last flush can be lost on crash** — this
  is by design, not a bug
- Concord is intended for data that doesn't change frequently and
  can be restored from an authoritative external source (database,
  config files, API) after a crash
- Snapshots compact the Raft log periodically (every N commands)

Users MUST understand this trade-off: Concord optimises for read
performance and consistency across nodes, not for crash durability of
every single write. If you need every write to survive a crash, use
PostgreSQL.

**Rationale**: The data Concord stores (feature flags, config,
coordination state) is derived from a more durable source. Forcing
`fsync` on every write would destroy the performance advantage of an
embedded in-memory store. The configurable flush interval lets users
tune the acceptable data loss window.

### V. Minimal Surface Area

Concord provides: `put`, `get`, `delete`, `get_all`, TTL, secondary
indexes, bulk operations, conditional updates (CAS), backup/restore,
and configurable read consistency.

Concord does NOT provide and MUST NOT grow to include:

- Authentication or authorization
- Role-based access control (RBAC) or ACLs
- Multi-tenancy or namespace isolation
- HTTP/REST/GraphQL API
- Audit logging or compliance features
- Prometheus metrics export or OpenTelemetry tracing
- Event streaming or change data capture
- Encryption at rest

These belong in the host application or in separate libraries that
wrap Concord.

**Rationale**: Every feature outside the core KV+Raft contract adds
maintenance burden, couples application policy to the storage engine,
and forces every consumer to pay for complexity they may not need.
Concord should be the smallest useful thing.

### VI. Test-Driven Quality

- Unit tests for isolated component behavior
- E2E tests for distributed scenarios (leader election, partitions,
  node failures)
- Tests run with `async: false` (Ra cluster is shared state)
- State machine changes require cluster restart verification

**Rationale**: Distributed systems have subtle failure modes.
Comprehensive testing is the only way to maintain correctness.

### VII. API Stability

Public API changes follow semantic versioning:

- MAJOR: Breaking changes to `Concord.*` public functions
- MINOR: New features, new optional parameters
- PATCH: Bug fixes, performance improvements
- State machine version changes MUST be backward compatible or
  include migration paths

**Rationale**: Applications depend on Concord for coordination.
Breaking changes without warning erode trust.

### VIII. Deterministic State Machine

The Ra state machine (`Concord.StateMachine`) MUST remain
deterministic and serialization-safe. These invariants are
non-negotiable:

1. **Deterministic replay**: `apply/3` is a pure function of
   `(meta, command, state)`. Time comes from `meta.system_time`
   (leader-assigned ms), NEVER `System.system_time`. Helper:
   `meta_time(meta)`.

2. **No anonymous functions in Raft state/log**: Use declarative
   extractor specs — tuples like `{:map_get, :email}`,
   `{:nested, [:a, :b]}`, `{:identity}`, `{:element, n}`. Closures
   cause `:badfun` on deserialization.

3. **All mutations through Raft**: Every state change routes through
   `:ra.process_command`. Direct ETS writes are ONLY acceptable as
   fallback when the cluster isn't ready (`:noproc`).

4. **ETS = materialized views**: Rebuilt from Raft state on
   `snapshot_installed/4`. Never the source of truth.

5. **Snapshots via `release_cursor`**: Ra has no `snapshot/1`
   callback. Emit `{:release_cursor, index, state}` every N commands.

6. **Pre-consensus evaluation**: `put_if`/`delete_if` evaluate
   conditions at the API layer, convert to CAS commands with
   `expected: current_value` before entering the Raft log.

**Rationale**: Violating any invariant causes state divergence, data
corruption on replay, or deserialization failures across nodes.

## Architectural Constraints

### Technology Stack

- **Language**: Elixir 1.14+
- **Consensus**: Ra (Raft)
- **Discovery**: libcluster (gossip)
- **Storage**: ETS (in-memory) + Ra log/snapshots on disk
- **Serialization**: Erlang term format (via Ra)

### Boundaries

- Maximum key size: 1024 bytes
- Maximum batch size: 500 operations (configurable)
- Compression threshold: 1KB (auto-compressed)
- Cluster size: 1–7 nodes (3+ for fault tolerance)
- Disk flush interval: configurable (default 1000ms)

### Scope Exclusions

These concerns are permanently out of scope:

| Concern | Why excluded | Where it belongs |
|---------|-------------|-----------------|
| Auth/authz | Application policy | Host app or Plug pipeline |
| RBAC/ACLs | Application policy | Host app |
| Multi-tenancy | Application policy | Host app (key prefixes) |
| HTTP API | Service concern | Separate wrapper library |
| Audit logging | Compliance concern | Host app |
| Prometheus/OTEL | Observability concern | Host app via telemetry hooks |
| Event streaming | Application concern | Host app subscribing to telemetry |
| Encryption at rest | Security concern | Host app or disk-level |

Concord emits `:telemetry` events. The host application can attach
any metrics/tracing/logging system it wants. Concord does not ship
with or depend on any specific observability stack.

## Development Workflow

### Code Quality Gates

- `mix credo --strict` passes
- `mix dialyzer` passes
- Test coverage above 40%
- New features include documentation

### Commit Standards

- Semantic prefixes: `feat:`, `fix:`, `docs:`, `chore:`, `test:`,
  `refactor:`
- No auto-generated footers (Claude Code, Co-Authored-By)
- Atomic, independently reversible commits

## Governance

This constitution supersedes all other development practices.

### Amendment Process

1. Propose changes via PR to `.specify/memory/constitution.md`
2. Document rationale
3. Update dependent templates if principles change
4. Increment version per semantic rules

### Version Policy

- MAJOR: Principle removal or fundamental redefinition
- MINOR: New principle added
- PATCH: Clarifications

**Version**: 2.0.0 | **Ratified**: 2025-12-03 | **Last Amended**: 2026-03-09