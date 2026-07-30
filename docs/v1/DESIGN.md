# Concord Architecture

## Overview

Concord is an embedded, strongly consistent key-value store for Elixir. Its
replicated runtime uses Viewstamped Replication (VSR) with one through six
ordered members. A strict majority quorum commits each operation, so a
minority partition cannot acknowledge writes.

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
duplicate suppression across retries and primary changes while a client
incarnation remains alive. By default, every client incarnation receives a
new cryptographically random identifier, so a restarted client cannot reuse a
persisted reply for its reset request counter.

This does not make a generic CRUD retry exactly-once across a client or VM
restart: the caller may still be uncertain whether a timed-out write committed.
Use `Concord.Txn.commit/2` with an `:idempotency_key`, followed by
`Concord.Txn.resolve/2` when needed, for restart-safe write retries while the
idempotency entry is retained. The replicated cache keeps at most 100,000
entries and evicts entries more than 10,000 revisions behind the current
revision. `resolve/2` returns `{:error, :not_found}` for an unknown or evicted
key; retrying an evicted key may execute the transaction again.

The VSR `:client_id` configuration is a logical base label, not the exact
protocol identity. Concord appends a fresh cryptographically random incarnation
token whenever the client process starts. This prevents a reset request counter
from matching replies cached for an earlier incarnation, including when an
application configures the base explicitly.

Replicated commands have an application-level envelope version. This release
reads both the legacy version-0 shape and the explicit version-1 shape, but
emits version 0 by default while readers are upgraded. New writers apply the
strict version-one schema even when they use the version-zero wire shape;
unknown commands and unsafe logical terms, including values hidden by
compression, are rejected before consensus. Version-zero replay retains the
frozen legacy semantics needed for historical logs and version-four snapshots.

Version-one replay also freezes its recursive safety walk and compression
decoder instead of consulting mutable API validation. Its logical limits are
500 bulk operations, 4,096-byte keys, 16 MiB values, 64 MiB aggregate commands,
64 transaction compares, 128 operations per transaction branch, 1,000,000-byte
transactions, and a 1,000-row transaction range limit. Both raw serialized size
and logical size after compression expansion must fit the value, transaction,
and aggregate caps. Operator settings can lower these limits at local admission
but cannot raise them or reinterpret committed bytes.

The compressed ETF decoder is designed for trusted, non-Byzantine embedded
callers. It bounds expanded bytes and rejects unsafe runtime-local terms, but
it is not an isolation boundary: decoding allocates terms and may intern atom
names before recursive validation. Untrusted protocols must translate a
bounded external schema rather than forwarding raw Erlang terms.

The version-0 to version-1 transition is an explicit state migration:

1. Upgrade every replica to a reader that supports version 1 while continuing
   to emit version 0.
2. Read `Concord.status/0`, record every exact value in
   `storage.legacy_indexes`, and drop each one by that exact name. Do not
   recreate it yet. A legacy index has either a non-declarative extractor or a
   name that is not a non-empty, valid UTF-8 binary of at most 255 bytes.
3. Pause writes, set `CONCORD_VSR_COMMAND_VERSION=1` on every node, and leave no
   old replica in the quorum before resuming operator commands. Normal
   version-one commands are blocked while the restored or version-zero state is
   marked legacy. Any missed exact legacy-index drops remain available.
4. Submit `Concord.Engine.command(:reconcile_legacy_state)` once. Continue only
   when status reports `storage.legacy_state_reconciliation_required == false`,
   `storage.legacy_state_representation == :current`, and a zero conflict
   count.
5. Recreate the dropped indexes with valid names, declarative extractors, and
   `reindex: true`. Calling `Concord.Index.reindex/2` immediately after a plain
   recreation is equivalent. Reindexing backfills records that predate the
   migration.

If version 1 starts with indexes still listed, normal writes fail with
`{:legacy_indexes_require_migration, names}`. Until step 4 completes, they fail
with `{:legacy_state_requires_reconciliation, status}`. The public status also
reports the active command version and configured `wal_version`. These are
manual compatibility gates; Concord does not negotiate application or storage
capabilities in the protocol.

## Read path

Concord queries use quorum-confirmed read barriers. The current primary
confirms its view with a quorum, then evaluates the query against its applied
state without appending the read to the replicated log. The public
`:eventual`, `:leader`, and `:strong` option names are retained for API
compatibility, but currently use the same linearizable VSR read path.

## Persistence and recovery

File storage uses a checksummed write-ahead log plus an atomically replaced
checkpoint. Version-two records checksum both their length header and payload,
so recovery truncates only an incomplete final version-two record, restores the
latest state-machine snapshot, and replays committed operations after it.
Complete corrupt records fail recovery without modifying the WAL. Complete
version-one records remain readable. Once the parser has seen the version-one
discriminator, an incomplete length, checksum, or payload fails closed because
the unchecked length cannot be distinguished safely from length-field
corruption. A tail ending in a partial magic prefix, or in the complete magic
without a version byte, is treated as an incomplete append and truncated.
Snapshots compact the replicated prefix without changing the logical Concord
state.

Storage version two is a gated, one-way deployment transition for both new WAL
records and rewritten checkpoints. New readers emit version one by default so
an application rollback cannot cause the old reader to discard version-two
data. After every deployment has left the old-reader rollback window,
operators may set `CONCORD_VSR_WAL_VERSION=2`. Once either a version-two WAL
record or checkpoint has been written, changing the setting back to 1 does not
downgrade existing data, and that directory must not be opened by an old
reader. Rollback then requires a separately verified version-one-compatible
backup; there is no automatic storage downgrade.

State transfer installs its snapshot and matching protocol state as one durable
operation. Custom storage adapters must implement
`ViewstampedReplication.Storage.install_snapshot_state/3` with the same
crash-atomic guarantee; a replica fails the transfer explicitly when the
adapter does not provide it.

## Failure model

VSR configurations tolerate failures while a majority remains available:

- one member tolerates no failure;
- two members tolerate no failure;
- three members tolerate one failure;
- four members tolerate one failure;
- five members tolerate two failures.
- six members tolerate two failures.

During a partition, only a quorum can continue committing operations. Nodes
that fall behind recover through state transfer or snapshot installation before
serving the current view.
