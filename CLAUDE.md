# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Concord is a distributed, strongly-consistent **embedded** key-value store built in Elixir using the Raft consensus algorithm (Ra library). CP system — think SQLite for distributed coordination. Starts with your application, no separate infrastructure.

## Development Commands

```bash
mix compile                    # Build
mix test                       # Unit tests (uses --no-start alias)
mix test test/concord_test.exs # Single file
mix test test/concord_test.exs:42  # Single test by line
mix test --cover               # Coverage (threshold: 40%)
mix lint                       # Credo + Dialyzer
mix credo                      # Linter only (max line length: 120)
mix dialyzer                   # Type checking (first run is slow — builds PLT)

# E2E tests — separate MIX_ENV, spawns real Erlang nodes
mix test.e2e                   # All e2e tests
mix test.e2e.distributed       # Distributed subset only
MIX_ENV=e2e_test mix test e2e_test/distributed/leader_election_test.exs  # Specific

mix start                      # HTTP API server (dev)
```

## Architecture

### State Machine (V3) — The Core

`Concord.StateMachine` implements `:ra_machine`. This is the most critical file in the project.

**State shape:**
```elixir
{:concord_kv, %{
  indexes: %{name => extractor_spec},
  tokens: %{token => permissions},
  roles: %{role => permissions},
  role_grants: %{token => [roles]},
  acls: [{pattern, role, permissions}],
  tenants: %{tenant_id => tenant_definition},
  command_count: non_neg_integer()
}}
```

**Correctness invariants — do NOT violate these:**

1. **Deterministic replay**: `apply/3` is a pure function of `(meta, command, state)`. Time comes from `meta.system_time` (leader-assigned milliseconds), never `System.system_time`. The helper `meta_time(meta)` converts to seconds.

2. **No anonymous functions in Raft state/log**: Index extractors use declarative specs (`Concord.Index.Extractor`) — tuples like `{:map_get, :email}`, `{:nested, [:address, :city]}`, `{:identity}`, `{:element, n}`. Anonymous functions cause `:badfun` on deserialization across code versions.

3. **All mutations through Raft**: Auth tokens, RBAC roles/grants/ACLs, tenant definitions, and backup restores all route through `:ra.process_command` as state machine commands. Direct ETS writes are only acceptable as fallbacks when the cluster isn't ready yet (`:noproc`).

4. **ETS tables are materialized views**: Rebuilt from authoritative Raft state on `snapshot_installed/4`. Never the source of truth.

5. **Snapshots via `release_cursor` effect**: Ra does NOT have a `snapshot/1` callback. Snapshots are emitted every 1000 commands as `{:release_cursor, index, state}` effects. The state passed includes ETS data captured by `build_release_cursor_state/1`.

6. **Pre-consensus evaluation**: `put_if`/`delete_if` evaluate condition functions at the API layer, then convert to CAS commands with `expected: current_value` before entering the Raft log.

### Data Flow

**Writes**: `Concord.put/3` → Auth → `:ra.process_command({:concord_cluster, node()}, cmd, timeout)` → Leader replicates → `StateMachine.apply_command/3` → ETS insert + index update + telemetry

**Reads**: `Concord.get/2` → Auth → `:ra.consistent_query` or `:ra.local_query` → `StateMachine.query/2` → ETS lookup → decompress → return

**Key detail**: Ra wraps query results as `{:ok, {:ok, result}, leader_info}`. Always unwrap the nested tuple. Server ID format is `{:concord_cluster, node()}`.

### Module Responsibilities

| Module | Role |
|--------|------|
| `Concord` | Public API — all client-facing functions |
| `Concord.StateMachine` | Ra state machine — commands, queries, snapshots |
| `Concord.Application` | Supervisor tree — Ra cluster, HTTP, telemetry |
| `Concord.Auth` | Token auth — mutations via Raft commands |
| `Concord.RBAC` | Roles, grants, ACLs — mutations via Raft commands |
| `Concord.MultiTenancy` | Tenant definitions via Raft; usage counters node-local |
| `Concord.Index` | Secondary indexes using `Index.Extractor` specs |
| `Concord.Index.Extractor` | Declarative extractor specs (no closures) |
| `Concord.Backup` | Backup/restore — restore submits `{:restore_backup, entries}` via Raft |
| `Concord.TTL` | Key expiration — GenServer for periodic cleanup |
| `Concord.Web` | HTTP/HTTPS API (Plug + Bandit) |

### Adding a New Feature

1. **API layer** (`lib/concord.ex` or `lib/concord/feature.ex`): Validate inputs, call `:ra.process_command` for writes or `:ra.consistent_query` for reads. Handle nested Ra result tuples.

2. **State machine command** (`lib/concord/state_machine.ex`): Add `apply_command/3` clause. Return `{{:concord_kv, new_state}, result, effects}`. Use `meta_time(meta)` for timestamps. Emit telemetry.

3. **State machine query** (`lib/concord/state_machine.ex`): Add `query/2` clause. Return `{:ok, result}`. No state modification.

4. **Tests**: `test/concord/feature_test.exs`, `async: false`, use `Concord.TestHelper.start_test_cluster()` in setup, clean up ETS between tests.

## Testing Notes

- All tests use `async: false` — Ra cluster is shared state
- `--no-start` alias prevents auto-starting the application; tests call `start_test_cluster()` explicitly
- E2E tests use `MIX_ENV=e2e_test` with separate config (`config/e2e_test.exs`)
- When testing state machine directly, `apply/3` increments `command_count` on every call — don't assert exact state equality, pattern-match on the fields you care about

## Configuration

- `config/runtime.exs` — Data directory: prod uses `CONCORD_DATA_DIR` env var (default `/var/lib/concord/data/`), dev/test use `/tmp`
- `default_read_consistency`: `:eventual`, `:leader` (default), `:strong`
- Auth disabled in dev, enabled in prod
- HTTP API, Prometheus, and OpenTelemetry tracing are opt-in

## Commit Conventions

Semantic prefixes: `feat:`, `fix:`, `docs:`, `chore:`, `test:`, `refactor:`

Do NOT include "Generated with Claude Code" or "Co-Authored-By: Claude" in commits.

## Design Documentation

See `docs/` for architectural documents:
- `docs/ArchitecturalAudit.md` — Audit of correctness issues and their fixes
- `docs/CorrectRaftStateMachinePattern.md` — V3 migration design and rationale
- `docs/DESIGN.md` — Original design blueprint
- `docs/API_DESIGN.md` — HTTP API design
- `docs/API_USAGE_EXAMPLES.md` — HTTP API usage examples
