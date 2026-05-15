# Project Concord: Design Blueprint

## 1. Overview

Concord is a distributed, highly-available, and strongly-consistent Key-Value store built entirely in Elixir, leveraging the power of the Erlang OTP framework.

Its primary mission is to provide a simple, reliable, and fault-tolerant data storage solution for scenarios where data consistency and system uptime are more critical than raw performance. It is designed to survive node failures while guaranteeing that all clients see a consistent, linearizable view of the data.

## 2. Core Concepts

Concord is built upon three fundamental principles of distributed systems design.

### 2.1. Replicated State Machine

The core of Concord is a Replicated State Machine (RSM). This is a classic pattern for building fault-tolerant services. The idea is simple:

- We have a state machine (in our case, a Key-Value store)
- We run identical copies of this state machine on multiple nodes in a cluster
- We ensure that every state machine receives and applies the exact same sequence of commands (`put`, `delete`)
- If we can guarantee this, then all replicas will remain in sync, and the system can tolerate the failure of some replicas without losing data or consistency

### 2.2. Raft Consensus Algorithm

To guarantee that all state machines see the same command sequence, we need a consensus algorithm. Concord uses the Raft algorithm, implemented via the excellent and production-hardened `ra` library (by the RabbitMQ team).

The `ra` library is responsible for the most complex parts of the system:

- **Leader Election**: Automatically elects a single leader node responsible for coordinating writes. If the leader fails, a new one is elected within milliseconds.
- **Log Replication**: The leader receives commands from clients, appends them to its local log, and replicates them to a majority (a "quorum") of follower nodes.
- **Commit Safety**: A command is only considered "committed" and applied to the state machine after it has been safely replicated to the quorum. This ensures that committed data will survive node failures.

### 2.3. Consistency over Availability (CP)

According to the CAP Theorem, a distributed system must choose between Consistency and Availability in the face of a network Partition. Concord is a CP system.

- **Consistency**: All read operations will return the most recently completed write. There is no stale data.
- **Partition Tolerance**: The system is designed to function correctly even if the network splits the cluster into partitions.
- **Availability (The Trade-off)**: In the event of a network partition, only the partition containing a majority of nodes (the quorum) will remain available for writes. The minority partition will become unavailable to ensure data consistency is never violated. This is the correct and necessary trade-off for a system designed to store critical data like configuration or credentials.

## 3. Architecture & Components

The system is composed of several distinct Elixir components working in concert.

- **`Concord.Application` (The Supervisor)**: The OTP application entry point. Its primary role is to start and supervise the libcluster service and the ra cluster instance.

- **`Concord` (The API Module)**: The public client interface. It provides simple `put/2`, `get/1`, and `delete/1` functions. This module abstracts away the complexity of Raft, automatically forwarding requests to the current cluster leader.

- **`Concord.StateMachine` (The Heart)**: This module implements the `:ra_machine` behavior. It is the actual state machine.
  - It uses an in-memory ETS table for extremely fast reads and writes.
  - It is responsible for applying committed commands (`apply/3`) and answering queries (`query/3`).
  - It also handles creating snapshots of its state and restoring from them, which is critical for persistence.

- **The `ra` Library (The Engine)**: We delegate all consensus and persistence logic to `ra`. It runs as a supervised process that, in turn, manages our `Concord.StateMachine`. `ra` is responsible for all networking, leader election, and disk I/O for the Raft log and snapshots.

- **The `libcluster` Library (The Discovery Service)**: This library allows Concord nodes to automatically discover each other on the network using strategies like Gossip, freeing us from static configuration.

## 4. Data Flow

### 4.1. Write Operation (`Concord.put/2`)

1. A client calls `Concord.put("hello", "world")` on any node in the cluster.
2. The Concord API module calls `:ra.command/3` with the `{:put, "hello", "world"}` tuple.
3. If the current node is not the leader, `:ra` automatically forwards the command to the current leader.
4. The leader writes the command to its local, persistent Raft log.
5. The leader replicates the log entry to all follower nodes.
6. As soon as a majority of nodes (the quorum) confirm they have written the entry to their logs, the leader considers the command "committed".
7. The leader applies the command to its local `Concord.StateMachine` (by calling `apply/3`), which inserts the data into the ETS table.
8. The leader returns `:ok` to the client.
9. Followers will eventually apply the same command to their own state machines.

### 4.2. Read Operation (`Concord.get/1`)

1. A client calls `Concord.get("hello")` on any node.
2. The Concord API module calls `:ra.query/3`.
3. To guarantee linearizability (reading the absolute latest state), the query is forwarded to the leader.
4. The leader executes the query directly against its `Concord.StateMachine` (by calling `query/3`), which looks up the key in the ETS table.
5. The result is returned directly to the client. This process does not create a Raft log entry.

## 5. Persistence Strategy

Concord achieves durability through a two-pronged strategy managed entirely by the `ra` library.

- **Persistent Raft Log**: Every write command is first written to an append-only log file on disk on a majority of nodes before the operation is confirmed to the client. This log is the ultimate source of truth and guarantees that no committed writes are lost.

- **State Machine Snapshots**: To prevent the Raft log from growing infinitely and to speed up recovery for new or restarting nodes, `ra` periodically commands the StateMachine to create a snapshot. Our `snapshot/1` callback dumps the entire ETS table to a binary format, which `ra` then writes to a snapshot file on disk. When a node starts, it can restore its entire state from the latest snapshot and then replay only the Raft log entries that occurred after the snapshot was taken.

## 6. Next Steps (Phase 3)

While the core functionality is complete, several features are required for a production-ready system:

- **Observability**: Integrate with Elixir's Telemetry library to expose critical metrics (e.g., leader changes, commit latency, cluster size).
- **Operational Tools**: Create Mix tasks for cluster management (e.g., safely adding/removing nodes).
- **Security**: Implement an authentication and authorization layer to control access to the data.
- **API Enhancements**: Provide more granular error types to the client (e.g., `{:error, :timeout}`, `{:error, :no_leader_available}`).