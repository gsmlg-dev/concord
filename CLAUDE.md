# CLAUDE.md

Repository guidance for contributors and coding agents.

## Project overview

Concord is an embedded, strongly consistent key-value database for Elixir.
Concord 3.0 uses the standalone `viewstamped_replication` umbrella application
as its only replicated runtime. `Concord.Local` and `Concord.Turso` remain
explicit node-local alternatives.

The repository is an umbrella with:

- `apps/concord` — public KV, MVCC, transaction, lease, index, Watch, backup,
  and engine APIs;
- `apps/viewstamped_replication` — VSR protocol, supervised runtime, transport,
  storage, snapshots, recovery, and telemetry;
- `apps/ex_turso` — optional node-local Turso/libSQL engine.

## Development commands

```bash
mix compile
MIX_ENV=test mix compile --warnings-as-errors
mix test
mix format --check-formatted
mix credo --strict
mix dialyzer
./e2e_test/scripts/run_e2e.sh
```

The Concord app defines `test: "test --no-start"`. Integration tests start an
isolated singleton VSR cluster with `Concord.TestHelper.start_test_cluster/0`.

## Replicated architecture

`Concord.Engine.VSR.Supervisor` starts:

1. a VSR replica with `Concord.Engine.VSR.StateMachine`;
2. a VSR client session;
3. `Concord.Engine.VSR`, the serialized Concord engine boundary.

Writes and queries are submitted through `Concord.Engine`. The default engine
is always `Concord.Engine.VSR`; there is no replication-engine configuration
switch. `Concord.Cluster.*` explicitly pins the same VSR engine.

All Concord reads currently use replicated query barriers. The public
`:eventual`, `:leader`, and `:strong` names are accepted for compatibility but
have the same linearizable behavior.

## Correctness invariants

1. `Concord.StateMachine.Core` is deterministic. Time used by commands comes
   from the replicated `Context.timestamp_ms`, never from local wall clock.
2. Replicated state and commands contain deterministic data. Prefer declarative
   index extractor specs over anonymous functions.
3. All replicated mutations go through `Concord.Engine.command/2`.
4. `Concord.StateMachine.Core.State` is authoritative. ETS tables are
   compatibility materialized views only.
5. VSR configuration membership is explicit, ordered, and identical on every
   replica. Supported sizes are one, three, and five.
6. `bootstrap: true` is only for fresh, empty multi-node storage. Durable
   restarts use `bootstrap: false`.
7. VSR client IDs and request numbers provide duplicate suppression. Do not
   bypass the client for public Concord operations.

## Adding a Concord feature

1. Validate and normalize input in the public API.
2. Add deterministic command/query behavior to
   `Concord.StateMachine.Core`.
3. Route through `Concord.Engine`; do not call VSR protocol processes from
   feature modules.
4. Add Core unit coverage and public API integration coverage through the VSR
   test helper.
5. Add release E2E coverage for distributed behavior or failure handling.

## Configuration

Runtime VSR configuration uses:

- `CONCORD_VSR_GROUP_ID`
- `CONCORD_VSR_REPLICA_ID`
- `CONCORD_VSR_MEMBERS`
- `CONCORD_VSR_TRANSPORT`
- `CONCORD_VSR_STORAGE`
- `CONCORD_VSR_STORAGE_PATH`
- `CONCORD_VSR_BOOTSTRAP`
- `CONCORD_VSR_RETRY_TIMEOUT`

When no member list is supplied, runtime configuration creates a singleton
using the current Erlang node. Multi-node deployments must supply the same
ordered `CONCORD_VSR_MEMBERS` list to every replica.

## Testing notes

- Protocol unit/property tests live under `apps/viewstamped_replication/test`.
- Concord integration tests are generally `async: false` because the VSR engine
  and compatibility ETS tables use registered names.
- Release E2E runs the full KV/MVCC/transaction/lease/engine suite, then a
  separate primary-failover test because that test intentionally stops a node.
- Keep historical 2.x Ra design records as history; current runtime and user
  documentation must describe VSR.

## Commit conventions

Use semantic prefixes such as `feat:`, `fix:`, `docs:`, `chore:`, `test:`, and
`refactor:`. Do not add generated-by or co-author trailers.
