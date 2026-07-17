# Concord v2: Design Overview

**Status**: Proposal (merged from two parallel reviews)
**Scope**: Evolve Concord from a single-revision KV with TTL/CAS into a **generic distributed database** with MVCC, multi-key transactions, revision-based sync, and grouped leases.

## 1. Scope: Concord is a database

Concord is a distributed, strongly-consistent, embedded **database**. It is not a workflow engine, not a coordination service with opinions about task lifecycles, and not an agent runtime.

Every concept in the public API must be domain-neutral:

```text
KV       Revision    Transaction
Watch    Sync        Lease / TTL
Snapshot Backup      Index
```

Workflow vocabulary — tasks, agents, managers, claims — belongs in **applications built on top of Concord**, not in Concord itself. A reference application demonstrating coordination patterns is included as an example (see [`examples/agent-coordination.md`](./examples/agent-coordination.md)), but it is not part of Concord's surface area.

This is the single most important constraint on the design. Every API decision should be checked against it: *would this concept be at home in a general-purpose distributed database?* If no, push it to the application layer.

## 2. What stays the same

- Embedded model — Concord starts with the host application
- Ra-backed Raft consensus
- ETS for in-memory state
- Strong consistency as the default
- Existing `Concord.put/get/delete` continue to work (extended, not replaced)
- `meta_time/1` for deterministic time inside the state machine

## 3. What changes

Six new layers, building on each other:

```
                  ┌──────────────────────────────┐
                  │  Application: Agents, etc.   │  (out of scope here)
                  └──────────────┬───────────────┘
                                 │
        ┌────────────┬───────────┴───────────┬────────────┐
        ▼            ▼                       ▼            ▼
   ┌─────────┐  ┌─────────┐             ┌─────────┐  ┌──────────┐
   │  Sync   │  │  Txn    │             │ Leases  │  │  Range / │
   │ + Watch │  │  API    │             │         │  │  Prefix  │
   └────┬────┘  └────┬────┘             └────┬────┘  └─────┬────┘
        │            │                       │             │
        └────────────┴───────────┬───────────┴─────────────┘
                                 ▼
                         ┌───────────────┐
                         │ Revisioned KV │   (foundation)
                         └───────────────┘
```

**Revisioned KV** is the keystone. Every other feature depends on it.

## 4. Module layout

The public surface is split by concern:

```elixir
Concord.KV          # get, put, delete, list, single-key ops
Concord.Txn         # atomic multi-key transactions
Concord.Sync        # changes, watch, current_revision, compact
Concord.Lease       # grant, keep_alive, revoke, info
Concord.Snapshot    # operational snapshot management
Concord.Backup      # backup/restore (existing)
```

Top-level shortcuts remain for the most common operations:

```elixir
Concord.get(key)
Concord.put(key, value)
Concord.delete(key)
Concord.txn(spec)
```

But canonical names live in the namespaced modules.

## 5. Dependency graph

| Layer | Depends on | Required by |
|---|---|---|
| Revisioned KV | (foundation) | All |
| Range/Prefix | KV ordered storage | Sync watch on prefix, txn ranges |
| Txn | KV, Range | Atomic ops, CRUD-as-sugar |
| Sync (changes, watch) | KV, Range | Reactive consumers |
| Lease | KV | Liveness, ephemeral keys |

See individual docs:

- [`01-mvcc-schema.md`](./01-mvcc-schema.md) — revisioned record shape, storage layout, compaction
- [`02-transaction-api.md`](./02-transaction-api.md) — txn spec, compares, operations, idempotency
- [`03-sync-and-watch.md`](./03-sync-and-watch.md) — change log, watch protocol, replay
- [`04-leases.md`](./04-leases.md) — lease lifecycle, key attachment
- [`05-validation-and-limits.md`](./05-validation-and-limits.md) — hard limits, validation rules
- [`examples/agent-coordination.md`](./examples/agent-coordination.md) — reference application

## 6. Core principles

These apply across every doc. Each is enforced, not aspirational.

### Plain-data commands
Raft log entries are pure data structures. No anonymous functions, no closures, no PIDs, no refs anywhere in a txn spec or any other command. Rejected at the API boundary before reaching `:ra.command/3`.

### Deterministic state machine
The state machine's `apply/3` is a pure function of (current state, command, ra-meta). No wall-clock reads, no random IDs, no external I/O. Time comes from `meta_time(meta)`; ordering comes from revisions.

### One-shot transactions
No `BEGIN/COMMIT`, no client-held locks, no interactive sessions. A txn is submitted as a complete spec, applied atomically at one Raft log position, returns a complete result.

### Revisions are the monotonic source
Every mutating commit produces one new revision. All writes within a single txn share the same `mod_revision`. Watchers and clients use revisions for ordering, resumption, history, and optimistic concurrency.

### Compare-failure is not an error
A txn whose compares fail returns `{:ok, %{succeeded: false, ...}}`. System errors (`:no_leader`, `:timeout`, `:invalid_txn`) return `{:error, reason}`. The two are semantically distinct and should never be conflated in the API.

### Plain data over wall clock for TTL
TTL is expressed relatively in commands (`ttl: 30`) and converted at apply time using `meta_time(meta)`. Absolute timestamps must never appear in user-submitted commands; replay would diverge.

## 7. Non-goals (v2)

Explicitly out of scope. Each is a deliberate restraint:

- **Document/blob storage with large values** — Raft replicates every value to every peer. Hard limit at ~1 MiB.
- **CRDTs / collaborative editing** — Different consistency model. Use a different tool.
- **Multi-Raft / sharding** — Significant complexity tax. Defer until measurement proves necessity.
- **etcd gRPC wire compatibility** — Design data model to make it *possible* later; do not ship the protocol now.
- **Interactive transactions** — One-shot only.
- **Server-side scripting (Lua-equivalent)** — Breaks determinism reasoning.
- **Cross-DC replication** — Single cluster only.
- **Server-side full-text search** — Project out-of-band via watch stream.
- **Domain vocabulary in the database layer** — No "task," "agent," "claim," "job" in Concord modules or docs.

## 8. Phasing

Six phases, each independently shippable:

### Phase 1 — Revisioned KV
- Per-key `create_revision`, `mod_revision`, `version`, `content_type`, `metadata`
- Cluster revision counter
- `Concord.KV.get(key, metadata: true)` returns full record
- Existing `put/get/delete` semantics preserved
- Snapshot format v2 with migration path from v1

### Phase 2 — Range and prefix
- Ordered keyspace storage
- `Concord.KV.list(prefix: p, opts)` with bounded limits
- Selector type `{:key, k} | {:prefix, p} | {:range, s, e}` introduced

### Phase 3 — Transaction API
- `Concord.Txn.commit/1` with compare/success/failure spec
- All compare predicates (exists, value, field, version, mod_revision, create_revision, lease, ttl)
- All operations (get, put, delete, touch)
- Idempotency key cache
- CRUD wrappers (`create/2`, `replace/2`, `update_if/3`, `delete_if/2`) compile to txn

### Phase 4 — Sync and watch
- Bounded change log in state
- `Concord.Sync.changes/3`, `Concord.Sync.watch/2`
- Resumable from revision; `:compacted` error on out-of-range
- Watch hub on each node with backpressure
- Leader-following client helper

### Phase 5 — Leases
- Lease as first-class object with multi-key attachment
- `Concord.Lease.grant/keep_alive/revoke`
- Backward compat: `put(k, v, ttl: 30)` continues to work via anonymous leases

### Phase 6 — Production polish
- Telemetry events for all paths
- Operational tooling (compact, snapshot, lease inspection)
- Documentation and reference application

## 9. Backward compatibility

| Existing API | Behavior in v2 |
|---|---|
| `Concord.put(k, v)` | Unchanged externally; internally produces revisioned record |
| `Concord.get(k)` | Unchanged externally; returns latest value |
| `Concord.delete(k)` | Unchanged; produces tombstone for watch observability |
| `Concord.put(k, v, ttl: N)` | Unchanged; internally creates anonymous single-key lease |
| `Concord.put_if/3` | Unchanged; reimplemented as txn wrapper |
| `Concord.put_many/1` | Unchanged; all entries share one `mod_revision` |
| `Concord.get_many/1` | Unchanged; atomic multi-key snapshot |
| Snapshot loading | v2 binary loads both v1 and v2 snapshots; v1 binary cannot load v2 |

## 10. Success criteria

The design succeeds if:

1. **No domain vocabulary leaks into Concord's public API.** Reviewable: search the codebase for "task", "agent", "job", "claim" in `apps/concord/lib/concord/*.ex` after implementation — should appear in tests/examples only.
2. **The reference agent coordination application** (`examples/agent-coordination.md`) is implementable on the public API with no escape hatches.
3. **A 5-node cluster sustains ≥1000 commits/sec at p99 commit latency <50ms** on commodity SSD + LAN.
4. **Watch fan-out to 100 subscribers** does not measurably degrade commit throughput.
5. **Existing test suite passes unchanged** modulo new feature tests.

## 11. Open questions across the proposal

1. **Storage layout**: single ordered table vs current+history split. See [`01-mvcc-schema.md`](./01-mvcc-schema.md) §4.
2. **Change log backing**: in-state map vs separate ETS table vs disk segments. See [`03-sync-and-watch.md`](./03-sync-and-watch.md) §6.
3. **Idempotency cache retention**: TTL-bound vs revision-bound. See [`02-transaction-api.md`](./02-transaction-api.md) §9.
4. **Watch delivery**: messages-only vs Stream wrapper. See [`03-sync-and-watch.md`](./03-sync-and-watch.md) §4.
