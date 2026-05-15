# Revisioned KV Schema

**Status**: Proposal
**Depends on**: nothing (foundation)
**Required by**: Transactions, Sync/Watch, Leases

## 1. Concept

Concord adopts an MVCC model centered on a single monotonic **cluster revision counter**. Every committed mutation increments this counter once; the resulting integer is the *revision* of that mutation.

Revisions are the only monotonic ordering source in Concord. They replace wall-clock timestamps, UUIDs, and per-key counters wherever ordering matters (history, sync resumption, optimistic concurrency).

Properties:

- **Monotonic** — strictly increasing across all commits
- **Dense** — consecutive integers, no gaps
- **Cluster-wide** — one counter, not per-key or per-node
- **Deterministic** — replaying the Raft log produces identical revisions

A transaction that writes 3 keys increments the revision once. All 3 keys share the same `mod_revision`. This is what allows sync consumers to identify atomic commit boundaries.

## 2. Per-key record

```elixir
%Concord.KV.Record{
  value:           term(),
  create_revision: non_neg_integer(),
  mod_revision:    non_neg_integer(),
  version:         non_neg_integer(),

  expires_at:      non_neg_integer() | nil,
  lease_id:        non_neg_integer() | nil,

  content_type:    binary() | nil,
  metadata:        map()
}
```

| Field | Meaning |
|---|---|
| `value` | The stored value (term) |
| `create_revision` | Revision when key was first created (or last re-created after delete) |
| `mod_revision` | Revision of the latest mutation |
| `version` | Count of writes since creation; `0` means absent or deleted |
| `expires_at` | Absolute timestamp of TTL expiry, or `nil` |
| `lease_id` | Lease this key is attached to, or `nil` |
| `content_type` | Optional MIME-ish hint (`"text/markdown"`, `"application/json"`, etc.) |
| `metadata` | Optional application-level metadata map |

`create_revision` and `version` **reset** on delete-and-recreate. `mod_revision` advances on every write.

The `content_type` and `metadata` fields are deliberately permissive: Concord stores and returns them but never interprets them. They exist so applications storing structured text (markdown notes, JSON results, etc.) can self-describe values without inventing an envelope format.

## 3. Global state

```elixir
{:concord_kv, %{
  revision:         non_neg_integer(),  # current cluster revision
  compact_revision: non_neg_integer(),  # everything below is compacted
  command_count:    non_neg_integer(),  # for snapshot triggers
  next_lease_id:    pos_integer(),
  indexes:          map()                # existing index state (preserved)
}}
```

`revision` advances **once per committed mutating command** (txn, put, delete, lease expiration). Pure-read commands and no-op commands do not advance it.

`compact_revision` records the lowest revision still preserved in history. Sync requests below this fail with `{:error, {:compacted, compact_revision}}`.

## 4. Storage layout

Two viable layouts. Recommend **Option B**.

### Option A — Single ordered table

One ETS `:ordered_set` keyed by `{key, revision}`. Every version of every key is a row.

```
{ {"k/1", 100}, %Record{value: "a", mod_revision: 100, ...} }
{ {"k/1", 105}, %Record{value: "b", mod_revision: 105, ...} }
```

Latest-value read: `:ets.prev(table, {key, :infinity})`.

**Pros**: single source of truth, history is "free."
**Cons**: every latest-state lookup walks revisions; range/prefix scans pull historical versions.

### Option B — Current + History tables (recommended)

Two tables:

- **Current**: ETS `:ordered_set` keyed by `key`, holds only the latest `Record` per key. Single-key reads and prefix scans are O(log n) with no version walking.
- **History**: ETS `:ordered_set` keyed by `{key, revision}`, holds prior `Record` versions. Consulted only for time-travel reads and watch replay.

**Invariant**: Current always holds the row with the maximum `mod_revision` for each key. On every mutation, the previous Current row is copied to History before the new row replaces it in Current.

**Pros**: fast common-case reads, range scans are clean, history can be sized/compacted independently.
**Cons**: two ETS operations per write, two tables to serialize in snapshots.

Trade-off favors Option B: the dominant access pattern is latest-state reads.

## 5. Deletion and tombstones

A delete operation produces a **tombstone** — a record with `version = 0`, `value = nil`, and a fresh `mod_revision`. The tombstone moves into History; the Current row is removed.

Tombstones exist for two reasons:

1. **Watch observability** — a sync consumer at revision R must observe deletes that occur at R+N. Without tombstones, the delete event is unrecoverable from History.
2. **Time-travel reads** — `get(key, revision: r)` must distinguish "key was deleted at r" from "key never existed."

Tombstones are subject to compaction (§7).

## 6. API surface

### Reads

```elixir
# Latest value
Concord.KV.get(key)
# => {:ok, value} | {:error, :not_found}

# With full record metadata
Concord.KV.get(key, metadata: true)
# => {:ok, %Concord.KV.Record{...}} | {:error, :not_found}

# At a specific revision (time-travel)
Concord.KV.get(key, revision: 1842)
# => {:ok, value_at_1842} | {:error, :not_found} | {:error, :compacted}

# History range for one key
Concord.KV.history(key, from_revision: r1, to_revision: r2, limit: 100)
# => {:ok, [%Record{}]}

# Cluster revision
Concord.KV.revision()
# => {:ok, 1843}
```

### Writes

Existing API preserved:

```elixir
Concord.KV.put(key, value)
Concord.KV.put(key, value, ttl: 30)
Concord.KV.put(key, value, lease: lease_id, content_type: "text/markdown")
Concord.KV.delete(key)
```

All writes return:

```elixir
{:ok, %{revision: 1843, prev_kv: nil | %Record{}}}
```

### Range and prefix

```elixir
Concord.KV.list(prefix: "/notes/", limit: 100)
Concord.KV.list(range: {"a", "z"}, limit: 100, keys_only: true)
Concord.KV.list(prefix: "/notes/", revision: 1842)  # snapshot read

# => {:ok, [%Record{}, ...], %{has_more: boolean, last_key: binary}}
```

Bounded results are mandatory. Default limit is 1000; callers can request lower but never unbounded.

## 7. Compaction

History grows monotonically without compaction. Three triggers, all configurable:

- **Revision-count-based**: keep last N revisions globally
- **Time-based**: keep history newer than T seconds (using `meta_time`)
- **Manual**: `Concord.KV.compact(up_to_revision: r)` for operators

Compaction is **a state-machine operation but does not go through Raft** — it is deterministic given current state and compaction parameters, so each replica runs it independently and arrives at identical state. The leader may emit compaction telemetry events for observability.

### Safety bound

Compaction must not strand active sync consumers below the compacted horizon. The state machine tracks `min_consumer_revision` (lowest revision any active watcher/changes-cursor is consuming from). Compaction is bounded above by:

```text
effective_compact_revision = min(configured_horizon, min_consumer_revision)
```

A sync request below `compact_revision` returns `{:error, {:compacted, compact_revision}}`. Consumer must re-snapshot and resume from current.

## 8. Snapshot format

```elixir
%Concord.Snapshot{
  schema_version: 2,
  global_state:   %{revision: ..., compact_revision: ..., next_lease_id: ..., ...},
  current_table:  [{key, %Record{}}],
  history_table:  [{{key, rev}, %Record{}}],
  lease_table:    [{lease_id, %Lease{}}],
  change_log:     [...]   # see sync doc
}
```

### Migration from v1

```text
For each row {key, %{value, expires_at}} in v1 snapshot:
  Create v2 Record with:
    value           = value
    create_revision = restore_revision
    mod_revision    = restore_revision
    version         = 1
    expires_at      = expires_at
    lease_id        = nil
    content_type    = nil
    metadata        = %{}

Set global_state.revision         = restore_revision
Set global_state.compact_revision = restore_revision
History table starts empty.
```

After migration, the cluster runs on v2 schema. Pre-migration history is lost (acceptable — v1 had no history). Forward compatibility only: v1 binaries cannot load v2 snapshots.

## 9. Determinism notes

- Revision advancement happens **inside** `apply/3`, before any ETS writes for the command. All replicas advance identically because they apply the same Raft entries in order.
- The Raft log entry does not carry the revision; the state machine assigns it. This avoids the writer needing to know the future revision in advance.
- `meta_time(meta)` is the only source of "current time" inside the state machine. `expires_at` is computed at apply time as `meta_time(meta) + ttl_seconds`.
- Bulk operations (`put_many`, multi-op txn) advance the revision **once** for the whole batch. All keys in the batch get the same `mod_revision`.

## 10. Indexes (preserved from v1)

Concord's existing index extractor design — declarative specs like `{:map_get, key}`, `{:nested, keys}`, `{:identity}` — is preserved verbatim. The same extractor module is reused by the transaction layer for `{:field, key, path, op, value}` compare predicates (see [`02-transaction-api.md`](./02-transaction-api.md) §4).

This is intentional code reuse: the extractor is already battle-tested in indexes, runs deterministically, and is data-only.

## 11. Telemetry

- `[:concord, :kv, :revision_advanced]` — measurements: `%{revision: r}`, metadata: `%{command_type: atom}`
- `[:concord, :kv, :compaction, :start | :stop]` — measurements: `%{revisions_removed: n, duration: us}`
- `[:concord, :kv, :history_size]` — periodic gauge of history table size
- `[:concord, :kv, :current_size]` — periodic gauge of current table size

## 12. Open questions

1. **Should `put` with identical value to current advance revision?**
   Recommend: yes. Simpler semantics; clients can use redundant `put` to refresh leases.
2. **Should `delete` of a non-existent key advance revision?**
   Recommend: no, matches etcd. No-op deletes are free.
3. **Should `content_type` participate in compare predicates?**
   Probably not. It's metadata for consumers, not a coordination field. Defer.
4. **Per-prefix retention policies?**
   Per-key/per-prefix history retention adds complexity. Recommend cluster-global retention with a `protected_prefix` allowlist for keys that must never compact.
