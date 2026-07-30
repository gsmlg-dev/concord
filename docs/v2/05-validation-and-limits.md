# Validation and Limits

**Status**: Implemented core admission limits; future limits are labeled below
**Depends on**: all other docs
**Required by**: enforcement at API boundaries

## 1. Purpose

Concord runs replicated commands through Viewstamped Replication (VSR). A
misbehaving client can:

- Block the cluster with oversized commands
- Crash the state machine with malformed input
- Break determinism with non-replicable values (functions, PIDs, refs)
- Exhaust memory by creating unbounded objects

All inputs must be validated **at the API boundary**, before submission to VSR. Validation failure returns `{:error, {:invalid_*, reason}}` to the client without affecting cluster state.

This doc consolidates the limits referenced in the other docs into a single source of truth.

## 2. Configuration

```elixir
config :concord,
  max_batch_size:   500,
  max_command_bytes: 64 * 1_024 * 1_024,

  # Transaction limits
  txn: [
    max_compare_ops:   64,
    max_success_ops:   128,
    max_failure_ops:   128,
    max_txn_bytes:     1_000_000,    # 1,000,000-byte serialized spec
    max_range_limit:   1_000
  ],

  # KV limits
  kv: [
    max_key_bytes:     4096,
    max_value_bytes:   16 * 1_024 * 1_024
  ]
```

The implemented batch, command, transaction, and KV settings are local
admission caps. They may be lowered for a deployment, but values above the
immutable version-one maxima are clamped and do not widen replay semantics.
Use the same local caps on every node for predictable request admission.
Invalid or negative cap values fail closed as zero.

## 3. Validation rules

### Universal — applied to every command

Walk the entire input recursively. Reject if any of:

- An anonymous function appears anywhere (`fn -> end`, `&Mod.fun/n` references)
- A PID, port, or reference appears
- A malformed or unsupported Concord compression envelope appears
- The recursive depth exceeds 100

Walking is depth-bounded (default depth 100). Specs nested beyond this are rejected as `{:invalid_spec, :depth_exceeded}`.

### Transactions

| Check | Limit | Rejection |
|---|---|---|
| Compare op count | `txn.max_compare_ops` (64) | `:too_many_compares` |
| Success op count | `txn.max_success_ops` (128) | `:too_many_success_ops` |
| Failure op count | `txn.max_failure_ops` (128) | `:too_many_failure_ops` |
| Logical serialized size | `txn.max_txn_bytes` (1,000,000 bytes) | `:spec_too_large` |
| Range op without `limit` | mandatory limit on `:prefix` / `:range` selectors | `:missing_range_limit` |
| `limit` value | `<= txn.max_range_limit` (1000) | `:range_limit_too_high` |
| Compare field unknown | not in `[:exists, :value, :field, :version, :create_revision, :mod_revision, :lease, :ttl]` | `:unsupported_compare_field` |
| Compare operator unknown | not in `[:==, :!=, :>, :>=, :<, :<=]` | `:unsupported_compare_op` |
| Operation type unknown | not in `[:get, :put, :delete, :touch]` | `:unsupported_op` |
| Put with both `ttl` and `lease` | conflict | `:ttl_and_lease_conflict` |
| Put references unknown lease | `lease_id` not in lease table | `:lease_not_found` (deferred to apply; rejected there) |
| Invalid idempotency key | empty, oversized, or non-binary | `:invalid_idempotency_key` |

### KV operations

| Check | Limit | Rejection |
|---|---|---|
| Key size | `kv.max_key_bytes` (4096) | `:key_too_large` |
| Empty key | not allowed | `:empty_key` |
| Value raw and logical serialized size | `kv.max_value_bytes` (16 MiB each) | `:value_too_large` |
| Aggregate raw and logical command size | `max_command_bytes` (64 MiB each) | `:command_too_large` |
| Bulk operation count | `max_batch_size` (500) | `:batch_too_large` |

Raw size and logical size after expanding Concord compression envelopes are
both bounded. Compression policy therefore cannot turn an oversized value,
transaction, or aggregate command into an admissible replicated operation.

Metadata/content-type byte caps, list caps, per-process watch caps, lease
attachment caps, and snapshot scheduling limits remain future proposals. They
are intentionally omitted from the implemented configuration above.

## 4. Validation locations

| Layer | What it validates |
|---|---|
| Public API (`Concord.*` modules) | All client-facing limits. Returns `{:error, {:invalid_*, reason}}` synchronously. |
| VSR command admission | Applies the immutable v1 recursive walk, raw and logical limits, and schema before submission. |
| State machine `apply/3` | Validates against current state (e.g., an unknown lease or missing key). Returns `{:error, reason}` in the apply result. |

Version-one replay re-checks its fixed size and safety rules without consulting
local configuration. A direct VSR submission therefore cannot bypass them.
Exact version-zero replay remains compatible with historical logs.

Compressed ETF input is trusted embedded input, not a sandbox. Expanded bytes
are bounded and unsafe runtime-local terms are rejected, but decoding can
allocate terms and intern atom names before recursive validation. Untrusted
wire protocols must translate a bounded external schema rather than forwarding
raw Erlang terms or compression envelopes.

## 5. Error model

Three categories, semantically distinct:

### Validation errors — `{:error, {:invalid_*, reason}}`

```elixir
{:error, {:invalid_txn, :too_many_compares}}
{:error, {:invalid_kv, :key_too_large}}
{:error, {:invalid_lease, :ttl_too_short}}
```

Synchronous, never reach VSR. Caller fixes input and retries.

### Apply errors — `{:error, reason}`

Returned from a VSR-applied command when the state forbids the operation:

```elixir
{:error, :not_found}
{:error, :unknown_lease}
{:error, :idempotency_conflict}
{:error, :lease_limit_exceeded}
```

These are real VSR commits (consumed a log entry) but did not mutate state. The cluster paid the consensus cost; the command was rejected at apply time.

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

## 6. Proposed telemetry

Validation events:

- `[:concord, :validation, :rejected]` — measurements: `%{}`, metadata: `%{api: atom, reason: atom}`
- `[:concord, :validation, :spec_depth_exceeded]` — metadata: `%{depth: n, api: atom}`
- `[:concord, :validation, :forbidden_value]` — metadata: `%{type: :function | :pid | :reference, api: atom}`

These events are proposed and are not emitted by the current implementation.

## 7. Open questions

1. **Should validation walk be cached by spec hash?** Many clients submit similar specs repeatedly. Caching saves re-walks. Recommend: defer; measure first.
2. **Should size limits be configurable per-namespace?** E.g., bigger limits for `/notes/` than for `/config/`. Adds complexity; defer.
3. **Should the state machine soft-fail on resource limits (e.g., return `:lease_limit_exceeded` from apply)?** Or hard-crash and rely on snapshot recovery? Recommend soft-fail — graceful degradation matters in production.
4. **Should we expose validation as a separate API (`Concord.validate/1`)?** Clients could pre-check before submission. Cheap to add; useful for tooling.
