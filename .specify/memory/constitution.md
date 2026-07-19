# Concord Constitution

## I. Embedded database, not a service

Concord is a library dependency that starts inside the host application's OTP
tree. Its core responsibility is replicated key-value storage, not application
policy or service delivery.

Concord provides KV/MVCC operations, transactions, leases, TTL, secondary
indexes, Watch/change-log support, logical backup/restore, local storage modes,
and telemetry hooks.

Authentication, authorization, multi-tenancy policy, HTTP serving, compliance
logging, metrics exporters, tracing backends, and encryption policy belong in
the host application or separate wrappers.

## II. Consistency through Viewstamped Replication

Viewstamped Replication is Concord's only replicated runtime.

- A majority quorum is required to commit operations.
- The minority side of a partition cannot acknowledge writes.
- Every replica uses the same explicit, ordered membership list.
- Supported replicated configurations have one, three, or five members.
- Client request identity and sequence numbers suppress duplicates across
  retries and view changes.

The public `:eventual`, `:leader`, and `:strong` consistency names currently
use the same replicated query barrier and provide linearizable reads.

## III. Deterministic state machine

`Concord.StateMachine.Core` is the source of truth. These invariants are
non-negotiable:

1. Command application is a pure function of replicated context, command,
   and prior state.
2. Command time comes from `Context.timestamp_ms`, never local wall clock.
3. Replicated state and commands contain serialization-safe deterministic
   data; declarative extractor specs are preferred over closures.
4. Replicated mutations go through `Concord.Engine.command/2`.
5. Core state is authoritative; ETS tables are compatibility materialized
   views and can be rebuilt.
6. Public feature modules do not address replicas, transports, or storage
   adapters directly.

Violations can cause replica divergence, invalid recovery, or duplicate client
effects.

## IV. Explicit durability and recovery

The VSR file storage adapter owns a checksummed write-ahead log and atomic
checkpoint. Durable state includes protocol hard state, log entries,
commit/applied positions, the client table, and a versioned state-machine
snapshot.

- Fresh multi-node storage is bootstrapped once with `bootstrap: true`.
- Restarts against non-empty storage use `bootstrap: false`.
- A partial or corrupt WAL tail is truncated only to the last valid record.
- Recovery restores the checkpoint and replays committed operations after it.
- Snapshot compaction must not change logical state or duplicate effects.

No compatibility with the removed 2.x Ra storage format is required for the
3.0 cutover.

## V. Minimal engine boundary

`Concord.Engine` remains because Concord supports three intentional modes:

- `Concord.Engine.VSR` — default replicated engine;
- `Concord.Engine.Local` — in-memory node-local engine;
- `Concord.Engine.Turso` — durable node-local Turso/libSQL engine.

`Concord.Cluster.*` pins VSR. `Concord.Local.*` and `Concord.Turso.*` must not
leak writes into replicated state.

## VI. Test-driven distributed correctness

Changes must be verified at the lowest useful level and at distributed
boundaries when relevant.

- Core unit tests cover deterministic state transitions.
- VSR protocol tests cover normal operation, view changes, recovery, storage,
  transport, duplicate suppression, and safety properties.
- Concord integration tests use an isolated singleton VSR cluster.
- Release E2E covers three-node KV, MVCC, transactions, leases, engine
  isolation, strong reads, and primary failover.
- Durable storage changes require restart/recovery coverage.

Tests using registered runtime names or shared compatibility ETS tables run
with `async: false`.

## VII. API and data compatibility

Public API changes follow semantic versioning:

- major: breaking public API or on-disk format change;
- minor: backward-compatible feature;
- patch: backward-compatible fix.

Versioned VSR snapshots must either restore correctly or fail with an explicit
validation error. Historical 2.x Ra documents remain historical records and do
not define current runtime behavior.

## VIII. Scope and quality gates

Every change should be the minimum coherent implementation of its requirement.
Do not add speculative engines, compatibility shims, or alternate replication
paths.

Required gates:

- `mix format --check-formatted`;
- compilation with warnings treated as errors;
- relevant unit/integration tests;
- full umbrella tests for cross-application changes;
- VSR release E2E for distributed runtime changes;
- `git diff --check`.

Commits use semantic prefixes and omit generated-by/co-author trailers.

## Technology constraints

- Elixir 1.17+ and supported OTP releases;
- Viewstamped Replication for replicated consensus;
- Erlang distribution or an explicit transport adapter;
- checksummed WAL plus atomic checkpoints for VSR file storage;
- immutable Core state with optional ETS materialized views;
- `:telemetry` for instrumentation.
