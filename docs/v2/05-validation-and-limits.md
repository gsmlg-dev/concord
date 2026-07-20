# Validation and Limits

**Status**: Proposal
**Depends on**: all other docs
**Required by**: enforcement at API boundaries

## 1. Purpose

Concord runs commands through Raft. A misbehaving client can:

- Block the cluster with oversized commands
- Crash the state machine with malformed input
- Break determinism with non-replicable values (functions, PIDs, refs)
- Exhaust memory by creating unbounded objects

All inputs must be validated **at the API boundary**, before submission to Raft. Validation failure returns `{:error, {:invalid_*, reason}}` to the client without affecting cluster state.

This doc consolidates the limits referenced in the other docs into a single source of truth.

## 2. Configuration

```elixir
config :concord,
  # Transaction limits
  txn: [
    max_compare_ops:   64,
    max_success_ops:   128,
    max_failure_ops:   128,
    max_txn_bytes:     1_000_000,    # 1 MiB serialized spec
    max_range_limit:   1_000
  ],

  # KV limits
  kv: [
    max_key_bytes:     4096,
    max_value_bytes:   1_000_000,    # 1 MiB
    max_metadata_bytes: 8192,
    max_content_type_bytes: 256,
    default_list_limit: 1_000,
    max_list_limit:    10_000
  ],

  # Sync / watch limits
  sync: [
    max_watches_per_node:       10_000,
    max_watches_per_pid:        100,
    default_changes_limit:      100,
    max_changes_limit:          1_000,
    watcher_mailbox_capacity:   1_000,
    change_log_retention_count: 1_000_000,
    change_log_retention_time:  86_400,  # 24h
    min_prefix_bytes:           1
  ],

  # Lease limits
  lease: [
    max_attached_keys:       10_000,
    max_active_leases:       100_000,
    expiration_tick_interval: 1_000,    # ms
    expiration_batch_size:   50,
    min_ttl_seconds:         1,
    idempotency_cache_size:  100_000,
    idempotency_retention_revisions: 10_000
  ],

  # Snapshot limits
  snapshot: [
    snapshot_interval_commands: 50_000,
    snapshot_interval_seconds:  3_600
  ]
```

Defaults are conservative for small-to-medium deployments. Tune for production load.

## 3. Validation rules

### Universal — applied to every command

Walk the entire input recursively. Reject if any of:

- An anonymous function appears anywhere (`fn -> end`, `&Mod.fun/n` references)
- A PID, port, or reference appears
- A struct from a module that isn't in the allowlist of serializable structs
- Any binary exceeds its respective size limit
- A key is `""` or contains null bytes outside permitted positions
- A revision-bearing field is negative or non-integer
- A TTL value is `<= 0` or `> 2^31`

Walking is depth-bounded (default depth 100). Specs nested beyond this are rejected as `{:invalid_spec, :depth_exceeded}`.

### Transactions

| Check | Limit | Rejection |
|---|---|---|
| Compare op count | `txn.max_compare_ops` (64) | `:too_many_compares` |
| Success op count | `txn.max_success_ops` (128) | `:too_many_success_ops` |
| Failure op count | `txn.max_failure_ops` (128) | `:too_many_failure_ops` |
| Serialized size | `txn.max_txn_bytes` (1 MiB) | `:spec_too_large` |
| Range op without `limit` | mandatory limit on `:prefix` / `:range` selectors | `:missing_range_limit` |
| `limit` value | `<= txn.max_range_limit` (1000) | `:range_limit_too_high` |
| Compare field unknown | not in `[:exists, :value, :field, :version, :create_revision, :mod_revision, :lease, :ttl]` | `:unsupported_compare_field` |
| Compare operator unknown | not in `[:==, :!=, :>, :>=, :<, :<=]` | `:unsupported_compare_op` |
| Operator-field mismatch | e.g., `:>` against `:value` | `:invalid_compare_operator` |
| Operation type unknown | not in `[:get, :put, :delete, :touch]` | `:unsupported_op` |
| Put with both `ttl` and `lease` | conflict | `:ttl_and_lease_conflict` |
| Put references unknown lease | `lease_id` not in lease table | `:unknown_lease` (deferred to apply; rejected there) |
| Duplicate compare on same `(field, key)` | each `(field, key)` allowed once | `:duplicate_compare` |
| Idempotency key with PID/ref | non-serializable | `:invalid_idempotency_key` |

### KV operations

| Check | Limit | Rejection |
|---|---|---|
| Key size | `kv.max_key_bytes` (4096) | `:key_too_large` |
| Empty key | not allowed | `:empty_key` |
| Value serialized size | `kv.max_value_bytes` (1 MiB) | `:value_too_large` |
| Metadata size | `kv.max_metadata_bytes` (8 KiB) | `:metadata_too_large` |
| Content-type size | `kv.max_content_type_bytes` (256) | `:content_type_too_large` |
| List limit | `<= kv.max_list_limit` (10,000) | `:list_limit_too_high` |

### Sync / watch

| Check | Limit | Rejection |
|---|---|---|
| Watches per node | `sync.max_watches_per_node` (10,000) | `:too_many_watches` |
| Watches per subscribing PID | `sync.max_watches_per_pid` (100) | `:too_many_watches_per_pid` |
| `from_revision` below `compact_revision` | normal compaction event | `{:compacted, compact_revision}` (not an `:invalid_*` error) |
| Prefix length | `>= sync.min_prefix_bytes` (1) | `:prefix_too_short` |
| Changes limit | `<= sync.max_changes_limit` (1000) | `:changes_limit_too_high` |

### Leases

| Check | Limit | Rejection |
|---|---|---|
| TTL value | `>= lease.min_ttl_seconds` (1) | `:invalid_ttl` |
| Active leases | `<= lease.max_active_leases` (100,000) | `:lease_limit_exceeded` |
| Attached keys per lease | `<= lease.max_attached_keys` (10,000) | `:lease_attachment_limit` |

## 4. Validation locations

| Layer | What it validates |
|---|---|
| Public API (`Concord.*` modules) | All client-facing limits. Returns `{:error, {:invalid_*, reason}}` synchronously. |
| Spec serializer | Recursive walk for functions/PIDs/refs/depth. Last line of defense before Raft submission. |
| State machine `apply/3` | Validates against current state (e.g., `:unknown_lease`, `:not_found`). Returns `{:error, reason}` in the apply result. |

**The state machine itself must also re-check size limits** as a backstop. A direct Raft command bypass (operator tooling, replay attack) could submit oversized data without going through the public API. The state machine treats any oversized input as a protocol violation and refuses to apply.

## 5. Error model

Three categories, semantically distinct:

### Validation errors — `{:error, {:invalid_*, reason}}`

```elixir
{:error, {:invalid_txn, :too_many_compares}}
{:error, {:invalid_kv, :key_too_large}}
{:error, {:invalid_lease, :ttl_too_short}}
```

Synchronous, never reach Raft. Caller fixes input and retries.

### Apply errors — `{:error, reason}`

Returned from a Raft-applied command when the state forbids the operation:

```elixir
{:error, :not_found}
{:error, :unknown_lease}
{:error, :idempotency_conflict}
{:error, :lease_limit_exceeded}
```

These are real Raft commits (consumed a log entry) but did not mutate state. The cluster paid the consensus cost; the command was rejected at apply time.

### Cluster errors — `{:error, reason}`

Infrastructure failures:

```elixir
{:error, :no_leader}
{:error, :timeout}
{:error, {:not_leader, leader}}
{:error, :cluster_not_ready}
```

Caller retries with backoff. Operation may or may not have committed — clients should use idempotency keys for write retries.

### Compaction errors — `{:error, {:compacted, compact_revision}}`

Special case for sync resumption. Not really an error from the application's perspective — it's a normal lifecycle event saying "the requested revision is no longer available; re-snapshot from current."

### Successful failure — `{:ok, %Result{succeeded: false}}`

A transaction whose compares didn't hold returns `{:ok, ...}` with `succeeded: false`. This is **not an error**. Conflating compare-failure with `{:error, ...}` would force callers to use try/catch for normal control flow.

## 6. Telemetry

Validation events:

- `[:concord, :validation, :rejected]` — measurements: `%{}`, metadata: `%{api: atom, reason: atom}`
- `[:concord, :validation, :spec_depth_exceeded]` — metadata: `%{depth: n, api: atom}`
- `[:concord, :validation, :forbidden_value]` — metadata: `%{type: :function | :pid | :reference, api: atom}`

These should be alarmed on in production — a sustained spike indicates a buggy client or an attack.

## 7. Open questions

1. **Should validation walk be cached by spec hash?** Many clients submit similar specs repeatedly. Caching saves re-walks. Recommend: defer; measure first.
2. **Should size limits be configurable per-namespace?** E.g., bigger limits for `/notes/` than for `/config/`. Adds complexity; defer.
3. **Should the state machine soft-fail on resource limits (e.g., return `:lease_limit_exceeded` from apply)?** Or hard-crash and rely on snapshot recovery? Recommend soft-fail — graceful degradation matters in production.
4. **Should we expose validation as a separate API (`Concord.validate/1`)?** Clients could pre-check before submission. Cheap to add; useful for tooling.
