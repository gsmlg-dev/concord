# Quickstart: Fix Review Issues

**Branch**: `001-fix-review-issues`

## Prerequisites

- Elixir 1.18+ / OTP 28+
- Git checkout of `001-fix-review-issues` branch

## Verify Current State

```bash
# Run unit tests (should pass — baseline)
mix test

# Run with coverage to see current threshold
mix test --cover

# Run E2E tests
mix test.e2e
```

## Implementation Order

Work through these groups sequentially. Each group is independently testable.

### Group 1: P0 Bug Fixes (code changes)

1. **Fix `put_many` index updates** — `lib/concord/state_machine.ex`
2. **Fix backup consistency** — `lib/concord/backup.ex` + `lib/concord/state_machine.ex`
3. **Optimize `cleanup_expired`** — `lib/concord/state_machine.ex`

After each fix, run: `mix test`

### Group 2: Tests (new test files)

4. **Snapshot round-trip tests** — `test/concord/snapshot_test.exs`
5. **Determinism tests** — `test/concord/determinism_test.exs`
6. **Backup integration tests** — `test/concord/backup_test.exs`
7. **put_many + index tests** — update `test/concord/bulk_operations_test.exs`
8. **Network partition tests** — rewrite `e2e_test/distributed/network_partition_test.exs`

After all tests: `mix test --cover` (should exceed 60%)

### Group 3: Documentation

9. **Known Limitations** in README.md
10. **Index extractor specs** in `docs/elixir-guide.md`
11. **Query consistency guide** in `docs/elixir-guide.md`
12. **Performance claims** — remove or add methodology in README.md

### Group 4: Cleanup

13. Remove `plug_cowboy` from `mix.exs`
14. Change ETS access from `:public` to `:protected` where safe
15. Raise coverage threshold to 60% in `mix.exs`
16. Add `--cover` to CI test workflow

## Validation

```bash
# Full validation
mix test --cover    # Must pass with 60%+ coverage
mix lint            # Credo + Dialyzer must pass
mix test.e2e        # E2E including partition tests
```
