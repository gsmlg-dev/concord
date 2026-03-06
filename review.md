# Concord — Project Review

**Date:** 2026-03-02
**Version:** 0.1.0
**Scope:** Full codebase, architecture, tests, documentation

---

## Executive Summary

Concord is an embedded distributed key-value store built in Elixir on the Ra (Raft) library. It aims to be "SQLite for distributed coordination" — a CP system that ships with your application, requiring no external infrastructure.

The project is **architecturally ambitious and well-structured**, with a clear V3 state machine design that addresses many correctness concerns identified in an earlier audit. The codebase spans ~9,000 lines of Elixir across 32 modules, with a 29-file test suite and 4 distributed E2E tests. Documentation is extensive (~14 guides).

**Overall assessment: Strong foundation with real engineering depth, but not yet production-safe.** Several correctness bugs remain, test coverage has structural gaps, and the documentation overpromises relative to actual guarantees.

---

## Scorecard

| Dimension | Rating | Summary |
|-----------|--------|---------|
| **Architecture** | 8/10 | Clean Raft-first design, ETS as materialized views, declarative index specs |
| **Correctness** | 6/10 | V3 fixes major issues, but batch index bug + backup inconsistency remain |
| **Code Quality** | 7/10 | Consistent patterns, good error handling, some duplication |
| **Test Coverage** | 5/10 | Good breadth, but no snapshot/recovery tests, partition tests skipped |
| **Documentation** | 7/10 | Comprehensive breadth, but overpromises production readiness |
| **API Design** | 8/10 | Clean public API, proper consistency levels, good HTTP layer |
| **Observability** | 8/10 | Telemetry, Prometheus, OpenTelemetry, audit logs, event streaming |
| **Production Readiness** | 4/10 | Critical gaps in snapshot completeness, backup safety, known limitations |

---

## Architecture

### What Works Well

**Raft-first mutation path.** All state changes (KV, auth tokens, RBAC roles/grants/ACLs, tenant definitions, indexes, backup restore) route through `:ra.process_command`. The state machine (`StateMachine.apply_command/3`) is the single source of truth. ETS tables serve as read-optimized materialized views, rebuilt from Raft state on `snapshot_installed/4`.

**Deterministic time handling.** The `meta_time(meta)` helper extracts leader-assigned `meta.system_time` (milliseconds) and converts to seconds. All `apply_command/3` clauses use this instead of `System.system_time()`. This is the correct pattern for Raft determinism.

**Declarative index extractors.** Index specs are stored as tuples (`{:map_get, :email}`, `{:nested, [:address, :city]}`, `{:identity}`, `{:element, n}`) rather than anonymous functions. This avoids `:badfun` errors during cross-version deserialization — a real production concern with Erlang term storage.

**Pre-consensus condition evaluation.** `put_if`/`delete_if` evaluate predicate functions at the API layer, then convert to CAS commands with `expected: current_value` before entering the Raft log. This keeps closures out of the replicated log entirely.

**Supervisor tree structure.** Clean `:one_for_one` supervision with conditional children (HTTP, Prometheus, audit log, event streaming). Cluster initialization runs as an async task with retry logic.

### Structural Concerns

**ETS tables are `:public`.** All six core ETS tables (`:concord_store`, `:concord_tokens`, `:concord_roles`, `:concord_role_grants`, `:concord_acls`, `:concord_tenants`) plus dynamic index tables are created with `:public` access. Any process on the node can bypass Raft and write directly. While all production code paths route through Raft, this is a defense-in-depth gap — a misbehaving dependency or debug tool could silently corrupt state.

**Fallback direct ETS writes.** Auth, RBAC, and multi-tenancy modules fall back to direct ETS writes when `:ra.process_command` returns `:noproc` (cluster not ready). This is intentional for bootstrap scenarios, but creates a window where state is not replicated. If the node crashes before the cluster forms, these writes are lost.

**Node-local usage counters.** Multi-tenancy rate limiting tracks operation counts per-node in ETS, not through Raft. This means quota enforcement is approximate in a multi-node cluster — a tenant could exceed its quota by up to N× (where N is node count) before being throttled. This is a reasonable trade-off for performance, but should be documented.

---

## Correctness Issues

### Bug: `put_many` Skips Secondary Index Updates

**File:** `lib/concord/state_machine.ex:1254-1275`
**Severity:** High

`execute_put_many_batch/1` inserts KV pairs into ETS but does not call `update_indexes_on_put/4`. In contrast, `execute_delete_many_batch/2` correctly calls `remove_from_all_indexes/3` before deleting. Single `{:put, ...}` commands update indexes correctly (line 181).

This means any batch write via `Concord.put_many/2` silently leaves secondary indexes stale. Subsequent `Index.lookup/3` calls return incomplete results.

**Fix:** Add index update calls in `execute_put_many_batch`, mirroring the pattern in `apply_command` for single `:put`.

### Bug: Backup Creation Reads from ETS, Not Raft State

**File:** `lib/concord/backup.ex`
**Severity:** Medium

Backup creation reads data via `:ets.tab2list(:concord_store)` rather than extracting it from the Raft state machine query. During a leadership change or network partition, ETS may contain stale or partial data. The backup could capture an inconsistent snapshot.

**Fix:** Use `:ra.consistent_query` that returns the full state map, then serialize that — not the ETS table.

### Design Issue: Query Functions Use Wall-Clock Time for TTL

**File:** `lib/concord/state_machine.ex:803,821,844,862,885,911`
**Severity:** Low

All `query/2` clauses use `System.system_time(:second)` to check TTL expiry. Commands use `meta_time(meta)` (leader-assigned time). If the leader's clock drifts ahead of a follower serving a local query, the follower may return a value the leader considers expired.

This is acceptable for read-only queries (they don't modify state), but creates a subtle inconsistency window. Worth documenting.

### Design Issue: `cleanup_expired` Uses N+1 Pattern

**File:** `lib/concord/state_machine.ex:335-384`
**Severity:** Low (performance)

Expired key cleanup first calls `:ets.select` to get all keys, then does a second `:ets.lookup` per key to check expiry. For large stores this is O(2N). A single `:ets.select` with a match guard on `expires_at` would be O(N).

---

## Code Quality

### Strengths

- **Consistent error tuples:** All operations return `{:ok, result}` or `{:error, reason}` — no bare values or exceptions for control flow.
- **Telemetry instrumentation:** Every operation emits telemetry events with timing, operation type, and metadata. Good for debugging and monitoring.
- **Catch-all command handler:** Unknown commands are logged via telemetry and return `{:concord_kv, data}, :ok, []` — the state machine never crashes on unexpected input.
- **State migration:** `normalize_state/1` handles V1/V2 state formats, enabling rolling upgrades.
- **HTTP layer separation:** `Web.ApiController` is a thin adapter that delegates to `Concord.*` modules — no business logic in the HTTP layer.

### Concerns

- **Credo max line length at 120** is reasonable, but some functions in `state_machine.ex` have high cyclomatic complexity (25 command types in one module). Consider extracting command groups into submodules.
- **Duplication between `format_value/2` calls** in `execute_put_many_batch` and single `apply_command(:put, ...)`. The batch path doesn't share the index/compression logic of the single path.
- **`plug_cowboy` and `bandit` are both dependencies.** The project uses Bandit as the HTTP server but also depends on `plug_cowboy`. This is likely a leftover — consider removing `plug_cowboy` if unused.

---

## Test Suite

### Coverage at a Glance

| Area | Test File(s) | Status |
|------|-------------|--------|
| Core KV (put/get/delete) | `concord_test.exs` | Covered |
| Auth tokens | `auth_test.exs` | Covered |
| RBAC (roles, grants, ACLs) | `rbac_test.exs` | Covered |
| TTL/expiration | `ttl_test.exs`, `ttl_integration_test.exs` | Covered |
| Secondary indexes | `index_test.exs` | Covered |
| Multi-tenancy | `multi_tenancy_test.exs` | Covered |
| Conditional updates | `conditional_updates_test.exs` | Covered |
| Bulk operations | `bulk_operations_test.exs`, `bulk_operations_integration_test.exs` | Covered |
| Read consistency | `read_consistency_test.exs` | Covered |
| Query API | `query_test.exs` | Covered |
| HTTP API | `api_controller_test.exs`, `auth_plug_test.exs` | Covered |
| Observability | `telemetry_test.exs`, `tracing_test.exs`, `audit_log_test.exs`, `event_stream_test.exs` | Covered |
| E2E: Leader election | `leader_election_test.exs` | Covered |
| E2E: Data consistency | `data_consistency_test.exs` | Covered |
| E2E: Network partition | `network_partition_test.exs` | **Skipped** |
| E2E: Node failure | `node_failure_test.exs` | Partial (catch-up skipped) |

**Coverage threshold:** 40% (configured in mix.exs) — low for a data store.

### Critical Test Gaps

1. **No snapshot/recovery tests.** The `release_cursor` mechanism, `build_release_cursor_state/1`, and `snapshot_installed/4` are untested. If a snapshot is incomplete or misapplied, data loss is silent.

2. **No backup/restore integration tests.** The full backup-create-verify-restore cycle is not exercised in the test suite.

3. **Network partition tests are skipped.** All 5 partition scenarios in `network_partition_test.exs` are `@tag :skip` due to Erlang global registry interference. This is the most critical distributed systems test category.

4. **No determinism verification.** No test replays the same command sequence on two independent state machines and asserts identical output — the core correctness property of Raft.

5. **`put_many` + indexes not tested together.** The index update gap in batch operations has no corresponding test that would catch it.

6. **40% coverage threshold is very low** for a data storage system. Consider raising to 70%+ and adding property-based tests for the state machine.

---

## Documentation

### Well Done

- **README.md** is cleanly organized with links to focused guides.
- **`docs/getting-started.md`** gets users from zero to running in minutes.
- **`docs/elixir-guide.md`** covers the full Elixir API with examples.
- **`docs/API_DESIGN.md`** and **`docs/API_USAGE_EXAMPLES.md`** provide comprehensive HTTP API documentation with curl examples in multiple languages.
- **`docs/observability.md`** covers telemetry, Prometheus, OpenTelemetry, audit logs, and event streaming.
- **`docs/deployment.md`** includes Docker Compose, Kubernetes StatefulSet, and production hardening guidance.
- **`docs/ArchitecturalAudit.md`** and **`docs/CorrectRaftStateMachinePattern.md`** are excellent engineering documents.

### Issues

**No "Known Limitations" section.** The README and deployment guide present Concord as production-ready without disclaimers about:
- Auth/RBAC/tenants lost if node restarts before cluster forms (fallback ETS writes)
- Secondary index definitions in snapshots (verify this is now correct in V3)
- Batch operations skipping index updates
- Node-local rate limiting (not cluster-wide)

**Performance benchmarks lack methodology.** The README claims "621K-870K ops/sec" without specifying hardware, cluster size, consistency level, or measurement method. The range "943K-25M ops/sec" for TTL operations spans 26× — too wide to be meaningful.

**Secondary index extractor specs are undocumented** in user-facing guides. The `{:map_get, key}` / `{:nested, keys}` / `{:identity}` / `{:element, n}` syntax is only documented in CLAUDE.md and code comments. Users will try to pass anonymous functions and hit `:badfun` errors in production.

**`Concord.Query` module exists but is under-documented.** The module is real (verified at `lib/concord/query.ex`), but the guides show usage examples without specifying which operations go through Raft and which are local ETS scans.

---

## Dependency Analysis

| Category | Dependencies | Notes |
|----------|-------------|-------|
| **Core** | `ra` 2.17.1, `libcluster` 3.5.0 | Solid, well-maintained |
| **HTTP** | `bandit` 1.8.0, `plug` 1.18.1 | Modern choice over Cowboy |
| **Observability** | `telemetry` + `prometheus` + `opentelemetry` (7 packages) | Comprehensive but heavy |
| **Events** | `gen_stage` 1.3.2 | Appropriate for CDC |
| **JSON** | `jason` 1.4.4 | Standard |
| **Dev** | `credo`, `dialyxir`, `ex_doc` | Standard tooling |
| **Possibly unused** | `plug_cowboy` 2.7.4 | Project uses Bandit, not Cowboy directly |

The dependency tree is reasonable. The observability stack (7 packages) is the largest group — consider making OpenTelemetry optional at the dependency level rather than just configuration.

---

## CI/CD

Four GitHub Actions workflows provide good coverage:

- **`test.yml`** — Unit tests on push/PR (Elixir 1.18, OTP 28)
- **`ci.yml`** — Compile warnings, format check, Credo strict, Dialyzer
- **`e2e-test.yml`** — Distributed tests on push/PR + nightly at 2 AM UTC
- **`release.yml`** — Tag-triggered publish to Hex.pm with GitHub Release

The CI pipeline catches compilation warnings (treated as errors), style violations, and type errors. E2E tests run nightly even without code changes, which is good for catching intermittent distributed issues.

**Gap:** No CI job runs `mix test --cover` and fails if coverage drops below threshold. The 40% threshold is only enforced locally.

---

## Recommendations

### P0 — Fix Before Any Production Use

1. **Fix `put_many` index updates.** Add `update_indexes_on_put` calls in `execute_put_many_batch` for each operation.
2. **Fix backup creation** to read from Raft state (consistent query result), not raw ETS.
3. **Add snapshot round-trip tests** — create snapshot, restore on fresh node, verify all state (KV, indexes, auth, RBAC, tenants).
4. **Add a "Known Limitations" section** to README.md listing current correctness gaps.

### P1 — Improve Before Wider Adoption

5. **Re-enable network partition tests** or replace with a simulation that avoids Erlang global registry conflicts.
6. **Document secondary index extractor specs** in the user-facing Elixir guide.
7. **Raise test coverage threshold** to at least 60% and add coverage enforcement to CI.
8. **Add determinism tests** — replay identical command sequences on two state machines, assert identical state.
9. **Remove `plug_cowboy`** if only Bandit is used as the HTTP server.

### P2 — Polish

10. **Optimize `cleanup_expired`** — single `:ets.select` with match guard.
11. **Document Query module** consistency guarantees (which queries are linearizable vs. eventual).
12. **Add performance benchmark methodology** to README or remove the numbers.
13. **Consider `:protected` ETS tables** instead of `:public` to prevent accidental consensus bypass.

---

## Conclusion

Concord demonstrates solid engineering thinking — the V3 state machine design correctly addresses the hardest problems in distributed consensus (deterministic replay, serialization safety, snapshot completeness). The codebase is well-organized, consistently patterned, and thoroughly instrumented for observability.

The main risks are in the gaps between ambition and verification: the `put_many` index bug shows that batch operations weren't tested with indexes enabled; the skipped partition tests mean the most critical distributed scenario is unverified; and the documentation presents a more polished picture than the current implementation delivers.

With the P0 fixes applied and test coverage expanded, Concord would be a credible embedded distributed KV store for Elixir applications — filling a real gap in the ecosystem.
