# Sync and Watch

**Status**: Proposal
**Depends on**: Revisioned KV, Range/Prefix
**Required by**: Reactive consumers

## 1. Concept

The Sync module exposes Concord's revision stream to external consumers. Two access patterns:

- **Pull** (`Concord.Sync.changes/3`) — fetch a range of changes since a known revision. Suitable for polling and bootstrap-from-snapshot workflows.
- **Push** (`Concord.Sync.watch/2`) — register for live delivery of changes as they commit. Suitable for reactive consumers.

Both are revision-based: consumers identify a position via revision number, can resume from any revision still within the compaction horizon, and observe atomic commit boundaries via shared `revision` on events from one transaction.

Watches are **not part of Raft state**. The Raft log replicates the change log; per-node watch subscriptions are local concerns of each node. This separation:

- Keeps watch state out of consensus, avoiding apply-path cost
- Allows watches to survive across leader changes (with reconnection)
- Bounds the blast radius of slow consumers (one node's overload doesn't affect commit throughput)

## 2. Change events

```elixir
%Concord.Sync.Event{
  revision:    pos_integer(),       # cluster revision of this commit
  op_index:    non_neg_integer(),   # order within the commit (0, 1, 2...)
  type:        :put | :delete,
  key:         binary(),
  value:       term() | nil,         # nil for :delete
  prev_value:  term() | nil,         # if available
  mod_revision: pos_integer(),
  version:     non_neg_integer(),
  lease_id:    pos_integer() | nil
}
```

For a transaction that writes 3 keys at revision 1843:

```text
{revision: 1843, op_index: 0, type: :put,    key: "/a", ...}
{revision: 1843, op_index: 1, type: :put,    key: "/b", ...}
{revision: 1843, op_index: 2, type: :delete, key: "/c", ...}
```

The `(revision, op_index)` pair is a globally unique, monotonically ordered event ID. Consumers can checkpoint after any event and resume cleanly.

## 3. API

```elixir
defmodule Concord.Sync do
  @spec current_revision() :: {:ok, %{revision: pos_integer}} | {:error, term}

  @spec changes(selector, after_revision :: pos_integer, opts) ::
          {:ok, %{events: [Event.t()], next_revision: pos_integer, has_more: bool}}
          | {:error, {:compacted, pos_integer}}
          | {:error, term}
  # opts: limit (default 100), include_values (default true), prev_values (default false)

  @spec watch(selector, opts) :: {:ok, ref()} | {:error, term}
  # opts: from_revision, include_values, prev_values, filter

  @spec unwatch(ref()) :: :ok

  @spec compact(up_to_revision :: pos_integer) :: :ok | {:error, term}
end
```

`selector` is the same `{:key, k} | {:prefix, p} | {:range, s, e}` used elsewhere.

### Pull example

```elixir
{:ok, %{revision: rev}} = Concord.Sync.current_revision()

{:ok, %{events: events, next_revision: next}} =
  Concord.Sync.changes({:prefix, "/notes/"}, last_seen_rev, limit: 100)

# Process events, update checkpoint to `next`
```

### Push example

```elixir
{:ok, ref} = Concord.Sync.watch({:prefix, "/notes/"},
                                 from_revision: last_seen_rev + 1,
                                 include_values: true)

# In the calling process:
receive do
  {:concord_sync, ^ref, {:event, event}}            -> handle(event)
  {:concord_sync, ^ref, {:status, :ready, rev}}     -> mark_synced(rev)
  {:concord_sync, ^ref, {:status, :compacted, rev}} -> resnapshot()
  {:concord_sync, ^ref, {:status, :slow_consumer, dropped}} -> reconnect()
  {:concord_sync, ^ref, {:status, :leader_changed, leader}}  -> rebind()
end
```

## 4. Delivery: messages vs Stream

Default delivery is **messages to the calling process**. The handler is a normal GenServer using `handle_info/2`.

A `Stream` wrapper is provided as sugar for callers that prefer enumeration:

```elixir
Concord.Sync.watch_stream({:prefix, "/notes/"}, from_revision: rev)
|> Stream.each(&handle_event/1)
|> Stream.run()
```

The Stream blocks on receive internally. Status messages (compacted, slow_consumer, leader_changed) translate to stream halts with a tagged term.

**Open question**: should Stream wrapping be in the core API or a separate convenience library? Recommend core — it's cheap and developers expect it in Elixir.

## 5. Architecture

Per-node:

```
┌────────────────────────────────────────────────────────────────┐
│                       Concord Node                             │
│                                                                │
│  ┌─────────────────┐                                           │
│  │ State Machine   │  applies committed mutations               │
│  │ (Ra-managed)    │  emits events via Ra :send_msg effect      │
│  └────────┬────────┘                                           │
│           │                                                    │
│           ▼  {:changes, [Event{}]}                             │
│  ┌──────────────────────┐                                      │
│  │ Sync Dispatcher      │  receives event batches              │
│  │ (named GenServer)    │  routes to matching watch hub        │
│  └──────────┬───────────┘                                      │
│             │                                                  │
│             ▼                                                  │
│  ┌──────────────────────┐                                      │
│  │ Watch Hub            │  registry of subscribers             │
│  │ (Registry + index)   │  per-watcher bounded delivery queue  │
│  └──┬────────────────┬──┘                                      │
│     │                │                                         │
│     │                └──────────► Remote subscribers (via :pg) │
│     ▼                                                          │
│  ┌──────────────┐                                              │
│  │ Local        │  receive {:concord_sync, ref, ...}           │
│  │ Subscribers  │                                              │
│  └──────────────┘                                              │
└────────────────────────────────────────────────────────────────┘
```

### State machine → Sync Dispatcher

The state machine emits events via Ra's `:send_msg` effect after each mutating command commits:

```elixir
effects = [{:send_msg, Concord.Sync.Dispatcher, {:changes, events}}]
```

This is asynchronous w.r.t. the commit reply — the client receives `{:ok, %Result{...}}` as soon as the apply completes; event dispatch happens immediately after but doesn't block the response. Events are guaranteed to be delivered in commit order to the local Dispatcher.

**Events are emitted only on the leader.** Followers apply the same Raft entries but suppress event emission. Watchers connect to the leader (or via a local node that forwards). This avoids duplicate delivery.

### Watch Hub responsibilities

- Maintain registry: `{selector, watch_ref, subscriber_pid, opts}` records
- On each event from Dispatcher: scan registrations, dispatch to matching subscribers
- Apply per-watcher filtering (event type, value inclusion)
- Manage per-watcher bounded mailbox (backpressure)
- Replay historical events for new subscribers with past `from_revision`

For O(1)-ish dispatch, the Hub maintains:
- Hash map keyed by exact-match keys
- Ordered trie or sorted index of registered prefixes

Per-event cost: O(log P) where P is distinct prefixes. For modest P (hundreds), negligible vs Raft commit cost.

## 6. Change log storage

The state machine maintains a bounded change log so consumers can request `changes(after_revision: r)` without each query walking the history table.

Three viable storage strategies:

| Strategy | Description | Suitable for |
|---|---|---|
| **In-state map** | `change_log: %{rev => [events]}` in state struct | Tiny deployments, ≤10k events retained |
| **ETS-backed** | Dedicated `:ordered_set` table keyed by `{revision, op_index}` | Medium deployments, 100k–1M events |
| **Disk segments** | Append-only segment files on disk | Large deployments, multi-day retention |

**Recommend ETS-backed** for v2. Snapshot includes the change log table; restoring brings consumers back online from where they left off (subject to compaction).

Retention is tied to:

```text
max(compact_revision, current_revision - configured_history_window)
```

Compaction (`Concord.Sync.compact(rev)`) deletes change log entries with `revision <= rev`, raising `compact_revision`. Active watchers' `min_consumer_revision` lower-bounds the effective compaction floor.

## 7. Resumption from revision

A watch or changes request with `from_revision: R`:

- If `R > current_revision + 1`: valid; no events delivered until cluster catches up.
- If `R <= compact_revision`: returns `{:error, {:compacted, compact_revision}}`. Consumer must re-snapshot from current state and resume from `current_revision + 1`.
- Otherwise: deliver all events with revision >= R, oldest first.

For watch, the Hub performs an initial replay from the change log before transitioning to live delivery:

```text
1. Mark watch as STARTING
2. Buffer live events into a bounded staging queue
3. Read change log entries with revision >= from_revision
4. Dispatch buffered + replay in order to subscriber
5. Send {:status, :ready, current_revision}
6. Mark watch as READY; live events delivered directly
```

If the staging queue overflows during replay, the watcher is dropped with `:slow_consumer`. This is intentional — replay must complete promptly or the consumer is too slow for live delivery anyway.

## 8. Backpressure

Each watcher has a bounded delivery queue managed by the Hub (not by Erlang's process mailbox). Default capacity: 1000 events. Configurable per watch via `opts`.

When the queue is full:

1. Drop further events for that watcher.
2. Send `{:status, :slow_consumer, dropped_count}`.
3. Cancel the watch and unregister.

The watcher is responsible for reconnecting with `from_revision = last_seen_rev + 1`. Concord never blocks the apply path on slow consumers.

**Why Hub-managed bounds, not Erlang mailbox?** A subscriber process with default unbounded mailbox under sustained pressure consumes memory until OOM. Hub-managed bounds give predictable behavior with explicit failure signaling.

## 9. Cross-node subscription and leader-following

Watchers connect to the leader because only the leader's Dispatcher emits events. On leader change:

- Followers receiving the `:leader_change` Ra event tear down their Dispatcher.
- The new leader's Dispatcher comes online.
- Existing subscribers receive `{:status, :leader_changed, new_leader}`.
- They must re-bind: `watch(..., from_revision: last_seen_rev + 1)` against the new leader.

A library helper hides this dance:

```elixir
{:ok, ref} = Concord.Sync.watch(selector, follow_leader: true, ...)
```

With `follow_leader: true`, the wrapping client process:
- Monitors leader changes via `:ra` events (or via watching `/system/raft/leader` if exposed)
- Automatically re-subscribes on leader change with `from_revision = last_seen_rev + 1`
- Forwards events to the original caller transparently

Application code never thinks about leadership.

## 10. Watch lifecycle

```
       create
         │
         ▼
   ┌──────────┐  initial replay (from change log)
   │ STARTING │──────────────────────────────────┐
   └──────────┘                                  │
                                                 ▼
                                          ┌───────────┐
                                          │   READY   │  (steady state)
                                          └─────┬─────┘
                                                │
              ┌─────────────────┬───────────────┴───────────────┬─────────────────┐
              ▼                 ▼                               ▼                 ▼
         unwatch()        subscriber dies                 compaction         slow consumer
              │                 │                               │                 │
              ▼                 ▼                               ▼                 ▼
          ┌──────┐          ┌──────┐                       ┌─────────┐      ┌────────┐
          │ DEAD │          │ DEAD │                       │  ERROR  │      │ ERROR  │
          └──────┘          └──────┘                       │compacted│      │  slow  │
                                                           └─────────┘      └────────┘
```

The Hub monitors subscriber PIDs and cleans up registrations when subscribers die. No explicit `unwatch` is required for a normally-exiting consumer.

## 11. Atomicity with transactions

Events from one transaction share the same `revision`. Subscribers can group by revision to reconstruct atomic boundaries.

A helper for callers that care about transaction-level atomicity:

```elixir
Concord.Sync.watch_grouped(selector, opts)
# Delivers {:concord_sync, ref, {:revision_batch, revision, [Event{}]}}
# instead of individual events
```

A subscriber registered for a prefix that covers only **some** of a transaction's keys sees a partial view. This is by design — the subscription is scoped to its pattern. Subscribers needing full-transaction visibility should subscribe to a wider scope and filter locally.

## 12. Constraints

| Setting | Default | Notes |
|---|---|---|
| Max watches per node | 10,000 | Reject grants beyond |
| Max watches per subscriber PID | 100 | Per-caller safety bound |
| Per-watcher mailbox capacity | 1,000 events | Configurable via opts |
| Default `changes` limit | 100 | Max 1,000 |
| Change log retention | 1,000,000 events or 24 hours, whichever first | Both configurable |
| Min prefix length | 1 byte | `""` reserved for "watch everything" wildcard |

## 13. Telemetry

- `[:concord, :sync, :watch_created]` — measurements: `%{from_revision}`, metadata: `%{selector_type}`
- `[:concord, :sync, :watch_cancelled]` — measurements: `%{reason: atom, events_delivered: n}`
- `[:concord, :sync, :event_dispatched]` — measurements: `%{batch_size, matching_watchers}`
- `[:concord, :sync, :replay_start | :replay_stop]` — measurements: `%{events_replayed, duration}`
- `[:concord, :sync, :queue_depth]` — periodic gauge per watcher
- `[:concord, :sync, :compaction]` — measurements: `%{compacted_up_to, events_removed}`

## 14. Failure modes

| Scenario | Behavior |
|---|---|
| Leader fails over | Watchers receive `:leader_changed`; rebind. With `follow_leader: true`, transparent. |
| Subscriber crashes | Hub monitor detects exit, cleans up registration. |
| State machine restart | Treated as leader change; subscribers rebind from `last_seen_rev + 1`. |
| Network partition (subscriber on minority) | Watch stalls. On heal, library resumes; events from majority delivered. |
| Compaction during disconnect | Reconnect returns `:compacted`; subscriber re-snapshots. |
| Hub overloaded | Per-watcher backpressure (§8) shields apply path. |
| Subscriber slow | Dropped with `:slow_consumer`. Reconnect from current. |

## 15. Open questions

1. **In-state vs ETS-backed change log**: recommend ETS for v2. Confirm with benchmarks.
2. **Should followers maintain shadow dispatchers for eventually-consistent watch?** Useful for read-replica-style watches with lower latency. Adds complexity; defer.
3. **Should `delete_range` produce one event per key or one bulk event?** Recommend one event per key, with a shared `(revision, op_index_range)` for grouping. Preserves the "every key change is observable" property.
4. **Should `changes` support `keys_only`?** Yes — useful for clients that want event metadata without payload.
