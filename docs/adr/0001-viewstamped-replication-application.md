# ADR 0001: Standalone Viewstamped Replication application

- Status: Accepted
- Date: 2026-07-18

## Context

Concord currently uses `:ra` for replicated operation. Replacing that engine
before an alternative has independent safety, recovery, and fault-simulation
evidence would put Concord's existing behavior at risk.

The planned Viewstamped Replication (VSR) implementation must be reusable for
arbitrary deterministic state machines. Its safety logic must also be testable
without process scheduling, real clocks, distributed Erlang, or storage I/O.

VSR assumes a fixed configuration of `2f + 1` replicas and commits with a
quorum of `f + 1`. It handles crash failures, not Byzantine failures.

## Decision

Create an independent umbrella application named
`:viewstamped_replication`, with the Elixir namespace
`ViewstampedReplication`. It does not depend on `:concord`; Concord may depend
on it later.

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

The initial configuration sizes are one, three, and five replicas. The first
Concord production target is three replicas, tolerating one crash failure.

The application supervisor owns a registry and dynamic replica supervisors.
The public API starts and stops replicas, reports their status and primary,
creates client sessions, submits commands, and writes explicit snapshots.
`:ra` remains Concord's replication engine until the VSR implementation passes
its own safety, recovery, durability, and integration gates.

## Consequences

The protocol kernel can be exercised directly by unit tests, deterministic
simulation, and model/property tests. The same kernel can later run behind a
real OTP replica without duplicating protocol decisions.

The effect interpreter must preserve effect order. In particular, a runtime
using durable storage must persist protocol state before sending any
acknowledgement whose safety relies on that state.

The application now has a replica runtime, local and explicit distributed
transports, volatile and file-backed storage, recovery, state transfer,
snapshots, and explicit log compaction. It remains non-production-ready and
fixed-membership; the remaining limitations must stay visible in the
application README.

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
- the criteria and migration plan for replacing `:ra` in Concord.
