# ADR 0001: Standalone Viewstamped Replication application

- Status: Accepted
- Date: 2026-07-18
- Amended: 2026-07-21 for flexible cluster sizes

## Context

Concord used `:ra` for replicated operation. Replacing that engine before an
alternative had independent safety, recovery, and fault-simulation evidence
would have put Concord's existing behavior at risk.

The planned Viewstamped Replication (VSR) implementation must be reusable for
arbitrary deterministic state machines. Its safety logic must also be testable
without process scheduling, real clocks, distributed Erlang, or storage I/O.

VSR assumes a fixed configuration and commits with intersecting majority
quorums. It handles crash failures, not Byzantine failures. The classic
`2f + 1` configuration remains the most replica-efficient way to tolerate `f`
failures, while even-sized configurations support operational deployments that
cannot use an odd replica count.

## Decision

Create an independent umbrella application named
`:viewstamped_replication`, with the Elixir namespace
`ViewstampedReplication`. It does not depend on `:concord`; Concord depends on
it through an umbrella dependency.

Separate the implementation into two boundaries:

1. A pure protocol kernel transforms a state and an event into a new state and
   an ordered list of effects.
2. A supervised OTP runtime interprets those effects using configured transport,
   storage, timers, and a replicated state-machine implementation.

The pure protocol kernel must not send process messages, inspect cluster
connections, read clocks, create timers, access files, emit telemetry, or
invoke the replicated state machine.

Replica membership is explicit, ordered, and fixed. It is not derived from
`Node.list/0`. The primary is selected deterministically from the view number
and that ordered configuration.

Supported configuration sizes are one through six replicas. Every size uses a
strict majority quorum of `floor(n / 2) + 1`, tolerating
`floor((n - 1) / 2)` crash failures.

The application supervisor owns a registry and dynamic replica supervisors.
The public API starts and stops replicas, reports their status and primary,
creates client sessions, submits commands, and writes explicit snapshots.
The VSR implementation passed its safety, recovery, durability, and integration
gates. Concord 3.0 therefore uses VSR as its only replicated engine and no
longer depends on `:ra`.

## Consequences

The protocol kernel can be exercised directly by unit tests, deterministic
simulation, and model/property tests. The same kernel can later run behind a
real OTP replica without duplicating protocol decisions.

The effect interpreter must preserve effect order. In particular, a runtime
using durable storage must persist protocol state before sending any
acknowledgement whose safety relies on that state.

The application has a replica runtime, local and explicit distributed
transports, volatile and file-backed storage, recovery, state transfer,
snapshots, and explicit log compaction. Its supported Concord production
profiles are fixed, explicitly configured groups of one through six replicas.
Operational constraints remain visible in the application README.

Keeping VSR independent adds an application boundary and explicit integration
work, but avoids coupling protocol correctness to Concord's domain model or
configuration.

## Deferred decisions

- durable storage-format migration policy;
- automatic snapshot and log-compaction thresholds;
- production hardening of distributed transport;
- operational policy for recovery and state-transfer thresholds;
- a commit-observer interface for external notifications;
- membership reconfiguration;
- migration between incompatible VSR storage formats.

Concord 3.0 intentionally does not read or migrate Ra storage. Upgrades from
Concord 2.x start with a new VSR data directory; no Ra backup compatibility or
automated migration path is provided.
