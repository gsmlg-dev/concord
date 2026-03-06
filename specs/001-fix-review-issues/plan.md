# Implementation Plan: Fix Review Issues

**Branch**: `001-fix-review-issues` | **Date**: 2026-03-03 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-fix-review-issues/spec.md`

## Summary

Fix 2 correctness bugs (batch index updates, backup consistency), add 4 missing test categories (snapshot, determinism, partition, backup), update 4 documentation areas (limitations, index specs, query consistency, performance claims), and clean up dependencies/code (remove `plug_cowboy`, optimize cleanup, tighten ETS access, raise coverage threshold).

## Technical Context

**Language/Version**: Elixir 1.18 / OTP 28
**Primary Dependencies**: Ra 2.17.1 (Raft), libcluster 3.5.0, Bandit 1.8.0, Plug 1.18.1
**Storage**: ETS (in-memory) with Ra snapshots for persistence
**Testing**: ExUnit (`mix test` for unit, `MIX_ENV=e2e_test mix test` for distributed)
**Target Platform**: Linux/macOS server (Erlang VM)
**Project Type**: Single Elixir library project
**Performance Goals**: <10us reads, <20ms writes, 600K+ ops/sec
**Constraints**: State machine must be deterministic; all mutations through Raft consensus
**Scale/Scope**: ~9,000 LOC across 32 modules, 29-file test suite

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Consistency First | PASS | Bug fixes strengthen consistency (backup reads from Raft, indexes updated on all paths) |
| II. Embedded by Design | PASS | No changes to embedded architecture |
| III. Performance Without Compromise | PASS | `cleanup_expired` optimization improves performance; backup change adds one Raft query |
| IV. Observability as Infrastructure | PASS | Existing telemetry preserved; no new operations without telemetry |
| V. Secure Defaults | PASS | ETS access tightening improves security posture |
| VI. Test-Driven Quality | PASS | Adding 4 missing test categories (snapshot, determinism, partition, backup) |
| VII. API Stability | PASS | No public API changes; backup format has backward compatibility |
| VIII. Deterministic State Machine | PASS | All fixes maintain deterministic replay; no closures in Raft log; mutations through Raft |

**Post-Phase 1 Re-check**: Constitution Principle VIII requires special attention for the backup format change — the `{:restore_backup, ...}` command handler must handle both V1 (list) and V2 (map) formats deterministically.

## Project Structure

### Documentation (this feature)

```text
specs/001-fix-review-issues/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0: research findings
├── data-model.md        # Phase 1: data model changes
├── quickstart.md        # Phase 1: implementation quickstart
├── contracts/           # Phase 1: API contract changes
│   └── backup-format-v2.md
├── checklists/
│   └── requirements.md  # Spec validation checklist
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (files to modify)

```text
lib/
├── concord/
│   ├── state_machine.ex    # Fix: put_many indexes, cleanup_expired optimization, restore_backup V2
│   ├── backup.ex           # Fix: read from Raft state, backup format V2
│   ├── auth.ex             # Change: ETS access (:public → keep :public for bootstrap)
│   ├── rbac.ex             # Change: ETS access (keep :public for bootstrap)
│   └── multi_tenancy.ex    # Change: ETS access (:public → :protected)
├── mix.exs                 # Change: remove plug_cowboy, raise coverage to 60%

test/
├── concord/
│   ├── snapshot_test.exs           # New: snapshot round-trip tests
│   ├── determinism_test.exs        # New: state machine determinism tests
│   ├── backup_test.exs             # New: backup/restore integration tests
│   └── bulk_operations_test.exs    # Update: add put_many + index tests

e2e_test/
└── distributed/
    └── network_partition_test.exs  # Rewrite: remove @tag :skip, use simulation

docs/
├── elixir-guide.md         # Add: index extractor specs, query consistency
README.md                   # Add: Known Limitations, fix performance claims

.github/workflows/
└── test.yml                # Add: --cover flag for CI coverage enforcement
```

**Structure Decision**: Existing Elixir project layout. No new directories needed — changes span existing source, test, docs, and CI files.

## Implementation Phases

### Phase A: P0 Bug Fixes (Stories 1-2)

These are the highest-priority correctness fixes. Each is independently testable.

**A1. Fix `put_many` index updates** (FR-001)
- File: `lib/concord/state_machine.ex`
- Change `execute_put_many_batch/1` → `execute_put_many_batch/2` (accept `data` map)
- Add per-entry: `old_value = get_decompressed_value(key)` before insert
- Add per-entry: `update_indexes_on_put(data, key, old_value, Compression.decompress(value))` after insert
- Update caller at `:put_many` handler to pass `data`
- Test: add test in `bulk_operations_test.exs` — put_many with active index, verify lookup

**A2. Fix backup consistency** (FR-002)
- File: `lib/concord/backup.ex`
- Rewrite `get_cluster_snapshot/0` to return full state from `:ra.consistent_query` result
- Change backup data format to V2 map (see `contracts/backup-format-v2.md`)
- File: `lib/concord/state_machine.ex`
- Update `{:restore_backup, ...}` handler to accept V2 map format
- Add backward compatibility for V1 list format
- Test: add `backup_test.exs` — create backup, restore, verify all state categories

### Phase B: Snapshot & Recovery Tests (Story 3)

**B1. Snapshot round-trip tests** (FR-003)
- New file: `test/concord/snapshot_test.exs`
- Populate all state categories (KV, indexes, auth, RBAC, tenants)
- Call `build_release_cursor_state/1`
- Call `snapshot_installed/4` on clean state
- Assert all 7 ETS tables contain correct data
- Test index lookups work after restore

### Phase C: Test Coverage Improvements (Story 5)

**C1. Determinism tests** (FR-009)
- New file: `test/concord/determinism_test.exs`
- Create two independent state machines (fresh state)
- Replay identical command sequence on both
- Assert final states are identical
- Include time-sensitive commands (TTL) to verify `meta_time` usage

**C2. Network partition tests** (FR-008)
- File: `e2e_test/distributed/network_partition_test.exs`
- Remove `@tag :skip` from all 4 tests
- Rewrite partition simulation to avoid Erlang global registry conflicts
- Options: message interception, Ra-level simulation, or isolated node groups

**C3. Coverage threshold + CI** (FR-010)
- File: `mix.exs` — change threshold from 40 to 60
- File: `.github/workflows/test.yml` — add `--cover` to test command

### Phase D: Documentation (Story 4)

**D1. Known Limitations** (FR-004)
- File: `README.md` — add section after "When to Use Concord"
- Document: bootstrap ETS fallback, node-local rate limiting, query TTL clock skew

**D2. Index extractor specs** (FR-005)
- File: `docs/elixir-guide.md` — add "Secondary Indexes" section
- Document all 4 spec types with examples: `{:map_get, key}`, `{:nested, keys}`, `{:identity}`, `{:element, n}`

**D3. Query consistency guide** (FR-006)
- File: `docs/elixir-guide.md` — add to existing "Read Consistency" section
- Clarify: `:strong` → `:ra.consistent_query`, `:leader` → `:ra.leader_query`, `:eventual` → `:ra.local_query`

**D4. Performance claims** (FR-007)
- File: `README.md` — remove specific throughput numbers or add methodology
- Decision: remove numbers, add link to `run_benchmarks.exs` for reproducibility

### Phase E: Cleanup (Story 6)

**E1. Remove `plug_cowboy`** (FR-011)
- File: `mix.exs` — remove `{:plug_cowboy, "~> 2.6"}` from deps
- Run `mix deps.unlock plug_cowboy && mix deps.get`

**E2. Optimize `cleanup_expired`** (FR-012)
- File: `lib/concord/state_machine.ex`
- Replace 3-pass pattern with single `:ets.select` returning `{key, stored_data}` tuples
- Filter expired in one pass, decompress inline for index removal

**E3. Tighten ETS access** (FR-013)
- Files: `state_machine.ex`, `multi_tenancy.ex`
- Change `:concord_store`, `:concord_tenants`, and dynamic index tables to `:protected`
- Keep `:concord_tokens`, `:concord_roles`, `:concord_role_grants`, `:concord_acls` as `:public` (bootstrap fallback needs cross-process writes)

## Dependency Graph

```
Phase A (bug fixes) → Phase B (snapshot tests, uses fixed backup)
Phase A → Phase C (coverage, needs bug fixes to pass)
Phase A, B, C → Phase E3 (ETS access, run all tests after)
Phase D (documentation) — independent, can run in parallel with B/C
Phase E1, E2 — independent, can run in parallel
```

## Complexity Tracking

No constitution violations. All changes align with existing principles.
