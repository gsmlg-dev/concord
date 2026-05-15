# Leases

**Status**: Proposal
**Depends on**: Revisioned KV, Transaction API
**Required by**: Liveness for distributed consumers, distributed locks, ephemeral keys

## 1. Concept

A **lease** is a named, time-bounded object to which any number of keys can be attached. When the lease expires or is revoked, all attached keys are atomically deleted in a single Raft commit.

This generalizes Concord's current per-key TTL:

- **TTL** (existing): per-key timeout, set at put time, refreshed only by re-putting the key.
- **Lease** (new): independent object with its own TTL, multiple keys attached, one `keep_alive` refreshes them all, revocation deletes all attached keys atomically.

Per-key TTL continues to work for callers who don't need grouping; internally it's implemented as an anonymous single-key lease (§11).

## 2. Lease object

```elixir
%Concord.Lease{
  id:             pos_integer(),       # cluster-unique
  ttl:            pos_integer(),        # original ttl in seconds
  remaining_ttl:  pos_integer(),        # countdown
  granted_at:     pos_integer(),        # cluster revision at grant
  attached_keys:  MapSet.t(binary())
}
```

Stored in a dedicated lease table in the state machine (ETS `:set` keyed by `lease_id`). Serialized with snapshots.

## 3. API

```elixir
defmodule Concord.Lease do
  @spec grant(ttl :: pos_integer, opts :: keyword) ::
          {:ok, lease_id :: pos_integer} | {:error, term}

  @spec keep_alive(lease_id, opts :: keyword) ::
          {:ok, %{remaining_ttl: pos_integer}} | {:error, term}
  # opts: new_ttl (optional override of original ttl)

  @spec revoke(lease_id) :: :ok | {:error, term}
  # Immediately deletes all attached keys atomically.

  @spec info(lease_id) :: {:ok, %Concord.Lease{}} | {:error, :not_found}

  @spec list(opts :: keyword) :: [%Concord.Lease{}]
  # opts: include_anonymous (default false)
end
```

Attaching keys happens at put time, either through the top-level API or inside a transaction:

```elixir
Concord.KV.put("k", v, lease: lease_id)

# Or in a transaction
{:put, "k", v, %{lease: lease_id}}
```

A key can be attached to at most one lease at any time. Changing a key's lease attachment requires explicit delete + re-put.

## 4. Lifecycle

```
                grant/2
                  │
                  ▼
            ┌──────────┐
            │  ACTIVE  │◄──────── keep_alive/2 (resets remaining_ttl)
            └────┬─────┘
                 │
        ┌────────┴─────────┐
        ▼                  ▼
   remaining_ttl       revoke/1
   reaches 0              │
        │                 │
        ▼                 ▼
   ┌──────────────────────────────────────────┐
   │  EXPIRING — apply :expire_lease command  │
   └──────────────────────────────────────────┘
                  │
                  ▼
   ┌──────────────────────────────────────────┐
   │  EXPIRED — keys deleted at one revision  │
   └──────────────────────────────────────────┘
```

## 5. Expiration mechanics

The leader runs a **per-second expiration tick** (interval configurable). On each tick:

1. Scan the lease table for leases with `remaining_ttl <= 0`.
2. For each, submit an `{:expire_lease, lease_id}` Raft command.
3. The state machine applies the command:
   - Iterates `attached_keys`
   - Issues delete operations for each (producing `:delete` change events)
   - Removes the lease record from the lease table
   - Advances cluster revision once for the entire expiration

**Why through Raft?** Because key deletions must be observed identically by all replicas, including watchers. Local-timer expiration would diverge.

**Why a per-second tick rather than precise timers?** Simpler. The accuracy cost (a lease may live up to 1 second past its declared TTL) is acceptable. Matches etcd's approach.

### Leader changes

When leadership transfers, the new leader inherits the lease table from state (it was already replicated). Each lease's `remaining_ttl` is the value as of the last applied command. The new leader resumes ticking with no special handover. There's a brief window (~election duration, milliseconds) where leases age but ticks don't fire — harmless.

### Batching

A single tick may have many leases expiring. Issuing N Raft commands at once creates a commit spike. The expiration loop batches:

- Group up to 50 expirations per Raft command (configurable).
- Each expiration in the batch is still atomic at the same revision.
- Multiple batches dispatched with short pauses if needed.

## 6. Keep-alive

`Concord.Lease.keep_alive(id)` resets `remaining_ttl` to the original `ttl` (or to a new TTL if specified via `opts: [new_ttl: N]`). The state machine command is small (one integer write); throughput is high.

**Refresh frequency**: clients should refresh at roughly `ttl / 3` intervals to tolerate transient network blips. Example: 30s lease → keep_alive every 10s.

### KeepaliveWorker helper

A small GenServer manages refresh automatically:

```elixir
{:ok, lease_id} = Concord.Lease.grant(30)
{:ok, _worker} = Concord.Lease.KeepaliveWorker.start_link(lease_id, interval: 10_000)

# Worker refreshes every 10 seconds.
# On repeated failures, it stops; the lease expires naturally.
```

Keep-alive does **not** batch across leases. At 5 machines × 20 consumers × 1 keep_alive / 10s = 10 commits/sec, this is negligible Raft load.

## 7. Revocation

`revoke/1` is explicit, voluntary release. Same effect as expiration but immediate:

- All attached keys deleted in one Raft command.
- All watchers see `:delete` events at the same revision.
- Lease record removed.

Use cases:

- A consumer finishes its work and wants to release its ephemeral state immediately.
- An operator wants to forcibly evict a consumer's keys.

## 8. Lease ID generation

Two schemes considered:

- **Revision-derived**: `lease_id = grant_revision`. Naturally unique, monotonically increasing.
- **Independent counter**: state machine holds `next_lease_id`, incremented on each grant.

Recommend **independent counter** (Option B). Simpler reasoning; decouples lease IDs from write traffic. The counter lives in the global state alongside `revision`.

Lease IDs are positive 64-bit integers. Wraparound is not a practical concern.

## 9. Interaction with sync/watch

When a lease expires, the resulting Raft command produces N `:delete` events (one per attached key), all sharing the same `revision`. Watchers see these events through the normal sync stream.

Watchers don't see a dedicated `:lease_expired` event. If a consumer needs to know "this lease expired" specifically (rather than reasoning from the keys), it can subscribe to a dedicated `/leases/<id>/status` key that the granting client maintains.

## 10. Interaction with transactions

Transactions can:

- Attach keys to leases via `:put` op options (`%{lease: lease_id}`)
- Compare against `:lease` field of a key
- Reference leases in helper patterns (lock acquire, etc.)

Transactions **cannot**:

- Grant or revoke leases as part of the operation list. Lease lifecycle is a control-plane concern; mixing it with data-plane writes complicates reasoning. `Concord.Lease.grant/2` and `revoke/1` are separate API calls.

A txn that attaches a key to a non-existent or expired lease fails with `{:error, {:invalid_txn, :unknown_lease}}` — atomically, no partial application.

## 11. Backward compatibility with TTL

Existing API:

```elixir
Concord.KV.put("session:abc", data, ttl: 3600)
```

Internally translated to:

```elixir
{:ok, anon_lease_id} = grant(3600, anonymous: true)
Concord.KV.put("session:abc", data, lease: anon_lease_id)
```

Anonymous leases:

- Marked with an `anonymous: true` flag in the Lease record.
- Excluded from `Concord.Lease.list/1` by default (visible with `include_anonymous: true`).
- Cannot be referenced by `keep_alive` from outside — the ID was never returned to the caller.
- Expire naturally; their single attached key vanishes when TTL elapses.

This preserves existing TTL semantics exactly. New code wanting refreshable or multi-key TTL uses explicit leases.

`Concord.get_with_ttl/1` continues to work; it reports the remaining TTL of the attached anonymous lease.

## 12. Storage layout

```elixir
# Lease table (ETS :set keyed by lease_id)
{lease_id, %Concord.Lease{...}}

# Reverse lookup (key -> lease) is already in KeyRecord.lease_id; no separate index needed.

# For efficient "list all keys attached to lease X" during expiration:
# The Lease struct's attached_keys set is the authoritative reverse index.
```

`attached_keys` is maintained on every put-with-lease (add to set) and every delete or re-put-without-lease (remove from set). The set lives inside the Lease struct, serialized with snapshots.

Bounded size: hard limit of 10,000 attached keys per lease (rejected at put-with-lease time beyond this).

## 13. Edge cases

1. **Put-with-lease when the lease just expired but the expiration command hasn't applied yet**: the put fails with `{:error, :unknown_lease}`. The expiration command applies in the next Raft entry; client retries with a new lease.

2. **Keep-alive concurrent with revoke**: revoke wins (it's processed in order). Keep-alive returns `{:error, :not_found}`.

3. **Lease grant during network partition**: minority partition cannot grant (no quorum); majority can. After heal, minority sees the leases granted on the majority side.

4. **Very long lease (e.g., 24h) with frequent keep_alives**: no issue. Each keep_alive is small. Memory cost is one Lease record.

5. **Many small leases (e.g., 100,000 active)**: per-second tick scan iterates all leases. At 100k leases, scan is ~10ms — acceptable. Beyond ~1M, scan cost dominates; would need indexed expiration queue.

## 14. Constants and limits

| Setting | Default | Notes |
|---|---|---|
| Expiration tick interval | 1 second | Tunable; trades accuracy for tick traffic |
| Max attached keys per lease | 10,000 | Hard limit at put-with-lease time |
| Max active leases per cluster | 100,000 | Reject grants beyond |
| Expiration batch size | 50 leases per Raft command | Trades latency for atomicity |
| Min TTL | 1 second | Below this is meaningless given tick interval |
| Max TTL | None enforced | Application-determined |

## 15. Telemetry

- `[:concord, :lease, :granted]` — measurements: `%{ttl, lease_id}`, metadata: `%{anonymous: bool}`
- `[:concord, :lease, :renewed]` — measurements: `%{lease_id, remaining_ttl}`
- `[:concord, :lease, :revoked]` — measurements: `%{lease_id, attached_keys: n}`
- `[:concord, :lease, :expired]` — measurements: `%{lease_id, attached_keys: n}`
- `[:concord, :lease, :active_count]` — periodic gauge
- `[:concord, :lease, :tick_duration]` — measurements: `%{leases_scanned, leases_expired}`

## 16. Open questions

1. **Should `keep_alive` accept a new TTL?** Recommend yes (already in API). Useful for "extend by N seconds, regardless of original ttl."
2. **Should anonymous leases be promotable to refreshable?** No — would require returning the ID from `put`, complicating the API. Callers wanting refreshable should use explicit `Concord.Lease.grant/2`.
3. **Should leases support `description` / `label` for operator visibility?** Recommend optional `metadata: map` field on the lease, similar to KV record. Cheap and useful.
4. **Should very-long leases (>1h) use a different tick cadence?** Probably not — the per-second tick is cheap. Optimize later if needed.
