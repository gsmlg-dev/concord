# Concord v2 — Design Docs

Merged design proposal for evolving Concord into a generic distributed database with MVCC, multi-key transactions, revision-based sync, and grouped leases.

## What changed from v1 design

This is a merge of two parallel design reviews. Key changes from the earlier `concord-design/` drafts:

| Topic | v1 drafts | v2 (this folder) |
|---|---|---|
| Scope | Concord = database + coordination patterns | **Concord = database only**. Coordination is application-layer. |
| Module layout | Implicit single namespace | **`Concord.KV`, `Concord.Txn`, `Concord.Sync`, `Concord.Lease`** |
| Selector for ops | `range_end:` option on each op | **`{:key, k} \| {:prefix, p} \| {:range, s, e}`** tagged union |
| Read-your-writes in txn branch | Documented as "no" | **Documented as "yes"** — reads observe earlier writes in same branch |
| Compare on structured values | Not supported | **`{:field, key, path, op, value}`** using existing index extractor |
| Idempotency keys | Missing | **First-class** with bounded cache |
| Touch / refresh-TTL | Flag on put (`ignore_value`) | **Dedicated `:touch` op** |
| Content-type / metadata on values | Not present | **First-class fields** for structured text |
| Anonymous-function rejection | Implied | **Hard validation rule**, walked recursively |
| Agent scenario | Bundled into Concord docs | **Moved to `examples/`**, clearly marked non-API |

## Reading order

1. **[`00-design-overview.md`](./00-design-overview.md)** — scope, principles, phasing, non-goals. Start here.
2. **[`01-mvcc-schema.md`](./01-mvcc-schema.md)** — revisioned KV record, storage layout, compaction.
3. **[`02-transaction-api.md`](./02-transaction-api.md)** — txn spec, compare predicates, operations, idempotency.
4. **[`03-sync-and-watch.md`](./03-sync-and-watch.md)** — change log, pull/push API, watch hub, replay.
5. **[`04-leases.md`](./04-leases.md)** — lease lifecycle, multi-key attachment, TTL compat.
6. **[`05-validation-and-limits.md`](./05-validation-and-limits.md)** — cross-cutting limits, error model.
7. **[`examples/agent-coordination.md`](./examples/agent-coordination.md)** — reference application built on the primitives. **Not part of Concord.**

## Core principles (shared across all docs)

- **Concord is a database.** No workflow, agent, or domain vocabulary in any public module.
- **Plain-data commands.** Raft log entries are pure data. No functions, PIDs, or refs anywhere.
- **Deterministic state machine.** `meta_time/1` for time; revisions for ordering. No wall clock, no I/O.
- **One-shot transactions.** No interactive sessions, no client-held locks.
- **Revisions are the monotonic source.** One revision per mutating commit; all writes in one txn share `mod_revision`.
- **Compare-failure is not an error.** Returns `{:ok, %Result{succeeded: false}}`, never `{:error, ...}`.
- **TTL is relative in commands, absolute after apply.** Computed inside the state machine via `meta_time(meta) + ttl_seconds`.
- **Validation at the API boundary.** Recursive walk for non-serializable values before Raft submission.

## How to review with Claude Code

Drop this folder into your repo (suggested: `docs/design/v2/` or `docs/proposals/`). Then:

### Recommended prompts

```
Read all docs in concord-v2-design/. Compare each proposal against
the current lib/. Produce a single table: feature, already-exists,
needs-extension, net-new, estimated diff size.
```

```
Walk through 02-transaction-api.md §13 examples. For each, confirm
expressible against the current put_if/CAS implementation, or list
what's missing.
```

```
Compare 01-mvcc-schema.md §4 (Option B: Current + History tables)
against current state machine ETS layout. Output the minimum diff
to migrate, including snapshot format changes.
```

```
Examine 02-transaction-api.md §11 (validation rules). Cross-reference
with existing input validation in the codebase. List which checks are
new vs already present, and propose where each new check lives.
```

```
Read 03-sync-and-watch.md §5 (architecture). The existing codebase
already has Ra-managed state machine and ETS. Identify which new
processes/modules need to be added vs which existing modules need
extension.
```

```
Examine examples/agent-coordination.md as if you were a new user.
Identify any pattern that requires Concord features not yet in the
proposal. (Goal: catch escape-hatches before they ship.)
```

### Verification queries

- "Search `lib/` and `test/` for any usage of `:os.system_time/1` or `System.system_time/1` inside the state machine apply path. Any hit is a determinism bug."
- "Confirm no anonymous functions appear in any current state machine command. Grep for `fn` and `&` patterns."
- "List every place where current code returns `{:error, :condition_failed}` or similar for compare-style failures. These need to migrate to `{:ok, %Result{succeeded: false}}`."

## Open questions across the proposal

Decisions deferred to implementation. Each is flagged in the relevant doc:

| Question | Doc | Recommendation |
|---|---|---|
| Storage layout (single ordered vs Current+History) | `01` §4 | Option B (Current + History) |
| Idempotency retention (TTL vs revision-bound) | `02` §9 | Revision-bound |
| Change log backing (in-state / ETS / disk) | `03` §6 | ETS-backed for v2 |
| Stream wrapper in core or separate lib | `03` §4 | Core |
| `delete_range` event shape (one bulk / N events) | `03` §15 | N events with shared `op_index` range |
| Per-prefix retention policies | `01` §12 | No; cluster-global with protected allowlist |

## Success criteria

The proposal succeeds if:

1. No domain vocabulary leaks into Concord's public API (grep `apps/concord/lib/concord/*.ex` for "task", "agent", "job", "claim" — should appear in tests/examples only).
2. The reference agent coordination application is implementable on the public API with no escape hatches.
3. A 5-node cluster sustains ≥1000 commits/sec at p99 latency <50ms on commodity SSD + LAN.
4. Watch fan-out to 100 subscribers doesn't measurably degrade commit throughput.
5. The existing test suite passes unchanged (modulo new feature tests).

## Phasing (from overview)

1. Revisioned KV (foundation)
2. Range and prefix selectors
3. Transaction API + CRUD wrappers + idempotency
4. Sync and watch
5. Leases (with TTL backward compat)
6. Production polish (telemetry, ops tools, examples)

Each phase is independently shippable. Phase 1 unblocks all subsequent phases; the rest can proceed roughly in parallel where teams permit.
