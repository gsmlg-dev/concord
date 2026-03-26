# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Concord is an **embedded key-value database** for Elixir with Raft consensus (Ra library). Think SQLite or CubDB, but with distributed replication.

- **Library, not a service** — no HTTP API, no auth, no RBAC, no multi-tenancy
- **In-memory with periodic flush** — ETS for reads, Ra log flushed to disk every ~1s (configurable in ms). Data since last flush can be lost on crash. This is by design.
- **Restore from source** — Concord stores data that doesn't change frequently. After a crash, data is restored from an authoritative external source (database, config, API). Crash durability of every write is explicitly not a goal.
- **CP system** — consistency over availability during partitions

## Development Commands

```bash
mix compile                    # Build
mix test                       # Unit tests (uses --no-start alias)
mix test test/concord_test.exs # Single file
mix test test/concord_test.exs:42  # Single test by line
mix test --cover               # Coverage (threshold: 50%)
mix lint                       # Credo + Dialyzer
mix credo                      # Linter only (max line length: 120)
mix dialyzer                   # Type checking (first run is slow — builds PLT)

# E2E tests — separate MIX_ENV, spawns real Erlang nodes
mix test.e2e                   # All e2e tests
mix test.e2e.distributed       # Distributed subset only
MIX_ENV=e2e_test mix test e2e_test/distributed/leader_election_test.exs  # Specific
```

## Architecture

### State Machine — The Core

`Concord.StateMachine` implements `:ra_machine`. Most critical file.

**State shape:**
```elixir
{:concord_kv, %{
  indexes: %{name => extractor_spec},
  command_count: non_neg_integer()
}}
```

**Correctness invariants — do NOT violate:**

1. **Deterministic replay**: `apply/3` is a pure function of `(meta, command, state)`. Time from `meta.system_time` (leader-assigned ms), never `System.system_time`. Helper: `meta_time(meta)`.

2. **No anonymous functions in Raft state/log**: Index extractors use declarative specs — `{:map_get, :email}`, `{:nested, [:a, :b]}`, `{:identity}`, `{:element, n}`. Closures cause `:badfun` on deserialization.

3. **All mutations through Raft**: `:ra.process_command` for every state change. Direct ETS writes only as fallback when cluster isn't ready (`:noproc`).

4. **ETS = materialized views**: Rebuilt from Raft state on `snapshot_installed/4`. Never source of truth.

5. **Snapshots via `release_cursor`**: Ra has no `snapshot/1` callback. Emit `{:release_cursor, index, state}` every N commands.

6. **Pre-consensus evaluation**: `put_if`/`delete_if` evaluate conditions at API layer, convert to CAS commands with `expected: current_value` before Raft log.

### Data Flow

**Writes**: `Concord.put/3` → Validation → `:ra.process_command({:concord_cluster, node()}, cmd, timeout)` → Leader replicates → `StateMachine.apply_command/3` → ETS insert + index update + telemetry

**Reads**: `Concord.get/2` → `:ra.consistent_query` or `:ra.local_query` → `StateMachine.query/2` → ETS lookup → decompress → return

**Key detail**: Ra wraps query results as `{:ok, {:ok, result}, leader_info}`. Always unwrap the nested tuple. Server ID format is `{:concord_cluster, node()}`.

### Module Responsibilities

| Module | Role |
|--------|------|
| `Concord` | Public API — put, get, delete, get_all, CAS, bulk ops |
| `Concord.StateMachine` | Ra state machine — commands, queries, snapshots |
| `Concord.Application` | Supervisor tree — Ra cluster, telemetry poller |
| `Concord.Index` | Secondary indexes using `Index.Extractor` specs |
| `Concord.Index.Extractor` | Declarative extractor specs (no closures) |
| `Concord.Backup` | Backup/restore — restore via `{:restore_backup, entries}` Raft command |
| `Concord.TTL` | Key expiration — GenServer for periodic cleanup |
| `Concord.Query` | Key filtering, range queries, value predicates |
| `Concord.Compression` | Transparent value compression for large values |
| `Concord.Telemetry` | Telemetry event definitions and helpers |

### Modules to Remove

These exist in the codebase but are out of scope for an embedded database:

- `Concord.Auth` — token authentication → host app concern
- `Concord.RBAC` — role-based access control → host app concern
- `Concord.MultiTenancy` — tenant isolation → host app concern
- `Concord.AuditLog` — compliance logging → host app concern
- `Concord.Web` — HTTP API → separate wrapper library
- `Concord.Tracing` — OpenTelemetry → host app via telemetry hooks
- `Concord.Prometheus` — metrics export → host app via telemetry hooks
- `Concord.EventStream` — CDC streaming → host app via telemetry hooks

### Adding a New Feature

1. **API layer** (`lib/concord.ex`): Validate inputs, call `:ra.process_command` for writes or `:ra.consistent_query` for reads. Handle nested Ra result tuples.

2. **State machine command** (`lib/concord/state_machine.ex`): Add `apply_command/3` clause. Return `{{:concord_kv, new_state}, result, effects}`. Use `meta_time(meta)` for timestamps. Emit telemetry.

3. **State machine query** (`lib/concord/state_machine.ex`): Add `query/2` clause. Return `{:ok, result}`. No state modification.

4. **Tests**: `test/concord/feature_test.exs`, `async: false`, use `Concord.TestHelper.start_test_cluster()` in setup, clean up ETS between tests.

## Testing Notes

- All tests `async: false` — Ra cluster is shared state
- `--no-start` alias prevents auto-starting; tests call `start_test_cluster()` explicitly
- E2E tests use `MIX_ENV=e2e_test` with separate config
- State machine `apply/3` increments `command_count` on every call — pattern-match fields you care about, don't assert exact state equality

## Configuration

- `config/runtime.exs` — Data dir: prod uses `CONCORD_DATA_DIR` env var, dev/test use `/tmp`
- `default_read_consistency`: `:eventual`, `:leader` (default), `:strong`
- `flush_interval_ms`: Ra log flush interval (default: 1000)

## Commit Conventions

Semantic prefixes: `feat:`, `fix:`, `docs:`, `chore:`, `test:`, `refactor:`

Do NOT include "Generated with Claude Code" or "Co-Authored-By: Claude" in commits.

## Design Documentation

See `docs/` for architectural documents:
- `docs/ArchitecturalAudit.md` — Audit of correctness issues and their fixes
- `docs/CorrectRaftStateMachinePattern.md` — V3 migration design and rationale
- `docs/DESIGN.md` — Original design blueprint

## Dependencies (target after cleanup)

- `ra` — Raft consensus
- `libcluster` — node discovery
- `telemetry` + `telemetry_poller` — event emission (no export deps)
- `jason` — JSON encoding for values

## Active Technologies
- Elixir 1.18 / OTP 28 + Ra 3.0 (Raft), libcluster 3.3+
- ETS (in-memory) with Ra snapshots for persistence