# Architectural Audit: Concord Storage Layer + CubDB Integration Analysis

**Date:** 2026-02-11
**Scope:** Raft log storage, state machine persistence, crash recovery, snapshotting, CubDB integration feasibility
**Auditor:** Distributed Systems Architecture Review

---

## Executive Summary

Concord's storage model is **fundamentally correct**: Ra handles Raft consensus + WAL, ETS serves as the hot-path state store. However, several **implementation-level gaps** threaten production readiness — most critically, incomplete snapshots that silently lose index/auth/RBAC state on recovery, and a `runtime.exs` that routes all Raft data to `/tmp`.

**CubDB integration verdict: NO.** CubDB does not belong in the Raft core, state layer, snapshot layer, or anywhere in Concord's storage stack. The architectural mismatch is structural, not a tuning problem. Concord's actual gaps are fixable without introducing new dependencies.

---

## Table of Contents

1. [Current Architecture Assessment](#1-current-architecture-assessment)
2. [CubDB Integration Option Evaluation](#2-cubdb-integration-option-evaluation)
3. [Storage Model Recommendation](#3-storage-model-recommendation)
4. [Design Constraints Validation](#4-design-constraints-validation)
5. [Final Verdict](#5-final-verdict)
6. [Appendix: CubDB Technical Profile](#appendix-cubdb-technical-profile)

---

## 1. Current Architecture Assessment

### 1.1 Raft Log Storage Model

Concord delegates **all** Raft log persistence to Ra 2.17.1. It implements zero custom storage. Ra provides:

| Layer | Mechanism | Location |
|-------|-----------|----------|
| WAL | `ra_log_wal` — sequential append file | `{data_dir}/{uid}/` |
| Segments | `ra_log_segment` — immutable post-compaction files | `{data_dir}/{uid}/` |
| Snapshots | Binary term serialization | `{data_dir}/{uid}/snapshots/` |
| Raft metadata | `currentTerm`, `votedFor` | Ra internal files |

The server config at `lib/concord/application.ex:148-158` passes `log_init_args` with `uid` and `data_dir` to Ra, which manages the complete lifecycle.

> **Assessment:** This delegation to Ra is architecturally correct. Ra's WAL achieves O(1) append cost with batch fsync, segment rotation for bounded file sizes, and efficient prefix truncation via snapshot-anchored compaction. Reimplementing this would be a net negative.

### 1.2 Persistence of `currentTerm` and `votedFor`

Handled entirely by Ra. These are persisted in Ra's internal metadata files and survive restarts. Concord has no visibility into or control over this, which is correct — these are Raft-core invariants that should not be touched by application code.

### 1.3 Crash Recovery Semantics

On restart, the sequence is:

1. `Application.start/2` creates ETS tables for RBAC, multi-tenancy
2. Supervisor starts children including a deferred `Task` for cluster init
3. After `Process.sleep(1000)`, `init_cluster/0` calls `:ra.start_server/1`
4. Ra reads its WAL/segments, loads latest snapshot, calls `snapshot_installed/4`
5. Ra replays log entries after the snapshot, calling `apply/3` for each
6. `trigger_election/1` starts leader election

**What survives a restart:**

- KV data in `:concord_store` (via Ra snapshot + log replay)
- Raft metadata (term, votedFor, commit index)
- Raft log entries

**What is LOST on every restart:**

- Secondary index definitions (`%{indexes: %{}}` in state machine state)
- All secondary index ETS tables (`:concord_index_*`)
- All auth tokens (`:concord_tokens`)
- All RBAC roles, grants, ACLs (`:concord_roles`, `:concord_role_grants`, `:concord_acls`)
- All tenant definitions (`:concord_tenants`)
- Rate limiter state
- Event stream subscriptions

### 1.4 Snapshotting Strategy

The `snapshot/1` function at `lib/concord/state_machine.ex:675` dumps `:ets.tab2list(:concord_store)`.

**Critical Bug:** The function discards the state machine's metadata tuple `{:concord_kv, %{indexes: ...}}` — it only returns raw ETS data. After snapshot-based recovery, `init/1` returns `{:concord_kv, %{indexes: %{}}}`, so all index definitions are silently lost. The function also lacks the `@impl :ra_machine` annotation, raising questions about its integration with Ra's snapshot lifecycle.

```elixir
# CURRENT (buggy) — lib/concord/state_machine.ex:675-685
def snapshot({:concord_kv, _data}) do
  data = :ets.tab2list(:concord_store)
  # ... telemetry ...
  data
end
```

The `_data` containing `%{indexes: %{...}}` is discarded. This is a silent data loss bug.

### 1.5 State Machine Persistence Durability

The state machine is purely in-memory (ETS). Durability comes exclusively from Ra's log + snapshots. This is a valid architecture — ETS is the hot path, Ra is the durability layer.

**Risk:** The ETS table is created with `:public` access, meaning any process on the node can write to it without going through Raft consensus. This is a safety hazard if accidentally used by non-state-machine code.

### 1.6 Log Truncation and Compaction

**Concord performs zero explicit log management.** There are no calls to `ra:release_cursor/2`, `ra:checkpoint/2`, or any compaction API anywhere in the codebase. Ra's default automatic policies handle this, but without explicit cursor release, Ra may retain log entries longer than necessary, consuming unbounded disk space.

### 1.7 Raft Safety After Restart

**Raft safety properties ARE preserved** — Ra handles this correctly. However, **application-level consistency is NOT preserved** because:

1. Auth tokens vanish → all authenticated clients lose access
2. RBAC configuration vanishes → access control resets to default
3. Tenant isolation vanishes → multi-tenancy is broken
4. Index definitions vanish → secondary queries return empty results

### 1.8 Production Readiness Gap Summary

| Gap | Severity | Impact |
|-----|----------|--------|
| `runtime.exs` routes data to `/tmp` | **CRITICAL** | All Raft data lost on OS reboot in production |
| Snapshot drops index metadata | **HIGH** | Silent data loss on snapshot recovery |
| Auth/RBAC/tenants not persisted | **HIGH** | Full security reset on every restart |
| Backup restore bypasses Raft | **HIGH** | Cluster split-brain after restore |
| No explicit log compaction | **MEDIUM** | Unbounded disk growth under sustained load |
| 1-second startup sleep (hardcoded) | **LOW** | Race condition; not a proper readiness check |
| ETS table is `:public` | **MEDIUM** | Possible consensus bypass |

---

## 2. CubDB Integration Option Evaluation

### Background: CubDB's Storage Engine

CubDB uses an **append-only, copy-on-write B-tree** (inspired by CouchDB). Every write creates new tree nodes from leaf to root. Old nodes become dead space reclaimed by compaction. It provides crash consistency through append-only writes + header-based recovery scanning.

Key characteristics relevant to this evaluation:

- **Write amplification:** O(log_B(N)) blocks rewritten per key update (3-5 KB for a single small value change)
- **Compaction:** Full rewrite of live data into new file; can hang under high write rates (GitHub issue #57)
- **Concurrency:** Single-writer GenServer; multiple concurrent readers via MVCC
- **Durability:** `fdatasync` per write when `auto_file_sync: true` (default)
- **Performance:** ElectricSQL measured 102x slower writes vs. append-only log on SSD after replacing CubDB

### Option A: CubDB as the Raft Log Store

**Verdict: REJECTED — Architecturally incompatible.**

A Raft log is a sequential append-only structure. Its critical operations:

| Operation | Raft Requirement | CubDB Cost |
|-----------|-----------------|------------|
| Append entry | O(1) sequential write | O(log N) — COW B-tree rewrite |
| Prefix truncation | O(1) pointer advance | O(K × log N) — individual deletes |
| Suffix truncation | O(1) file truncate | O(K × log N) — individual deletes |
| Point lookup by index | O(1) with offset | O(log N) — B-tree traversal |
| Ordered scan | O(K) sequential | O(K) — acceptable |

CubDB's copy-on-write B-tree writes 3-5 KB per single key update (depth × 1024-byte blocks). ElectricSQL measured **102x slower writes** compared to an append-only log on SSD after replacing CubDB. For a Raft log processing thousands of commands/second, this is disqualifying.

CubDB's compaction model (full rewrite of live data) conflicts with Raft's log lifecycle where truncation should be instantaneous after a snapshot checkpoint.

**Failure mode:** Under high throughput, CubDB's compaction could fall behind (issue #57 — compaction hangs), causing unbounded file growth and eventually disk exhaustion. Ra's segment-based architecture avoids this entirely by writing immutable segment files that can be deleted atomically.

Ra already implements a purpose-built WAL + segment store. Replacing it with CubDB would be a regression in every measurable dimension.

### Option B: CubDB as the State Machine Backend

**Verdict: CONDITIONALLY VIABLE — but not recommended for Concord's design.**

This is where CubDB's strengths (sorted keys, range queries, MVCC snapshots, crash consistency) align best. The idea: replace ETS with CubDB for the KV store, gaining disk persistence for free.

**Potential advantages:**

- Eliminates dependence on Ra snapshots for state recovery — CubDB IS the durable state
- Range queries via `CubDB.select/2` are natively efficient
- MVCC snapshots provide consistent reads without blocking writes
- Crash-safe without additional work

**Critical problems:**

1. **Write amplification on every Raft apply.** Every `apply_command/3` (`:put`, `:delete`, `:put_many`) would trigger a CubDB B-tree rewrite. At Concord's target throughput (600K-870K ops/sec), CubDB's single-writer GenServer becomes an insurmountable bottleneck.

2. **Deterministic replay breaks.** Ra replays log entries through `apply/3` during recovery. If state already exists in CubDB (because it's durable), replaying the same commands would produce duplicate writes. You'd need idempotency checks (comparing Ra's applied index against CubDB's latest), adding complexity and subtle correctness risks.

3. **Snapshot semantics become ambiguous.** If CubDB is the authoritative state, Ra's snapshot mechanism becomes redundant for state recovery but still needed for log truncation. The interaction between CubDB's own crash recovery and Ra's snapshot lifecycle creates a complex invariant to maintain.

4. **Latency regression.** ETS reads are sub-microsecond. CubDB reads require B-tree traversal + Erlang term deserialization, even with page cache. For Concord's "microsecond-level performance" claim, this is a non-starter.

5. **fsync cost.** With `auto_file_sync: true` (required for crash safety), every write incurs an `fdatasync`. CubDB's single-writer serializes all writes through one GenServer.

**When it COULD work:** If Concord evolves to a design where the state machine is multi-GB, doesn't fit in memory, and requires range queries as a primary access pattern — CubDB becomes a reasonable embedded persistent backend. But this is a fundamentally different product than what Concord is today.

### Option C: CubDB as the Snapshot Storage Layer

**Verdict: POOR FIT — Unnecessary complexity for marginal benefit.**

Ra snapshots are point-in-time serialized state. They're written once, read once (on recovery), and deleted after newer snapshots exist. This is a write-once-read-once workload.

CubDB adds:

- A B-tree structure (unnecessary — you're writing one blob)
- Compaction overhead (unnecessary — old snapshots are deleted, not updated)
- A GenServer process (unnecessary — snapshots are infrequent)
- Write amplification (unnecessary — a single file write suffices)

The correct tool for snapshot storage is a flat file: `:erlang.term_to_binary(state) |> File.write!(path)`. Ra already does this. CubDB adds overhead with zero benefit.

### Option D: CubDB for Raft Metadata (term / votedFor)

**Verdict: REJECTED — Absurd overhead for two integers.**

`currentTerm` and `votedFor` are two values that change at most once per election. Ra persists these with minimal overhead. Using CubDB would mean:

- Starting a GenServer + file handle for two fields
- B-tree overhead for key-value pairs that never exceed 100 bytes total
- fsync overhead per update (same as a flat file, but with more writes)
- A new failure domain (CubDB process crash) for Raft's most critical metadata

### Option E: Do Not Integrate CubDB

**Verdict: CORRECT for the Raft core. Correct for the current application layer.**

Ra's built-in storage is purpose-built for Raft. It provides O(1) appends, segment-based compaction, efficient truncation, and crash-safe metadata — exactly what a Raft log needs. No replacement is warranted.

For the application layer (the state machine's KV store), ETS is the correct choice given Concord's performance targets. The persistence gap should be solved by fixing the snapshot implementation and persisting auxiliary state (auth, RBAC, tenants) through Ra commands — not by introducing CubDB.

### Option Comparison Matrix

| Criterion | A: Raft Log | B: State Machine | C: Snapshots | D: Metadata | E: None |
|-----------|:-----------:|:-----------------:|:------------:|:-----------:|:-------:|
| Raft safety | ❌ Degrades | ⚠️ Complex | ✅ Neutral | ❌ Risk | ✅ Safe |
| Crash consistency | ⚠️ Adequate | ✅ Good | ✅ Adequate | ✅ Adequate | ✅ Via Ra |
| Write amplification | ❌ O(log N) | ❌ O(log N) | ❌ Wasteful | ❌ Wasteful | ✅ O(1) |
| Truncation feasibility | ❌ No support | N/A | N/A | N/A | ✅ Native |
| Append throughput | ❌ 102x slower | ❌ Bottleneck | N/A | N/A | ✅ Native |
| Recovery determinism | ⚠️ Complex | ❌ Idempotency | ✅ Simple | ✅ Simple | ✅ Simple |
| Operational complexity | ❌ High | ❌ High | ⚠️ Medium | ⚠️ Low | ✅ None |
| Scalability | ❌ Compaction | ❌ Single-writer | ✅ Fine | ✅ Fine | ✅ Native |
| Safety violation risk | ❌ High | ⚠️ Medium | ✅ Low | ⚠️ Medium | ✅ None |

---

## 3. Storage Model Recommendation

### 3.1 Recommended Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                        Client API (Concord)                          │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────────────────┐    ┌─────────────────────────────────┐  │
│  │   Write Path             │    │   Read Path                     │  │
│  │                          │    │                                 │  │
│  │  Validate + Auth         │    │  :ra.consistent_query/2         │  │
│  │         │                │    │  :ra.local_query/2              │  │
│  │  :ra.process_command     │    │         │                       │  │
│  │         │                │    │  ETS Lookup (:concord_store)    │  │
│  │    Ra Consensus          │    │         │                       │  │
│  │         │                │    │  Decompress + Return            │  │
│  │  apply_command/3         │    │                                 │  │
│  │         │                │    └─────────────────────────────────┘  │
│  │  ETS Insert + Index      │                                        │
│  └─────────────────────────┘                                         │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│                       Ra (Raft Consensus)                            │
│                                                                      │
│  ┌───────────┐  ┌────────────┐  ┌───────────┐  ┌─────────────────┐  │
│  │    WAL    │  │  Segments  │  │  Metadata  │  │   Snapshots     │  │
│  │ (append-  │  │ (immutable │  │ (term /    │  │ (complete state │  │
│  │  only)    │  │  files)    │  │  votedFor) │  │  incl. indexes, │  │
│  │           │  │            │  │            │  │  auth, RBAC,    │  │
│  │           │  │            │  │            │  │  tenants)       │  │
│  └─────┬─────┘  └─────┬──────┘  └─────┬──────┘  └───────┬─────────┘  │
│        └───────────────┴───────────────┴─────────────────┘           │
│                          Disk (data_dir)                             │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│                     State Machine Layer (ETS)                        │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │  :concord_store         — KV data             (in-memory)     │  │
│  │  :concord_index_*       — Secondary indexes   (in-memory)     │  │
│  │  :concord_tokens        — Auth tokens         (in-memory)     │  │
│  │  :concord_roles         — RBAC roles          (in-memory)     │  │
│  │  :concord_role_grants   — Role grants         (in-memory)     │  │
│  │  :concord_acls          — ACL rules           (in-memory)     │  │
│  │  :concord_tenants       — Multi-tenancy       (in-memory)     │  │
│  │                                                                │  │
│  │  ALL rebuilt from Ra snapshot + log replay on recovery          │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.2 Key Design Decisions

**Should WAL be append-only file-based?**
Yes, and it already is — Ra provides this. No change needed.

**Should Raft log and state storage be separated?**
They already are. Ra manages the log; ETS holds the applied state. This separation is correct. The fix needed is making the state fully recoverable from Ra, not changing the separation model.

**Should storage layers be abstracted via behaviours?**
**No — not at this stage.** A storage behaviour adds indirection that is not justified by the current single-implementation reality. Premature abstraction here would:

- Obscure the actual consistency guarantees
- Make reasoning about crash recovery harder
- Add an API surface to maintain without a second implementation to validate it against

If Concord later needs pluggable storage (e.g., RocksDB for datasets exceeding RAM), introduce the behaviour then with a concrete second implementation to drive the API design.

**Should Concord expose pluggable storage engines?**
**No.** Concord is an embedded database, not a storage engine framework. The value proposition is "drop it into your Elixir app and get distributed KV." Pluggable engines would fragment the consistency model and testing matrix. Keep it opinionated.

**How should snapshotting be implemented?**
Fix the current implementation to capture complete state:

```elixir
@impl :ra_machine
def snapshot({:concord_kv, data}) do
  %{
    version: 2,
    kv_data: :ets.tab2list(:concord_store),
    indexes: Map.get(data, :indexes, %{}),
    tokens: safe_tab2list(:concord_tokens),
    roles: safe_tab2list(:concord_roles),
    role_grants: safe_tab2list(:concord_role_grants),
    acls: safe_tab2list(:concord_acls),
    tenants: safe_tab2list(:concord_tenants)
  }
end

defp safe_tab2list(table) do
  case :ets.whereis(table) do
    :undefined -> []
    _ref -> :ets.tab2list(table)
  end
end
```

And restore all tables in `snapshot_installed/4`:

```elixir
@impl :ra_machine
def snapshot_installed(snapshot, _metadata, {:concord_kv, _data}, _aux) do
  # Restore KV data
  :ets.delete_all_objects(:concord_store)
  Enum.each(snapshot.kv_data, &:ets.insert(:concord_store, &1))

  # Restore auth tokens
  restore_table(:concord_tokens, Map.get(snapshot, :tokens, []))

  # Restore RBAC
  restore_table(:concord_roles, Map.get(snapshot, :roles, []))
  restore_table(:concord_role_grants, Map.get(snapshot, :role_grants, []))
  restore_table(:concord_acls, Map.get(snapshot, :acls, []))

  # Restore tenants
  restore_table(:concord_tenants, Map.get(snapshot, :tenants, []))

  # Rebuild secondary index ETS tables from definitions + KV data
  rebuild_indexes(Map.get(snapshot, :indexes, %{}))

  []
end
```

**How should log compaction interact with state storage?**
Add explicit `ra:release_cursor/3` calls after state machine snapshots to signal Ra that log entries before the snapshot index can be truncated. Currently, Concord never signals this, so Ra relies on its default heuristics which may retain entries longer than necessary.

### 3.3 Required Fixes (Priority Order)

#### P0: CRITICAL

1. **Fix `runtime.exs` data directory** — Remove the `/tmp` override or gate it to non-production environments. In production, `data_dir` must point to durable, non-ephemeral storage.

2. **Fix snapshot to capture complete state** — Include index definitions, auth tokens, RBAC configuration, and tenant data in snapshots. Add snapshot versioning for backward compatibility.

#### P1: HIGH

3. **Route auth/RBAC/tenant mutations through Raft** — Currently, `Auth.create_token/1`, `RBAC.create_role/2`, `MultiTenancy.create_tenant/3` write directly to ETS. These must go through `:ra.process_command` to be replicated across cluster members and captured in the Raft log. Without this, they are lost on restart and inconsistent across nodes.

4. **Fix backup restore to go through Raft** — `Backup.restore/2` writes directly to local ETS without going through Ra consensus. This causes split-brain data inconsistencies in a multi-node cluster. Restore must submit entries via `:ra.process_command`.

#### P2: MEDIUM

5. **Add explicit log compaction** — Call `ra:release_cursor/3` after successful snapshots to enable Ra to truncate old log entries.

6. **Change ETS table access** — Use `:protected` instead of `:public` for `:concord_store` to prevent accidental consensus bypass. Only the Ra state machine process (which owns the table) should write to it.

#### P3: LOW

7. **Replace hardcoded startup sleep** — Replace `Process.sleep(1000)` with a proper readiness check (e.g., attempt to contact Ra server with exponential backoff).

---

## 4. Design Constraints Validation

| Constraint | Current Status | After Recommended Fixes |
|-----------|---------------|------------------------|
| Raft safety MUST NOT be compromised | ✅ Ra handles correctly | ✅ No change needed |
| Avoid unnecessary abstraction | ✅ No storage behaviour | ✅ Keep as-is |
| Deterministic crash recovery | ❌ Incomplete snapshots | ✅ Full state in snapshots |
| Multi-node cluster evolution | ⚠️ Auth/RBAC not replicated | ✅ All state through Raft |
| Correctness first, performance second | ⚠️ Silent data loss bugs | ✅ Complete state recovery |
| Architectural clarity | ✅ Clean Ra + ETS model | ✅ Same model, better implementation |

---

## 5. Final Verdict

### CubDB Integration: **NO**

**CubDB does not belong in the Raft core, state layer, snapshot layer, or anywhere in Concord's storage stack.**

| Layer | Why Not CubDB |
|-------|--------------|
| **Raft Log** | Ra's WAL + segments provide O(1) appends vs CubDB's O(log N). CubDB lacks efficient truncation. 102x measured performance gap (ElectricSQL benchmarks). |
| **State Machine** | ETS provides sub-microsecond reads. CubDB's B-tree traversal + deserialization would regress latency by 10-100x. CubDB's single-writer GenServer caps throughput far below Concord's 600K+ ops/sec target. |
| **Snapshots** | Snapshots are write-once blobs. A B-tree is the wrong data structure. A flat file suffices. Ra already does this. |
| **Metadata** | Two integers (`currentTerm`, `votedFor`) don't need a database. Ra handles this internally. |

### What Concord Should Do Instead

Concord's storage architecture is **fundamentally sound**: Ra for consensus + WAL, ETS for hot state. The gaps are **implementation bugs**, not architectural deficiencies:

1. Fix the snapshot to capture all state (indexes, auth, RBAC, tenants)
2. Route all mutable state through Raft consensus
3. Fix `runtime.exs` to not use `/tmp` in production
4. Add explicit log compaction signals to Ra
5. Fix backup/restore to go through consensus
6. Change ETS access from `:public` to `:protected`

These are targeted, low-risk fixes to an existing sound architecture. Introducing CubDB would add complexity, degrade performance, and create new failure modes without solving any of the actual problems.

### When CubDB Would Be Appropriate

CubDB is a well-engineered embedded database suitable for:

- Embedded applications on resource-constrained devices (Nerves/IoT)
- Moderate-throughput KV stores where simplicity outweighs raw performance
- Applications needing persistent sorted maps without external infrastructure

It is **not** suitable for the inner loop of a distributed consensus system where sub-millisecond latency and high-throughput sequential appends are mandatory.

---

## Appendix: CubDB Technical Profile

### Storage Engine

Append-only, copy-on-write B-tree with 1024-byte fixed blocks. All writes create new tree nodes from leaf to root; old nodes become dead space. Serialization uses `:erlang.term_to_binary`.

### Crash Consistency

Append-only invariant ensures partial writes cannot corrupt committed data. Recovery scans backwards from EOF to find the last valid header. With `auto_file_sync: true` (default), `fdatasync` is called after every commit — data is durable after the call returns.

### Write Amplification

O(log_B(N)) blocks per key update. For a 1M-entry database with branching factor ~64, every write produces 3-4 block rewrites (~3-4 KB) even for a single byte change. This is the primary performance limitation.

### Compaction

Online two-phase compaction: bulk-load live entries into new file, then iteratively catch up with concurrent writes. Requires ~2x disk space during compaction. Known issue: can hang under very high write rates (GitHub #57).

### Concurrency

Single-writer GenServer with MVCC for readers. Writers are serialized. Readers get immutable snapshot views (zero-cost). Only one process may open a data directory.

### Performance Envelope

| Workload | Suitability |
|----------|-------------|
| Low-frequency random writes | Good |
| High-frequency small writes | Poor (write amplification) |
| Sequential append-heavy | Poor (B-tree overhead per append) |
| Range scans | Good (sorted B-tree, lazy streams) |
| Point lookups | Good (O(log N) with page cache) |
| Mixed read/write | Acceptable (MVCC prevents contention) |

### API Highlights

- Core CRUD: `put/3`, `get/3`, `delete/2`, `fetch/2`
- Batch: `put_multi/2`, `delete_multi/2` (atomic)
- Range queries: `select/2` with `min_key`/`max_key` (lazy streams)
- Transactions: `transaction/2` with serializable isolation
- Snapshots: `with_snapshot/2` for consistent reads
- Admin: `compact/1`, `file_sync/1`, `back_up/2`

### Durability Guarantees

- `auto_file_sync: true`: Durable after `put` returns. Survives power failure.
- `auto_file_sync: false`: Durable against process crash (OS buffers persist). Power failure may lose recent writes. Database never corrupts — rolls back to last fsynced header.
