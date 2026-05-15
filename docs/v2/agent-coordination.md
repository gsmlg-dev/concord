# Example: Agent Coordination Application

**Status**: Reference example, not part of Concord's API
**Purpose**: Demonstrate the public primitives compose into a complete distributed coordination application without escape hatches.

> **Important**: This is an example. None of the namespaces, key conventions, helper modules, or workflow vocabulary in this document are part of Concord. Concord is a generic distributed database. This document shows how an application built on top of Concord can implement agent coordination patterns. The same primitives work for any other workflow.

## 1. Scenario

A team of N agents distributed across M machines (e.g., M=5) cooperates on a shared work list. Each agent:

- Pulls work from the shared list
- Writes structured notes as it works (test results, status updates, errors)
- Reports success or failure for each item

One or more **manager** processes:

- Watch progress notes across all items
- Coordinate dependent work
- Aggregate intermediate results in near-real-time
- Detect and recover from agent failures

All state lives in Concord. No external coordination service.

## 2. Cluster topology

```
┌─────────────────────────────────────────────────────────────┐
│  5-node Concord cluster (Raft quorum = 3)                   │
│                                                             │
│  Node 1            Node 2            Node 3                 │
│  ┌────────┐        ┌────────┐        ┌────────┐             │
│  │Concord │◄──────►│Concord │◄──────►│Concord │             │
│  └───┬────┘        └───┬────┘        └───┬────┘             │
│      │                 │                 │                  │
│   agents...         agents...         agents...             │
│   manager?          manager?          manager?              │
│                                                             │
│  Node 4            Node 5                                   │
│  ┌────────┐        ┌────────┐                               │
│  │Concord │◄──────►│Concord │                               │
│  └───┬────┘        └───┬────┘                               │
│      │                 │                                    │
│   agents...         agents...                               │
└─────────────────────────────────────────────────────────────┘
```

- Tolerates 2 simultaneous node failures.
- One manager is active at a time, elected via Concord (see §6).
- Agents talk to their local Concord node, which routes mutations to the leader.

## 3. Application key namespace

Chosen by the application. Concord doesn't care about path conventions; the patterns below are one reasonable layout.

```
/work/items/<id>/spec               # immutable definition
/work/items/<id>/state              # denormalized current state
/work/items/<id>/holder             # lease-bound; current owner agent
/work/items/<id>/attempts/<rev>     # per-attempt record
/work/items/<id>/notes/<rev>        # progress notes (Concord-persisted)
/work/items/<id>/result             # final result on completion

/work/agents/<agent_id>/status      # lease-bound; agent heartbeat

/work/system/manager                # lease-bound; current active manager
```

Design notes:

- **`/spec` immutable**: work definitions don't change after creation. Cacheable, contention-free.
- **`/state` denormalized**: the common read ("what's the status of item X?") is O(1) without scanning attempts.
- **`<rev>` as the per-attempt index**: monotonic, gap-free, no UUIDs needed. Concord revisions provide the natural ordering.
- **`/notes/<rev>`**: append-only, written via transactions. High-frequency chatter goes through PubSub (see §5).

## 4. Work item lifecycle

The application enforces a state machine using Concord transactions. Every transition is a single Raft commit.

```
   ┌──────────┐
   │ pending  │◄──────────────────────────────┐
   └────┬─────┘                               │
        │  claim (compare: state == pending)  │ reap
        ▼                                     │  (holder lease expired)
   ┌──────────┐                               │
   │ claimed  │───────────────────────────────┤
   └────┬─────┘                               │
        │  start_work (compare: holder == self)
        ▼                                     │
   ┌──────────┐                               │
   │ running  │───────────────────────────────┘
   └────┬─────┘
        │
   ┌────┴────┬─────────────┐
   ▼         ▼             ▼
┌──────────┐ ┌────────┐ ┌──────────┐
│succeeded │ │ failed │ │abandoned │
└──────────┘ └────────┘ └──────────┘
    (terminal; deleted by application retention policy)
```

### Claim transaction

```elixir
Concord.Txn.commit(%{
  compare: [
    {:field, "/work/items/#{id}/state", [:status], :==, :pending}
  ],
  success: [
    {:put, "/work/items/#{id}/state",
     %{status: :claimed, holder: agent_id}, %{prev_kv: true}},
    {:put, "/work/items/#{id}/holder", agent_id,
     %{lease: my_lease, content_type: "application/elixir-term"}},
    {:put, "/work/items/#{id}/attempts/#{revision}",
     %{kind: :claim, agent: agent_id, ts: now}, %{}}
  ],
  failure: [
    {:get, {:key, "/work/items/#{id}/state"}, %{}},
    {:get, {:key, "/work/items/#{id}/holder"}, %{}}
  ]
}, idempotency_key: "claim-#{agent_id}-#{id}")
```

On `succeeded: true`, the item is mine. On `succeeded: false`, the `failure` responses tell me current state and holder in one round-trip. The idempotency key makes claim retry safe.

### Complete transaction (atomic transition + result + final note)

```elixir
Concord.Txn.commit(%{
  compare: [
    {:value, "/work/items/#{id}/holder", :==, agent_id}
  ],
  success: [
    {:put, "/work/items/#{id}/state",
     %{status: :succeeded, completed_at: now}, %{prev_kv: true}},
    {:put, "/work/items/#{id}/result", result,
     %{content_type: "application/json"}},
    {:put, "/work/items/#{id}/notes/#{revision}",
     %{kind: :result, agent: agent_id, ts: now, payload: %{...}}, %{}},
    {:delete, {:key, "/work/items/#{id}/holder"}, %{}}
  ],
  failure: [
    {:get, {:key, "/work/items/#{id}/holder"}, %{}}
  ]
})
```

State transition, result, final note, and holder release are all atomic. If the holder field changed (e.g., reaped while I was working), my completion fails atomically.

### Reap transaction (run by manager when holder lease has expired)

When an agent's lease expires, its `/holder` key auto-deletes. The manager watches for these deletions and resets the item's state:

```elixir
Concord.Txn.commit(%{
  compare: [
    {:exists, "/work/items/#{id}/holder", :==, false},
    {:field, "/work/items/#{id}/state", [:status], :!=, :pending},
    {:field, "/work/items/#{id}/state", [:status], :!=, :succeeded},
    {:field, "/work/items/#{id}/state", [:status], :!=, :failed}
  ],
  success: [
    {:put, "/work/items/#{id}/state",
     %{status: :pending, prev_holder_lost: true}, %{prev_kv: true}},
    {:put, "/work/items/#{id}/notes/#{revision}",
     %{kind: :info, reason: :reaped}, %{}}
  ],
  failure: []
})
```

The `:field` predicate exact-matches state.status. The compare list expresses "holder is gone AND state is not in a terminal status." If the holder reappears between the watch event and this transaction, the compare fails and we leave the item alone.

## 5. Notes channel — what goes where

| Event type | Channel | Rationale |
|---|---|---|
| State transitions | Concord (txn) | Coordination-critical; must be durable, ordered |
| Milestone notes ("stage 3 done") | Concord (`/notes/<rev>`) | Manager reacts; worth committing |
| Errors and warnings | Concord (`/notes/<rev>`) | Manager may take corrective action |
| Final result | Concord (`/result`) | Authoritative outcome |
| Per-line debug logs | `Phoenix.PubSub` or `:pg` | Volume too high for Raft; loss on crash acceptable |
| Continuous progress % | `Phoenix.PubSub` or `:pg` | Live-update only, not durable |

**Rate-limit at the agent SDK**, not at Concord. Agents self-throttle Concord writes to (e.g.) 10/sec sustained, 50 burst. Excess events go through PubSub.

### Note record shape

```elixir
%{
  kind:       :started | :progress | :warning | :error | :result | :info,
  agent_id:   binary,
  ts:         pos_integer,
  payload:    map
}
```

Stored with `content_type: "application/elixir-term"` or `"application/json"` depending on consumer needs.

The `kind` tag enables pattern-matching dispatch in subscribers. Avoid free-text parsing.

## 6. Manager — singleton with leader election

Only one manager is active across the cluster at any time. Achieved via lease-bound key:

```elixir
{:ok, my_lease} = Concord.Lease.grant(30)

case Concord.Txn.commit(%{
       compare: [{:exists, "/work/system/manager", :==, false}],
       success: [{:put, "/work/system/manager",
                  %{pid_info: my_info, since: now}, %{lease: my_lease}}],
       failure: [{:get, {:key, "/work/system/manager"}, %{}}]
     }) do
  {:ok, %{succeeded: true}} ->
    Concord.Lease.KeepaliveWorker.start_link(my_lease, interval: 10_000)
    start_manager_loop(my_lease)

  {:ok, %{succeeded: false, responses: [{:get, _, %{kvs: [current]}}]}} ->
    # Another manager is active; watch the key
    {:ok, ref} = Concord.Sync.watch({:key, "/work/system/manager"},
                                     from_revision: current.mod_revision + 1)
    standby_loop(ref)
end
```

The active manager keep-alives its lease every 10s. If it crashes or partitions, the lease expires within 30s, the key is deleted, and standby candidates race to acquire (see §6.1).

### 6.1 Election race

When the active manager's lease expires, all standby candidates see the `:delete` event simultaneously. They all attempt the acquire transaction. Concord's compare-and-swap ensures exactly one wins; the rest see `succeeded: false` and re-enter standby with a new watch.

### 6.2 Projection over the sync stream

Once elected, the manager:

1. Snapshots current work state: `Concord.KV.list(prefix: "/work/items/")` → builds in-memory `%{item_id => state}`.
2. Records the current cluster revision.
3. Subscribes: `Concord.Sync.watch({:prefix, "/work/"}, from_revision: snapshot_rev + 1)`.
4. Reacts to events by pattern-matching on the key's path component.

```elixir
def handle_info({:concord_sync, _ref, {:event, ev}}, state) do
  state = apply_event(state, ev)
  state = react(state, ev)
  {:noreply, state}
end

defp react(state, %Event{key: key} = ev) do
  case parse_key(key) do
    {:work_state, id}      -> on_state_change(state, id, ev)
    {:work_note, id, _rev} -> on_note(state, id, ev)
    {:work_result, id}     -> on_result(state, id, ev)
    {:work_holder, id}     -> on_holder_change(state, id, ev)
    _                      -> state
  end
end
```

### 6.3 Failover continuity

On takeover by a new manager:

1. Snapshots current state from Concord.
2. Subscribes from `current_revision + 1`.

No event loss. New events flow from that point.

If the new manager wants to know "what happened during the gap," it can pull `Concord.Sync.changes/3` for the historical range. But this is optional — coordination decisions are based on current state, not historical replay.

## 7. Agent SDK shape

A thin client library wraps the patterns. Not part of Concord; this is the application's API.

```elixir
defmodule MyApp.Agent do
  @spec start_link(opts) :: GenServer.on_start
  # Manages the agent's lease, heartbeat worker, and namespace

  @spec claim_any(filter \\ fn _ -> true end) :: {:ok, item_id} | {:error, :no_work}
  @spec heartbeat() :: :ok
  @spec note(item_id, kind, payload) :: :ok
  @spec complete(item_id, result) :: :ok | {:error, term}
  @spec fail(item_id, reason) :: :ok | {:error, term}
  @spec abandon(item_id) :: :ok | {:error, term}
end
```

Agent loop:

```elixir
{:ok, _agent} = MyApp.Agent.start_link(id: "agent_1", lease_ttl: 30)

Stream.repeatedly(fn ->
  with {:ok, item_id} <- MyApp.Agent.claim_any() do
    MyApp.Agent.note(item_id, :started, %{worker: self()})
    result = do_work(item_id)
    MyApp.Agent.complete(item_id, result)
  else
    {:error, :no_work} -> Process.sleep(1000); :noop
  end
end)
|> Stream.run()
```

The agent never thinks about transactions, leases, or revisions directly. They're under the SDK surface.

## 8. Failure modes

| Failure | Detection | Recovery |
|---|---|---|
| Agent crashes | Lease expires within `ttl` | Holder key auto-deletes → manager reaps state → another agent claims |
| Machine dies (5 → 4 nodes) | Quorum still 3 | Agents on dead machine: leases expire, claims reaped. Other nodes continue. |
| Network partition (3/2) | Minority cannot reach quorum | Minority agents: writes fail. They stop claiming new work. On heal, they resume; lost state reconciled by manager reaps. |
| Manager crashes | Manager's lease expires within `ttl` | Standby manager takes over via `/work/system/manager` watch |
| All managers down | No automatic detection | New manager process started by deployment system; takes over via lease grant |
| Watch backpressure (manager overloaded) | `:slow_consumer` status | Manager exits, supervisor restarts, re-reads state and resubscribes |
| Lease expires while agent paused (long GC) | Next state-change txn fails (compare on holder) | Agent abandons gracefully; work reclaimable |

## 9. Capacity estimates

For sizing intuition: M=5 machines, A=10 agents/machine:

| Quantity | Estimate |
|---|---|
| Active agents | 50 |
| Concurrent active items | ~50 (one per agent) |
| Total items in `/work/items/` | depends on retention; assume 10,000 |
| Structured notes per second (steady) | 50 agents × 1 note/sec = 50 |
| Keep-alives per second | 50 agents × 1 keep_alive / 10s = 5 |
| Manager + housekeeping ops | <1/sec average |
| **Total commits/sec** | **~60-100** under steady load; well within Concord's range |
| Watch events/sec to manager | ~60-100 |
| Manager projection memory | ~10,000 items × ~1 KB = 10 MB |

Raft commit latency on local LAN + SSD: p50 1-3 ms, p99 10-30 ms.

## 10. What this example demonstrates

If Concord ships with the primitives in `01`-`05`, this entire application is implementable with:

- **No new Concord features** — only the public API
- **No polling** — everything is event-driven via watch
- **No custom timeout/retry logic** — leases handle liveness; idempotency keys handle retries
- **No race conditions** — transactions guarantee atomic state transitions
- **No event loss across manager failover** — resumable watch + revision-based checkpoints

The complete agent + manager loops fit in a few hundred lines of application code per side, built entirely on Concord's public surface.

## 11. What is NOT in Concord

Re-emphasizing the boundary:

- `/work/`, `/work/items/`, `/work/system/manager` — application namespace conventions
- The work-item state machine (`pending → claimed → running → ...`) — application logic
- The manager singleton election pattern — application logic (built on `Concord.Txn` + `Concord.Lease`)
- The reap-on-holder-delete pattern — application logic (built on `Concord.Sync.watch`)
- The note rate-limiting logic — application logic
- The agent SDK — separate library

If a competing application wants a different state machine, different namespace, different election strategy, different SDK — none of this is changed in Concord. The primitives are domain-neutral.
