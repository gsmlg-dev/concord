# Research: Fix Review Issues

**Date**: 2026-03-03
**Branch**: `001-fix-review-issues`

## R1: `put_many` Index Update Gap

**Decision**: Add `update_indexes_on_put/4` calls inside `execute_put_many_batch`, passing the `data` map (which contains the `indexes` map).

**Rationale**: The single `:put` handler (line 177) calls `update_indexes_on_put(data, key, old_value, Compression.decompress(value))` after every insert. The batch handler `execute_put_many_batch` (lines 1254-1275) skips this entirely. The delete batch handler `execute_delete_many_batch` (lines 1290-1305) correctly calls `remove_from_all_indexes` — so the batch put path is the only gap.

**Alternatives considered**:
- Refactoring batch operations to call `apply_command(:put, ...)` per item — rejected because it would emit per-item telemetry and lose batch semantics.
- Adding a post-batch index rebuild — rejected because it's less efficient than incremental updates and would miss old-value removal.

**Implementation details**:
- `execute_put_many_batch/1` must become `execute_put_many_batch/2` accepting `data` map
- For each entry: look up old value via `get_decompressed_value(key)` before insert, then call `update_indexes_on_put(data, key, old_value, Compression.decompress(value))` after insert
- The caller at the `:put_many` command handler (lines ~390-422) must pass `data` to the batch function

## R2: Backup Consistency Fix

**Decision**: Rewrite `get_cluster_snapshot/0` to use the state returned by `:ra.consistent_query` directly, capturing all state categories (KV, auth, RBAC, tenants, indexes).

**Rationale**: The current implementation (backup.ex:272-287) calls `:ra.consistent_query` but **ignores the returned state** and reads from `:ets.tab2list(:concord_store)` instead. This misses auth tokens, RBAC roles/grants/ACLs, tenant definitions, and index metadata. The restore handler (state_machine.ex:723-746) also only processes `kv_entries`.

**Implementation details**:
- Backup creation: Use the full state map from `:ra.consistent_query` result
- Backup format: Change from `[{key, value}]` to `%{kv_data: [...], tokens: %{}, roles: %{}, role_grants: %{}, acls: [...], tenants: %{}, indexes: %{}}` — a versioned map
- Restore command: Change `{:restore_backup, kv_entries}` to `{:restore_backup, backup_state}` where `backup_state` is the full map
- Add backward compatibility: The restore handler should detect whether it receives a list (V1 format) or map (V2 format)
- Backup verification: Update `verify/1` to check all state categories

**Alternatives considered**:
- Reading all 6 ETS tables directly — rejected because ETS may be stale during leadership changes (the core bug)
- Adding a dedicated `:ra.process_command` for backup — rejected because `:ra.consistent_query` is the correct read-only pattern

## R3: Snapshot Recovery — Already Complete, Needs Tests

**Decision**: The V3 snapshot mechanism is already comprehensive. Focus on adding tests, not changing implementation.

**Rationale**: `build_release_cursor_state/1` (lines 979-1002) captures KV data, index definitions, index ETS data with `__snapshot_version__: 3`. `snapshot_installed/4` (lines 1008-1028) delegates to `rebuild_all_ets_from_snapshot/1` which rebuilds all 7 ETS tables: `:concord_store`, per-index tables, `:concord_tokens`, `:concord_roles`, `:concord_role_grants`, `:concord_acls`, `:concord_tenants`.

**Implementation**: Write snapshot round-trip tests that:
1. Populate all state categories
2. Call `build_release_cursor_state/1`
3. Call `snapshot_installed/4` with the captured state on a clean node
4. Assert all state categories restored correctly

## R4: Network Partition Tests

**Decision**: Rewrite partition tests to use process-level simulation instead of real Erlang node disconnection.

**Rationale**: The 4 skipped tests in `network_partition_test.exs` (lines 22-119) fail because the test runner node gets disconnected by Erlang's global registry during partition simulation. Real network partitions between Erlang nodes can't be reliably tested in CI because `Node.disconnect/1` and `Node.connect/1` interact with the global registry.

**Implementation**: Simulate partitions by:
- Intercepting Ra messages between nodes using `:erlang.trace` or process group manipulation
- Or using a proxy process that can drop/delay messages between Ra members
- Or testing at the state machine level: verify that minority partitions can't commit (Ra handles this internally)

**Alternatives considered**:
- Using Docker network partitions — rejected because it requires Docker-in-Docker in CI and is even more fragile
- Keeping tests skipped with documentation — rejected because partition safety is the most critical distributed property

## R5: `cleanup_expired` Optimization

**Decision**: Replace the N+1 lookup pattern with a single `:ets.select` that returns keys, values, and expiration data in one pass.

**Rationale**: Current implementation (lines 335-384) does 3 passes:
1. `:ets.select` to get all keys (line 339)
2. `:ets.lookup` per key to check expiration (line 343)
3. `get_decompressed_value` per expired key for index removal (line 358)

**Implementation**: Single `:ets.select` with match spec that extracts `{key, stored_data}` tuples, filter expired in Elixir, then delete+index-remove in one pass. For index removal, the stored data already contains the value — decompress inline.

## R6: ETS Table Access Control

**Decision**: Change ETS tables from `:public` to `:protected` where possible.

**Rationale**: All 6+ ETS tables are created with `:public` access. Since all legitimate writes go through Raft → state machine → ETS, and reads go through query functions in the owning process, `:protected` (read from any process, write only from owner) is sufficient.

**Caveat**: The state machine runs inside a Ra server process. ETS tables created by the state machine are owned by that process. If other processes (like the API layer) need to write directly to ETS (e.g., for auth fallback during bootstrap), those specific tables may need to remain `:public` or the fallback logic needs to route through the owning process.

**Implementation**: Audit each table creation site and determine if any non-owner writes exist outside of the state machine process.

## R7: Dependency Cleanup — `plug_cowboy`

**Decision**: Remove `plug_cowboy` from `mix.exs` dependencies.

**Rationale**: The project uses Bandit as the HTTP server (confirmed at `lib/concord/web/supervisor.ex:28-29`). Zero references to `Plug.Cowboy` exist in production code. The dependency is dead weight.

## R8: Documentation Gaps

**Decision**: Four documentation updates needed.

1. **Known Limitations section** in README.md — add after the "When to Use Concord" section. Document: bootstrap-window ETS fallback, node-local rate limiting, query TTL clock skew.

2. **Index extractor specs** in `docs/elixir-guide.md` — add a "Secondary Indexes" section documenting `{:map_get, key}`, `{:nested, keys}`, `{:identity}`, `{:element, n}` syntax with examples. Currently only documented in module `lib/concord/index.ex` source.

3. **Query consistency guide** — add to `docs/elixir-guide.md` clarifying which queries are linearizable (`:strong` consistency via `:ra.consistent_query`) vs. eventually consistent (`:eventual` via `:ra.local_query`).

4. **Performance claims** — remove specific throughput numbers from README.md (lines 82-90) that lack methodology. Replace with qualitative claims or add a link to `run_benchmarks.exs` for reproducibility.

## R9: Test Coverage and CI Enforcement

**Decision**: Raise threshold from 40% to 60% in `mix.exs` and add coverage check to `test.yml` CI workflow.

**Rationale**: The new snapshot, determinism, partition, and backup tests should significantly increase coverage. Adding `--cover` to the CI test step and the mix.exs threshold ensures regression.

**Implementation**:
- Update `mix.exs` line 66: `test_coverage: [summary: [threshold: 60]]`
- Update `.github/workflows/test.yml`: change `mix test` to `mix test --cover`
