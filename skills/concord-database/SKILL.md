---
name: concord-database
description: >
  Guide for using the Concord distributed key-value store — an embedded Raft-based CP database
  for Elixir applications. Use when writing code that stores/retrieves data with Concord,
  adding features to Concord, writing tests for Concord operations, configuring Concord
  in an application, using the Concord HTTP API, or working with any Concord module
  (StateMachine, Auth, RBAC, Index, Backup, TTL, Query, EventStream, MultiTenancy).
  Triggers on: Concord.put, Concord.get, Concord.delete, :ra.process_command,
  :concord_cluster, StateMachine, Concord.Query, Concord.Index, Concord.Auth,
  Concord.RBAC, Concord.Backup, Concord.EventStream, Concord.TTL, Concord.MultiTenancy,
  mix concord, /api/v1/kv, embedded key-value store, Raft consensus database.
---

# Concord Database

Concord is an embedded, strongly-consistent distributed KV store for Elixir using Raft consensus (Ra library). CP system — starts with your application, no separate infrastructure.

## Correctness Invariants — NEVER Violate

1. **Deterministic replay**: `StateMachine.apply/3` must be pure function of `(meta, command, state)`. Use `meta.system_time` for time, NEVER `System.system_time`. Helper: `meta_time(meta)` converts ms to seconds.

2. **No anonymous functions in Raft state/log**: Index extractors use declarative specs — tuples like `{:map_get, :email}`, `{:nested, [:a, :b]}`, `{:identity}`, `{:element, n}`. Closures cause `:badfun` on deserialization.

3. **All mutations through Raft**: Auth tokens, RBAC, tenants, backups all route through `:ra.process_command`. Direct ETS writes only acceptable as fallback when cluster isn't ready (`:noproc`).

4. **ETS = materialized views**: Rebuilt from Raft state on `snapshot_installed/4`. Never the source of truth.

5. **Snapshots via `release_cursor`**: Ra has no `snapshot/1` callback. Emit `{:release_cursor, index, state}` every 1000 commands.

## Core API

```elixir
# Writes (go through Raft consensus)
Concord.put(key, value, opts \\ [])                    # => :ok | {:error, reason}
Concord.delete(key, opts \\ [])                        # => :ok | {:error, reason}
Concord.put_many([{key, value} | {key, value, ttl}], opts)
Concord.delete_many([keys], opts)
Concord.touch(key, ttl_seconds, opts)                  # extend TTL
Concord.touch_many([{key, ttl_seconds}], opts)

# Conditional writes (CAS)
Concord.put_if(key, value, expected: current_value)    # => :ok | {:error, :condition_failed}
Concord.put_if(key, value, condition: fn val -> ... end)
Concord.delete_if(key, expected: current_value)

# Reads (query Raft leader or followers)
Concord.get(key, opts \\ [])                           # => {:ok, value} | {:error, :not_found}
Concord.get_many([keys], opts)                         # => {:ok, %{key => result}}
Concord.get_all(opts \\ [])                            # => {:ok, %{key => value}}
Concord.get_with_ttl(key, opts)                        # => {:ok, {value, remaining_seconds}}
Concord.get_all_with_ttl(opts)
Concord.ttl(key, opts)                                 # => {:ok, seconds | nil}
Concord.exists?(key, opts)                             # => {:ok, boolean}
Concord.status(opts)                                   # => {:ok, %{cluster: ..., storage: ...}}
Concord.members()                                      # => {:ok, [member_ids]}
```

### Common Options

- `:timeout` — ms, default 5000
- `:token` — auth token (required when auth enabled)
- `:consistency` — `:eventual` | `:leader` (default) | `:strong`
- `:ttl` — seconds, key auto-expires
- `:compress` — override auto-compression (true/false)

### Read Consistency

- `:eventual` — fastest, reads from any node, may be stale
- `:leader` — default, reads from leader
- `:strong` — linearizable, leader + heartbeat verification

### Ra Result Unwrapping

Ra wraps results: `{:ok, {:ok, result}, leader_info}`. Always unwrap the nested tuple. Server ID: `{:concord_cluster, node()}`.

## Query Language

```elixir
Concord.Query.keys(prefix: "user:")
Concord.Query.keys(suffix: ":admin")
Concord.Query.keys(pattern: ~r/user:\d+/)
Concord.Query.keys(range: {"user:100", "user:200"})
Concord.Query.keys(prefix: "user:", limit: 50, offset: 100)
Concord.Query.where(prefix: "product:", filter: fn {_k, v} -> v.price > 100 end)
Concord.Query.count(prefix: "temp:")
Concord.Query.delete_where(prefix: "temp:")
```

## Secondary Indexes

Use declarative extractor specs (never closures):

```elixir
Concord.Index.create("by_email", {:map_get, :email})
Concord.Index.create("by_city", {:nested, [:address, :city]})
Concord.Index.lookup("by_email", "alice@example.com")  # => {:ok, ["user:1"]}
Concord.Index.list()
Concord.Index.drop("by_email")
```

Specs: `{:map_get, key}`, `{:nested, [path]}`, `{:identity}`, `{:element, n}`

## Adding Features to Concord

1. **API layer** (`lib/concord.ex`): Validate inputs, call `command/2` for writes or query functions for reads. Handle nested Ra tuples.

2. **State machine command** (`lib/concord/state_machine.ex`): Add `apply_command/3` clause. Return `{{:concord_kv, new_state}, result, effects}`. Use `meta_time(meta)` for timestamps.

3. **State machine query** (`lib/concord/state_machine.ex`): Add `query/2` clause. Return `{:ok, result}`. No state modification.

4. **Tests**: `test/concord/feature_test.exs`, `async: false`, call `Concord.TestHelper.start_test_cluster()` in setup.

### State Machine State Shape

```elixir
{:concord_kv, %{
  indexes: %{name => extractor_spec},
  tokens: %{token => permissions},
  roles: %{role => permissions},
  role_grants: %{token => [roles]},
  acls: [{pattern, role, permissions}],
  tenants: %{tenant_id => definition},
  command_count: non_neg_integer()
}}
```

## Testing Patterns

- All tests: `async: false` (Ra cluster is shared state)
- `--no-start` alias: tests call `start_test_cluster()` explicitly
- Don't assert exact state equality — `command_count` increments on every apply. Pattern-match on fields you care about.
- E2E: `MIX_ENV=e2e_test mix test e2e_test/distributed/`

## HTTP API

Public: `GET /api/v1/health`, `GET /api/v1/openapi.json`, `GET /api/docs`

Authenticated (`Authorization: Bearer <token>` or `X-API-Key: <token>`):

| Method | Path | Body |
|--------|------|------|
| PUT | `/api/v1/kv/:key` | `{"value": ..., "ttl": N}` |
| GET | `/api/v1/kv/:key` | — |
| DELETE | `/api/v1/kv/:key` | — |
| GET | `/api/v1/kv/:key/ttl` | — |
| POST | `/api/v1/kv/:key/touch` | `{"ttl": N}` |
| GET | `/api/v1/kv` | — (list all) |
| POST | `/api/v1/kv/bulk` | `{"items": [{key, value, ttl?}]}` |
| POST | `/api/v1/kv/bulk/get` | `{"keys": [...]}` |
| POST | `/api/v1/kv/bulk/delete` | `{"keys": [...]}` |
| POST | `/api/v1/kv/bulk/touch` | `{"items": [{key, ttl}]}` |
| GET | `/api/v1/status` | — |

## Configuration Essentials

```elixir
config :concord,
  auth_enabled: false,                    # true in prod
  default_read_consistency: :leader,      # :eventual | :leader | :strong
  max_batch_size: 500,
  compression: [enabled: true, algorithm: :zlib, threshold_bytes: 1024, level: 6],
  ttl: [enabled: true, cleanup_interval_seconds: 300],
  http: [enabled: false, port: 4000],
  prometheus_enabled: false,
  tracing_enabled: false,
  audit_log: [enabled: false],
  event_stream: [enabled: false, buffer_size: 10_000]
```

Runtime: prod uses `CONCORD_DATA_DIR` (default `/var/lib/concord/data/`), dev/test use `/tmp`.

## Detailed References

- [API Reference](references/api-reference.md) — Full function signatures, options, return types, auth/RBAC/multi-tenancy API
- [State Machine Internals](references/state-machine.md) — Command/query patterns, snapshot mechanics, extending the state machine
- [HTTP API Reference](references/http-api.md) — Full endpoint docs with request/response examples
