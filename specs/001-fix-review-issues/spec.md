# Feature Specification: Fix Review Issues — Correctness, Tests, and Documentation

**Feature Branch**: `001-fix-review-issues`
**Created**: 2026-03-03
**Status**: Draft
**Input**: User description: "Fix correctness bugs, test gaps, and documentation issues identified in the project review (review.md)"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Batch Writes Maintain Index Consistency (Priority: P1)

A developer stores structured data (e.g., user records with email fields) using secondary indexes and writes records in bulk via `put_many`. After the batch write, the developer queries the secondary index and expects all written records to appear in the results.

**Why this priority**: This is a data correctness bug. Batch writes silently leave indexes stale, causing lookups to return incomplete results. Users cannot trust their query results, which is the most fundamental expectation of a data store.

**Independent Test**: Can be tested by writing records via `put_many` with an active secondary index and verifying that all records are returned by subsequent index lookups.

**Acceptance Scenarios**:

1. **Given** a secondary index exists on a field (e.g., `:email`), **When** a developer writes 100 records via `put_many`, **Then** all 100 records are discoverable via the secondary index lookup.
2. **Given** a secondary index exists and records already exist, **When** a developer overwrites existing records via `put_many` with changed indexed fields, **Then** the old index entries are removed and new entries reflect the updated values.
3. **Given** a secondary index exists, **When** a developer writes records via `put_many` where some records lack the indexed field, **Then** only records containing the indexed field appear in index lookups, and no errors are raised.

---

### User Story 2 - Backups Capture Consistent State (Priority: P1)

An operator creates a backup of a running Concord cluster for disaster recovery. The backup must reflect a consistent point-in-time snapshot of the authoritative state, even during concurrent writes or leadership changes.

**Why this priority**: Backups that capture stale or partial data can lead to silent data loss during restore. This undermines the core value proposition of a CP (consistent) data store.

**Independent Test**: Can be tested by creating a backup during active writes, restoring it to a fresh cluster, and verifying all data matches the state at backup time.

**Acceptance Scenarios**:

1. **Given** a cluster with 1,000 key-value pairs, **When** an operator creates a backup, **Then** the backup contains all 1,000 entries with correct values.
2. **Given** a cluster under active write load, **When** an operator creates a backup, **Then** the backup reflects a consistent snapshot — no partial writes or missing entries that existed before backup started.
3. **Given** a backup was created, **When** the operator restores it to a fresh cluster, **Then** all key-value pairs, secondary indexes, auth tokens, RBAC roles/grants/ACLs, and tenant definitions are fully restored.

---

### User Story 3 - Snapshot Recovery Preserves All State (Priority: P1)

After a node restart or new node joining the cluster, Raft snapshot recovery rebuilds the full application state. All data categories — KV pairs, indexes, authentication, authorization, and multi-tenancy — must survive the snapshot round-trip.

**Why this priority**: Snapshot recovery is the mechanism that enables node restarts and cluster scaling. If any state category is lost during recovery, the system silently degrades after routine operations.

**Independent Test**: Can be tested by creating a snapshot, restoring it on a fresh state machine, and verifying all state categories are intact.

**Acceptance Scenarios**:

1. **Given** a node with KV data, secondary indexes, auth tokens, RBAC roles, and tenant definitions, **When** the node restarts and recovers from a snapshot, **Then** all data categories are fully present and correct.
2. **Given** secondary indexes were defined before the snapshot, **When** the snapshot is restored, **Then** the index definitions and indexed data are both preserved — index lookups return correct results without re-indexing.
3. **Given** a three-node cluster, **When** a new node joins and catches up via snapshot transfer, **Then** the new node has identical state to the leader.

---

### User Story 4 - Documentation Accurately Reflects Capabilities (Priority: P2)

A developer evaluating Concord reads the documentation to understand its capabilities and limitations. The documentation should present an honest picture: known limitations, correct API usage for secondary indexes, consistency guarantees for queries, and meaningful performance claims.

**Why this priority**: Documentation that overpromises leads to production incidents when users rely on guarantees that don't hold. Accurate docs build trust and prevent misuse.

**Independent Test**: Can be tested by reviewing documentation against actual codebase behavior and verifying all claimed behaviors match implementation.

**Acceptance Scenarios**:

1. **Given** a developer reads the README, **When** they look for limitations, **Then** they find a "Known Limitations" section listing current correctness gaps, approximate rate limiting, and bootstrap-window caveats.
2. **Given** a developer wants to use secondary indexes, **When** they read the Elixir guide, **Then** they find documentation of extractor spec syntax (`{:map_get, key}`, `{:nested, keys}`, `{:identity}`, `{:element, n}`) with examples.
3. **Given** a developer uses the Query module, **When** they read the documentation, **Then** they understand which queries are linearizable (consistent) vs. eventually consistent (local).
4. **Given** a developer reads performance claims, **When** they look for methodology, **Then** they find hardware specs, cluster configuration, consistency level, and measurement method — or the unsubstantiated numbers have been removed.

---

### User Story 5 - Comprehensive Test Coverage for Distributed Scenarios (Priority: P2)

The test suite validates the most critical distributed systems properties: network partition tolerance, deterministic state machine replay, and snapshot recovery. Skipped or missing tests for these scenarios are addressed.

**Why this priority**: Untested distributed scenarios are the highest-risk area for a consensus-based data store. Network partitions and deterministic replay are the fundamental correctness properties of Raft.

**Independent Test**: Can be tested by running the full test suite and verifying partition tests execute, determinism tests pass, and coverage meets the target threshold.

**Acceptance Scenarios**:

1. **Given** the test suite, **When** a developer runs all tests, **Then** network partition tests execute (not skipped) and validate that the system maintains consistency during and after partition events.
2. **Given** two independent state machines, **When** the same command sequence is replayed on both, **Then** both produce identical final state — verifying deterministic replay.
3. **Given** the test suite, **When** coverage is measured, **Then** it meets or exceeds 60% line coverage.
4. **Given** the CI pipeline, **When** a PR is submitted, **Then** coverage is measured and the build fails if coverage drops below the threshold.

---

### User Story 6 - Clean Dependency Tree and Code Optimization (Priority: P3)

The project maintains a minimal dependency tree with no unused packages, and core operations are optimized for efficiency at scale.

**Why this priority**: Unused dependencies increase attack surface and confuse contributors. Suboptimal data operations become bottlenecks at scale.

**Independent Test**: Can be tested by verifying the dependency tree contains no unused packages and that expired-key cleanup operates efficiently on large datasets.

**Acceptance Scenarios**:

1. **Given** the project dependencies, **When** a developer inspects the dependency list, **Then** there are no unused HTTP server dependencies.
2. **Given** a store with 100,000 keys where 10% are expired, **When** cleanup runs, **Then** it completes in a single pass without redundant lookups.
3. **Given** data tables used for state, **When** a developer inspects table access modes, **Then** tables use the minimum required access level to prevent accidental consensus bypass.

---

### Edge Cases

- What happens when `put_many` is called with an empty list of entries? The operation should succeed as a no-op.
- What happens when a backup is created during a leadership transition? The operation should either complete with consistent data or return an error — never silently capture partial state.
- What happens when a snapshot is restored but the local tables already contain data? Old data should be fully cleared before restoring from the snapshot.
- What happens when `put_many` includes duplicate keys in the same batch? The last occurrence should win.
- What happens when an index extractor spec references a field that doesn't exist in a value? The record should be silently skipped for that index (no crash).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST update all secondary indexes when records are written via batch operations, matching the behavior of single-record writes.
- **FR-002**: System MUST create backups by reading from the authoritative consensus state, not from local materialized views that may be stale.
- **FR-003**: Snapshot recovery MUST restore all state categories: key-value pairs, secondary index definitions and data, auth tokens, RBAC roles/grants/ACLs, and tenant definitions.
- **FR-004**: README MUST include a "Known Limitations" section documenting: batch index update status, backup consistency model, bootstrap-window fallback behavior, and node-local rate limiting approximation.
- **FR-005**: User-facing Elixir guide MUST document secondary index extractor spec syntax with examples for each supported type.
- **FR-006**: Query module documentation MUST specify consistency guarantees for each query type.
- **FR-007**: Performance claims in documentation MUST include methodology (hardware, cluster size, consistency level, measurement tool) or be removed.
- **FR-008**: Network partition tests MUST execute (not be skipped) and validate that the system maintains consistency during and after partition events.
- **FR-009**: Test suite MUST include determinism verification tests that replay identical command sequences on independent state machines and assert identical output.
- **FR-010**: Test coverage threshold MUST be raised to at least 60%, with enforcement in CI.
- **FR-011**: Unused dependencies MUST be removed from the project.
- **FR-012**: Expired-key cleanup MUST operate in a single pass without redundant per-key lookups.
- **FR-013**: Data tables SHOULD use the minimum required access level to prevent accidental consensus bypass.

### Key Entities

- **Secondary Index**: A mapping from extractor spec to indexed values, maintained in sync with the KV store. Must be updated on all write paths (single and batch).
- **Backup**: A point-in-time capture of the full authoritative state, suitable for disaster recovery and cluster migration.
- **Snapshot**: An internal Raft mechanism that captures state for efficient log compaction and node recovery. Must include all state categories.
- **Extractor Spec**: A declarative tuple describing how to extract an index key from a value — avoids serialization issues with anonymous functions.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All records written via batch operations are discoverable through secondary index lookups immediately after the write completes — zero missing entries.
- **SC-002**: Backups created during concurrent writes contain a consistent, complete snapshot of all data — no partial state when restored.
- **SC-003**: After snapshot recovery, 100% of data across all state categories (KV, indexes, auth, RBAC, tenants) is present and correct.
- **SC-004**: Documentation includes a Known Limitations section, extractor spec reference, query consistency guide, and either performance methodology or cleaned-up claims.
- **SC-005**: Network partition tests and determinism tests execute successfully in the test suite with no skipped scenarios.
- **SC-006**: Test coverage meets or exceeds 60% with CI enforcement — builds fail if coverage drops below threshold.
- **SC-007**: Project has no unused dependencies in its dependency tree.
- **SC-008**: Expired-key cleanup handles stores with 100,000+ keys without performance degradation from redundant lookups.

## Assumptions

- The `plug_cowboy` dependency is indeed unused since Bandit is the configured HTTP server. This will be verified before removal.
- Network partition tests are skipped due to Erlang global registry interference, not fundamental design limitations. An alternative test approach (simulation or registry avoidance) can make them executable.
- The 60% coverage threshold is achievable with the addition of snapshot, determinism, and partition tests without requiring exhaustive unit test additions.
- Changing data table access from public to protected will not break any legitimate code paths, since all production writes route through Raft.
- The backup consistency fix can use consensus-based state reading without significant performance impact on the cluster.
