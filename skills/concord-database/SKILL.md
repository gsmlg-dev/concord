---
name: concord-database
description: >
  Guide for using or extending the Concord embedded, strongly consistent
  key-value database for Elixir. Use for Concord.put/get/delete, KV, Txn,
  Lease, Index, Watch, Backup, VSR configuration, distributed tests, or
  Concord.StateMachine.Core changes.
---

# Concord Database

Concord 3.0 uses Viewstamped Replication (VSR) as its only replicated runtime.
`Concord.Local` and `Concord.Turso` are explicit node-local alternatives.

## Correctness invariants

1. `Concord.StateMachine.Core` must be deterministic. Command time comes from
   `Context.timestamp_ms`.
2. Replicated commands/state must be serialization-safe. Use declarative index
   extractor specs instead of anonymous functions.
3. Submit mutations through `Concord.Engine.command/2`; query through
   `Concord.Engine.query/2`.
4. Core state is authoritative. ETS tables are compatibility materialized
   views.
5. Every VSR replica uses the same explicit, ordered membership list.
6. Use `bootstrap: true` only for fresh multi-node storage and `false` for
   durable restarts.

## Public API

```elixir
Concord.put(key, value, opts \\ [])
Concord.get(key, opts \\ [])
Concord.delete(key, opts \\ [])
Concord.put_many(operations, opts \\ [])
Concord.get_many(keys, opts \\ [])
Concord.delete_many(keys, opts \\ [])
Concord.put_if(key, value, expected: current_value)
Concord.delete_if(key, expected: current_value)
Concord.status()
Concord.members()

Concord.KV.put(key, value, opts \\ [])
Concord.KV.get(key, opts \\ [])
Concord.KV.history(key, opts \\ [])
Concord.KV.list(opts)

Concord.Txn.commit(spec, opts \\ [])
Concord.Lease.grant(ttl_seconds, opts \\ [])
Concord.Lease.keep_alive(lease_id, opts \\ [])
Concord.Lease.revoke(lease_id, opts \\ [])
```

All accepted read consistency names (`:eventual`, `:leader`, `:strong`) currently
use the same replicated VSR query barrier and are linearizable.

## Secondary indexes

```elixir
Concord.Index.create("by_email", {:map_get, :email})
Concord.Index.create("by_city", {:nested, [:address, :city]})
Concord.Index.lookup("by_email", "alice@example.com")
Concord.Index.reindex("by_email")
```

Supported declarative specs include `{:map_get, key}`,
`{:nested, path}`, `{:identity}`, and `{:element, index}`.

## Adding features

1. Validate input in the public API module.
2. Add deterministic behavior to `Concord.StateMachine.Core`.
3. Route through the `Concord.Engine` boundary.
4. Add Core tests plus public API tests using
   `Concord.TestHelper.start_test_cluster/0`.
5. Add release E2E coverage for distributed/failure semantics.

## VSR runtime configuration

```elixir
config :concord,
  vsr: [
    group_id: :concord_cluster,
    replica_id: :"n1@127.0.0.1",
    members: [
      %{id: :"n1@127.0.0.1", endpoint: :"n1@127.0.0.1"},
      %{id: :"n2@127.0.0.1", endpoint: :"n2@127.0.0.1"},
      %{id: :"n3@127.0.0.1", endpoint: :"n3@127.0.0.1"}
    ],
    transport: :distribution,
    storage: :file,
    storage_path: "/var/lib/concord/vsr/n1",
    bootstrap: false
  ]
```

## Detailed references

- [API Reference](references/api-reference.md)
- [State Machine Internals](references/state-machine.md)
- [HTTP API Reference](references/http-api.md)
