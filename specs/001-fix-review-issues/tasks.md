# Tasks: Fix Review Issues — Correctness, Tests, and Documentation

**Input**: Design documents from `/specs/001-fix-review-issues/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

**Tests**: Tests are integral to this feature — the spec explicitly requires snapshot, determinism, partition, and backup tests as core deliverables (US3, US5).

**Organization**: Tasks are grouped by user story. US1-US3 are P1 (correctness), US4-US5 are P2 (docs/tests), US6 is P3 (cleanup).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup

**Purpose**: Verify baseline state before making changes

- [x] T001 Run `mix test` and `mix test --cover` to establish baseline test pass rate and coverage percentage (313 tests, 0 failures, 50.61% coverage)

**Checkpoint**: All existing tests pass. Baseline coverage recorded for comparison.

---

## Phase 2: User Story 1 — Batch Writes Maintain Index Consistency (Priority: P1) MVP

**Goal**: Fix the bug where `put_many` skips secondary index updates, causing stale index lookups.

**Independent Test**: Write records via `put_many` with an active secondary index, then verify all records appear in index lookups.

### Implementation for User Story 1

- [x] T002 [US1] Fix `execute_put_many_batch/1` in `lib/concord/state_machine.ex` — change signature to `execute_put_many_batch/2` accepting `data` map; for each entry, call `get_decompressed_value(key)` before insert and `update_indexes_on_put(data, key, old_value, Compression.decompress(value))` after insert; update the `:put_many` command handler (~line 390-422) to pass `data` to the batch function
- [x] T003 [US1] Add put_many + index integration tests in `test/concord/bulk_operations_test.exs` — test: (1) put_many with active index verifies all entries appear in lookup, (2) put_many overwriting existing records updates index entries, (3) put_many with entries missing indexed field skips gracefully, (4) put_many with empty list is a no-op, (5) put_many with duplicate keys keeps last occurrence

**Checkpoint**: `mix test test/concord/bulk_operations_test.exs` passes. Index lookups return correct results after batch writes.

---

## Phase 3: User Story 2 — Backups Capture Consistent State (Priority: P1)

**Goal**: Fix backup creation to read from authoritative Raft state (not stale ETS), capture all state categories, and use a versioned V2 format with backward-compatible restore.

**Independent Test**: Create a backup with KV, auth, RBAC, and tenant data populated; restore to fresh cluster; verify all categories are present.

### Implementation for User Story 2

- [x] T004 [US2] Rewrite `get_cluster_snapshot/0` in `lib/concord/backup.ex` (~line 272-287) — use the full state map returned by `:ra.consistent_query` instead of `:ets.tab2list(:concord_store)`; extract all state categories (kv_data from `__kv_data__` or ETS within the query, plus tokens, roles, role_grants, acls, tenants, indexes from the state map); return V2 format `%{version: 2, kv_data: [...], tokens: %{}, roles: %{}, ...}`
- [x] T005 [P] [US2] Add V2 `{:restore_backup, backup_state}` command handler in `lib/concord/state_machine.ex` (~after line 746) — pattern match `when is_map(backup_state)` to distinguish from V1 list format; restore all state categories: clear and repopulate `:concord_store`, update `tokens`/`roles`/`role_grants`/`acls`/`tenants` in state map, rebuild all ETS tables and indexes; keep existing V1 handler `when is_list(kv_entries)` for backward compatibility
- [x] T006 [US2] Update backup metadata and verification in `lib/concord/backup.ex` — update `build_metadata/1` (~line 289-306) to include `state_categories: [:kv, :auth, :rbac, :tenants, :indexes]` and correct entry counts; update `verify/1` to validate V2 format structure
- [x] T007 [US2] Update backup restore fallback path in `lib/concord/backup.ex` (~line 336-369) — update `apply_backup/1` to pass V2 map to `:ra.process_command`; update the `:noproc` fallback to restore all state categories to their respective ETS tables (not just `:concord_store`)
- [x] T008 [US2] Create backup/restore integration test in `test/concord/backup_test.exs` — test: (1) backup captures all state categories (KV, tokens, roles, grants, ACLs, tenants, indexes), (2) restore from V2 format recovers all categories, (3) restore from V1 format (list) still works (backward compat), (4) backup during leadership transition returns error or consistent data (never partial)

**Checkpoint**: `mix test test/concord/backup_test.exs` passes. Backup/restore round-trip preserves all state categories.

---

## Phase 4: User Story 3 — Snapshot Recovery Preserves All State (Priority: P1)

**Goal**: Verify (via tests) that the V3 snapshot mechanism correctly preserves and restores all state categories. No code changes needed — implementation is already complete.

**Independent Test**: Build snapshot state, call `snapshot_installed/4`, verify all 7 ETS tables rebuilt correctly.

### Implementation for User Story 3

- [x] T009 [US3] Create snapshot round-trip tests in `test/concord/snapshot_test.exs` — populate all state categories: (1) KV entries in `:concord_store`, (2) secondary index definitions and ETS data, (3) auth tokens in state + `:concord_tokens`, (4) RBAC roles/grants/ACLs in state + respective ETS tables, (5) tenant definitions in state + `:concord_tenants`; call `build_release_cursor_state/1`; clear all ETS tables; call `snapshot_installed/4` with captured state; assert all 7 ETS tables contain correct data; verify index lookups work after restore

**Checkpoint**: `mix test test/concord/snapshot_test.exs` passes. All state categories survive snapshot round-trip.

---

## Phase 5: User Story 4 — Documentation Accurately Reflects Capabilities (Priority: P2)

**Goal**: Add honest documentation: Known Limitations section, index extractor spec reference, query consistency guide, and fix performance claims.

**Independent Test**: Review each documentation file against codebase behavior.

### Implementation for User Story 4

- [x] T010 [P] [US4] Add "Known Limitations" section to `README.md` after the "When to Use Concord" section — document: (1) auth/RBAC/tenant data written via ETS fallback during bootstrap window is not replicated until cluster forms, (2) multi-tenancy rate limiting is node-local (tenant can exceed quota by up to N× across N nodes), (3) query TTL checks use wall-clock time which may differ from leader-assigned time during clock drift
- [x] T011 [P] [US4] Add "Secondary Indexes" section to `docs/elixir-guide.md` — document all 4 extractor spec types with examples: `{:map_get, :email}` for flat map fields, `{:nested, [:address, :city]}` for nested paths, `{:identity}` for indexing the raw value, `{:element, 2}` for tuple element access; include create/drop/lookup API examples; warn against using anonymous functions (causes `:badfun` on deserialization)
- [x] T012 [P] [US4] Add query consistency documentation to `docs/elixir-guide.md` — extend the existing "Read Consistency Levels" section to explain: `:strong` uses `:ra.consistent_query` (linearizable, highest latency), `:leader` uses `:ra.leader_query` (leader-consistent, default), `:eventual` uses `:ra.local_query` (may return stale data, lowest latency); document which `Concord.Query` operations support consistency options
- [x] T013 [P] [US4] Fix performance claims in `README.md` (~lines 82-90) — either remove the specific throughput/latency table or add methodology section documenting: hardware specs, cluster size, consistency level used, measurement tool; add link to `run_benchmarks.exs` for users to reproduce benchmarks on their own hardware

**Checkpoint**: Documentation review confirms all 4 areas are addressed. No unsubstantiated claims remain.

---

## Phase 6: User Story 5 — Comprehensive Test Coverage (Priority: P2)

**Goal**: Add determinism and network partition tests; raise coverage threshold to 60% with CI enforcement.

**Independent Test**: `mix test --cover` meets 60%; no tests are skipped.

### Implementation for User Story 5

- [x] T014 [P] [US5] Create state machine determinism tests in `test/concord/determinism_test.exs` — create two independent state machines with identical initial state; replay the same command sequence (puts, deletes, TTL operations with explicit `meta.system_time`, index creates, auth token creates) on both; assert final states are identical field-by-field; include commands that use `meta_time(meta)` to verify time determinism
- [x] T015 [US5] Rewrite network partition tests in `e2e_test/distributed/network_partition_test.exs` — remove all `@tag :skip` tags from the 4 test cases (majority partition, minority partition, cluster recovery, split-brain prevention); rewrite partition simulation to avoid Erlang global registry conflicts (use process-level message interception, Ra-level isolation, or isolated node groups instead of `Node.disconnect/1`); ensure tests pass reliably in CI
- [x] T016 [P] [US5] Raise test coverage threshold from 40% to 60% in `mix.exs` (~line 66) — change `test_coverage: [summary: [threshold: 40]]` to `test_coverage: [summary: [threshold: 60]]`
- [x] T017 [P] [US5] Add coverage enforcement to CI in `.github/workflows/test.yml` — change `mix test` to `mix test --cover` so the CI build fails if coverage drops below the threshold defined in `mix.exs`

**Checkpoint**: `mix test --cover` passes with 60%+ coverage. `mix test.e2e` runs partition tests without skips.

---

## Phase 7: User Story 6 — Clean Dependency Tree and Code Optimization (Priority: P3)

**Goal**: Remove unused `plug_cowboy`, optimize expired-key cleanup, and tighten ETS access control.

**Independent Test**: `mix deps.tree` shows no `plug_cowboy`; cleanup benchmark shows single-pass; ETS tables use `:protected` where safe.

### Implementation for User Story 6

- [x] T018 [P] [US6] Remove `plug_cowboy` dependency from `mix.exs` (~line 120) — delete `{:plug_cowboy, "~> 2.6"}` from deps list; run `mix deps.unlock plug_cowboy && mix deps.clean plug_cowboy && mix deps.get`; verify `mix compile` succeeds with no warnings
- [x] T019 [US6] Optimize `cleanup_expired` in `lib/concord/state_machine.ex` (~lines 335-384) — replace the 3-pass N+1 pattern with a single `:ets.select` using a match spec that returns `{key, stored_data}` tuples; filter expired entries in one Elixir pass using `extract_value/1` and `expired?/2`; for each expired entry, decompress inline for `remove_from_all_indexes/3` then delete; result should be O(N) instead of O(3N)
- [x] T020 [US6] ~~Change ETS tables from `:public` to `:protected`~~ SKIPPED — not safe (backup fallback, snapshot_installed, and tests all write from non-owner processes) — in `lib/concord/state_machine.ex` change `:concord_store` and dynamic index tables (via `ensure_ets_table/1`) from `:public` to `:protected`; in `lib/concord/multi_tenancy.ex` (~line 328) change `:concord_tenants` from `:public` to `:protected`; keep `:concord_tokens`, `:concord_roles`, `:concord_role_grants`, `:concord_acls` as `:public` (bootstrap fallback requires cross-process writes)

**Checkpoint**: `mix test` passes. `mix deps.tree` confirms no plug_cowboy. ETS tables verified.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Final validation across all stories

- [x] T021 Run full test suite with `mix test --cover` and verify coverage meets 60% threshold
- [x] T022 Run `mix lint` (Credo strict + Dialyzer) and fix any violations introduced by changes
- [x] T023 Run E2E tests with `mix test.e2e` and verify network partition tests execute (not skipped)
- [x] T024 Run quickstart.md validation: `mix test --cover && mix lint && mix test.e2e`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **US1 (Phase 2)**: Depends on Setup — can start immediately after baseline verified
- **US2 (Phase 3)**: Depends on Setup — can start in parallel with US1 (different files except state_machine.ex T005)
- **US3 (Phase 4)**: Depends on US2 completion (backup fix may affect snapshot tests)
- **US4 (Phase 5)**: Independent — can run in parallel with any phase
- **US5 (Phase 6)**: Depends on US1 + US2 + US3 (new tests need bug fixes to pass; coverage depends on all new test files)
- **US6 (Phase 7)**: Partially independent (T018 anytime; T019 anytime; T020 after US1-US5 verified)
- **Polish (Phase 8)**: Depends on all previous phases

### User Story Dependencies

- **US1 (P1)**: No dependencies — first to implement
- **US2 (P1)**: No dependencies on US1 — can run in parallel (T005 touches state_machine.ex, coordinate with T002)
- **US3 (P1)**: Depends on US2 (backup format changes affect test expectations)
- **US4 (P2)**: No code dependencies — can run anytime
- **US5 (P2)**: Depends on US1-US3 (coverage requires all new tests + bug fixes)
- **US6 (P3)**: T018/T019 independent; T020 should run after all tests verified

### Within Each User Story

- Code fixes before tests (fix the bug, then prove it's fixed)
- Same-file tasks are sequential
- Different-file tasks marked [P] can run in parallel

### Parallel Opportunities

- **US1 + US2**: Can develop in parallel (mostly different files; T002 and T005 both touch state_machine.ex but different functions)
- **US4 tasks**: All 4 documentation tasks (T010-T013) can run in parallel — different files
- **US5 tasks**: T014 (determinism), T016 (mix.exs), T017 (CI yaml) can run in parallel — different files
- **US6 tasks**: T018 (deps) and T019 (cleanup) can run in parallel — different areas of codebase

---

## Parallel Example: User Story 4 (Documentation)

```bash
# Launch all documentation tasks in parallel (different files):
Task: "Add Known Limitations section to README.md"
Task: "Add Secondary Indexes documentation to docs/elixir-guide.md"
Task: "Add query consistency guide to docs/elixir-guide.md"
Task: "Fix performance claims in README.md"
```

## Parallel Example: US1 + US2 (Bug Fixes)

```bash
# These can run in parallel (different functions in state_machine.ex + separate files):
Task: "Fix execute_put_many_batch in lib/concord/state_machine.ex"       # US1
Task: "Rewrite get_cluster_snapshot in lib/concord/backup.ex"             # US2
Task: "Add V2 restore_backup handler in lib/concord/state_machine.ex"    # US2 (different function area)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (baseline)
2. Complete Phase 2: US1 — fix put_many index bug
3. **STOP and VALIDATE**: `mix test test/concord/bulk_operations_test.exs` passes
4. This alone fixes the highest-severity data correctness bug

### Incremental Delivery

1. US1 (put_many fix) → Test → Verify index correctness
2. US2 (backup fix) → Test → Verify backup captures all state
3. US3 (snapshot tests) → Test → Verify snapshot round-trip
4. US4 (documentation) → Review → Verify accuracy
5. US5 (coverage) → Test → Verify 60% threshold + CI
6. US6 (cleanup) → Test → Verify no regressions
7. Polish → Full validation suite

### Parallel Strategy

With parallel execution:
1. Start US1 + US2 simultaneously (Phase 2 + Phase 3)
2. Start US4 (docs) simultaneously — no code dependencies
3. After US1 + US2 complete: US3 (snapshot tests)
4. After US1-US3 complete: US5 (coverage + CI)
5. US6 (cleanup) anytime for T018/T019, after tests verified for T020
6. Polish phase last

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- State machine changes (T002, T005, T019, T020) must be coordinated if done in parallel — different function areas but same file
- Tests use `async: false` — Ra cluster is shared state
- All new test files need `Concord.TestHelper.start_test_cluster()` in setup
- Commit after each completed user story phase
