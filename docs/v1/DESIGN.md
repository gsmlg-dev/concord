# Concord Architecture

## Overview

Concord is an embedded, strongly consistent key-value store for Elixir. Its
replicated runtime uses Viewstamped Replication (VSR) with one, three, or five
ordered members. A majority quorum commits each operation, so a minority
partition cannot acknowledge writes.

## Components

- `Concord.Application` supervises the VSR runtime, TTL cleanup, Watch
  dispatch, telemetry, and optional node-local engines.
- `Concord.Engine.VSR.Supervisor` builds one replica, one client session, and
  the Concord VSR engine from the explicit membership configuration.
- `ViewstampedReplication.Replica` serializes protocol transitions and
  interprets transport, storage, timer, and state-machine effects.
- `Concord.Engine.VSR.StateMachine` adapts committed VSR operations to
  `Concord.StateMachine.Core`.
- `Concord.StateMachine.Core` owns the deterministic KV, MVCC, index, lease,
  transaction, and backup state.
- `ViewstampedReplication.Storage.File` persists the VSR log and atomic
  checkpoints.

`Concord.Local` and `Concord.Turso` are explicit node-local alternatives. They
do not participate in VSR membership or replication.

## Membership and primary selection

Membership is explicit and ordered. Every replica must use the same `group_id`
and member list. The current view selects a deterministic primary from that
order. A view change elects the next primary when the current primary becomes
unavailable.

Fresh multi-node clusters must start once with `bootstrap: true`. Durable
restarts use `bootstrap: false`; replicas recover their hard state, log,
commit/applied positions, client table, and latest state-machine checkpoint
from storage.

## Write path

1. Any Concord node accepts a public API command.
2. The local VSR client routes the request to its believed primary.
3. The primary appends the operation and sends prepare messages to backups.
4. A quorum makes the operation committed.
5. Replicas apply committed operations in order to
   `Concord.StateMachine.Core`.
6. The client receives the deterministic state-machine result.

Client identifiers and monotonically increasing request numbers provide
duplicate suppression across retries and primary changes.

## Read path

Concord queries are submitted as replicated query barriers. This places each
read in the committed operation order and provides linearizable results. The
public `:eventual`, `:leader`, and `:strong` option names are retained for API
compatibility, but currently use the same VSR barrier.

## Persistence and recovery

File storage uses a checksummed write-ahead log plus an atomically replaced
checkpoint. Recovery truncates a partial or corrupt WAL tail to the last valid
record, restores the latest state-machine snapshot, and replays committed
operations after it. Snapshots compact the replicated prefix without changing
the logical Concord state.

## Failure model

VSR configurations tolerate failures while a majority remains available:

- one member tolerates no failure;
- three members tolerate one failure;
- five members tolerate two failures.

During a partition, only a quorum can continue committing operations. Nodes
that fall behind recover through state transfer or snapshot installation before
serving the current view.
