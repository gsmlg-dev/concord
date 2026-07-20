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

The supported production profile is a fixed, explicitly configured
three-replica group that tolerates one crash failure. Current operational
constraints are:

- fixed membership with no reconfiguration protocol;
- no automatic log-compaction or storage-retention policy;
- no storage-format migration between incompatible VSR releases;
- snapshots are explicit rather than managed by a production checkpoint
  policy.

## Fault and quorum model

VSR assumes crash failures, not Byzantine failures. A fixed, ordered
configuration contains `2f + 1` replicas and requires a quorum of `f + 1`.
Supported configuration sizes are currently one, three, and five replicas.
The first Concord production target is three replicas, which tolerates one
crashed replica.

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
partial or corrupt WAL tails during recovery. It does not yet provide an
automatic compaction or retention policy.

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

## Terminology

This application uses the VSR terms **primary**, **backup**, **replica**,
**view**, **view change**, **operation number**, and **commit number**.

See the
[Viewstamped Replication application ADR](https://github.com/gsmlg-dev/concord/blob/main/docs/adr/0001-viewstamped-replication-application.md)
for the architectural decision and scope.
