# Viewstamped Replication

`viewstamped_replication` is a standalone, protocol-generic OTP application for
replicating deterministic state machines with Viewstamped Replication (VSR). It
does not depend on Concord. Concord depends on this application and uses it as
its only replicated engine.

## Status

This application implements the pure protocol kernel, supervised replica
runtime, client sessions, normal operation, view changes, recovery, state
transfer, storage adapters, transport adapters, and telemetry emission. It is
the replication runtime for Concord 3.0.

The supported production profiles are fixed, explicitly configured groups of
one through six replicas. Current operational constraints are:

- fixed membership with no reconfiguration protocol;
- no automatic log-compaction or storage-retention policy;
- applied client results are retained without eviction, so deployments that
  continually create new client identities need a future replicated
  session-retirement policy to bound the durable client table;
- no storage-format migration between incompatible VSR releases;
- snapshots are explicit rather than managed by a production checkpoint
  policy.

## Fault and quorum model

VSR assumes crash failures, not Byzantine failures. A fixed, ordered
configuration contains one through six replicas and requires a strict majority
quorum of `floor(n / 2) + 1`. It tolerates `floor((n - 1) / 2)` crashed
replicas. Even-sized groups therefore have the same failure tolerance as the
preceding odd-sized group while requiring one additional quorum vote.

Membership is explicit and fixed. It is never inferred from connected
distributed Erlang nodes. The primary for a view is selected deterministically
from the view number and the ordered configuration.

## Runtime and storage

The application supervisor owns a registry and a dynamic replica supervisor.
Multiple independent groups may run in one VM. Public entry points include:

```elixir
ViewstampedReplication.start_replica(opts)
ViewstampedReplication.stop_replica(group_id, replica_id)
ViewstampedReplication.status(group_id, replica_id)
ViewstampedReplication.primary(group_id, replica_id)
ViewstampedReplication.snapshot(group_id, replica_id)
ViewstampedReplication.command(group_id, operation, client: client)
ViewstampedReplication.read(group_id, operation,
  replica_id: replica_id,
  replicas: members
)
```

`ViewstampedReplication.Storage.Memory` is volatile and intended for tests.
`ViewstampedReplication.Storage.File` provides a checksummed, fsynced WAL,
atomic checkpoints, configuration identity validation, and truncation of
incomplete version-two WAL tails whose length header is checksummed. Complete
corrupt records and ambiguous incomplete version-one records fail recovery
without modifying the WAL. A tail ending in a partial magic prefix, or in the
complete magic without a version byte, is treated as an incomplete append and
truncated. It does not yet provide an automatic compaction or retention policy.

WAL records and checkpoints have the same fixed 256 MiB ETF payload limit.
Oversized writes fail before changing the WAL or replacing a checkpoint, so
everything acknowledged to disk remains readable by recovery. State that grows
beyond one checkpoint record requires a future chunked snapshot format; the
adapter does not silently split or truncate it.

Writes default to version one for rollback compatibility. The file storage
option `write_version` controls both new WAL records and rewritten checkpoints.
Set `write_version: 2` only after every deployment has passed the old-reader
rollback window. Once either a version-two WAL record or checkpoint exists,
setting `write_version: 1` does not downgrade it, and opening that directory
with an older reader is unsafe. A later binary rollback requires restoring a
separately verified version-one-compatible backup; no automatic downgrade is
provided.

State transfer must persist the transferred snapshot together with its matching
hard state, log, commit/applied counters, and client table. A custom
`ViewstampedReplication.Storage` adapter must implement
`install_snapshot_state/3` as one crash-atomic operation. The runtime returns
`{:atomic_snapshot_state_install_not_supported, adapter}` instead of attempting
a non-atomic fallback when that callback is absent.

`ViewstampedReplication.Transport.Local` routes through the local registry and
supports an injectable delivery function for deterministic fault tests.
`ViewstampedReplication.Transport.Distribution` routes only through explicit
endpoint maps; connected Erlang nodes are never treated as membership.

## Architecture

The protocol core is pure and deterministic:

```text
event + protocol state
        |
        v
ViewstampedReplication.Protocol.step/2
        |
        v
new protocol state + ordered effects
```

The protocol does not send messages, read clocks, schedule timers, access
storage, emit telemetry, or invoke the replicated state machine. The
supervised replica runtime interprets its ordered effects.

Replicated services implement `ViewstampedReplication.StateMachine`. Operations
must be deterministic and free of arbitrary external side effects.

## Performance benchmark

Run the explicit local-memory benchmark to compare command throughput and
p50/p95/p99 latency across all supported cluster sizes:

```bash
mix do --app viewstamped_replication cmd mix test \
  test/performance/cluster_size_benchmark.exs --trace
```

The benchmark defaults to four concurrent clients with 100 commands per client
for each cluster size. Override the workload with
`VSR_BENCHMARK_CLIENTS` and `VSR_BENCHMARK_OPERATIONS_PER_CLIENT`. Optional
regression gates are available through `VSR_BENCHMARK_MIN_OPS_PER_SECOND` and
`VSR_BENCHMARK_MAX_P99_US`.

This benchmark uses in-memory storage and local transport so it measures the
protocol and OTP runtime rather than disk or network performance. Production
results must also be measured with the deployment's actual storage, network,
and hardware.

## Terminology

This application uses the VSR terms **primary**, **backup**, **replica**,
**view**, **view change**, **operation number**, and **commit number**.

See the
[Viewstamped Replication application ADR](https://github.com/gsmlg-dev/concord/blob/main/docs/adr/0001-viewstamped-replication-application.md)
for the architectural decision and scope.
