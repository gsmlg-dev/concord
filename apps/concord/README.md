# Concord

[![Build Status](https://github.com/gsmlg-dev/concord/workflows/CI/badge.svg)](https://github.com/gsmlg-dev/concord/actions)
[![Hex.pm](https://img.shields.io/hexpm/v/concord.svg)](https://hex.pm/packages/concord)
[![Documentation](https://img.shields.io/badge/docs-latest-blue.svg)](https://hexdocs.pm/concord/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> A distributed, strongly-consistent embedded key-value store built in Elixir using Viewstamped Replication.

**Concord** is an **embedded database** for Elixir applications — think SQLite for distributed coordination. Starts with your application, no separate infrastructure needed. Strong consistency guarantees with ETS-backed read performance.

## Key Features

- **Strong Consistency** — Viewstamped Replication ensures all nodes agree on data
- **High Performance** — ETS-backed reads with microsecond-level latency
- **Embedded Design** — Starts with your app, no external infrastructure
- **Linearizable Reads** — Eventual, leader, and strong names use the same quorum-confirmed VSR barrier
- **TTL Support** — Automatic key expiration with time-to-live
- **Bulk Operations** — Efficient batch processing (up to 500 items)
- **Value Compression** — Automatic compression for large values
- **Conditional Updates** — Compare-and-swap for optimistic concurrency
- **Secondary Indexes** — Query by indexed fields
- **Backup/Restore** — Compressed backups with integrity verification
- **Telemetry** — Built-in telemetry events for observability hooks

## Installation

```elixir
def deps do
  [{:concord, "~> 3.0.0-beta"}]
end
```

## Quick Start

```elixir
# Store and retrieve data
Concord.put("user:1001", %{name: "Alice", role: "admin"})
{:ok, user} = Concord.get("user:1001")

# TTL (auto-expires after 1 hour)
Concord.put("session:abc", session_data, ttl: 3600)
{:ok, {data, remaining_ttl}} = Concord.get_with_ttl("session:abc")

# Bulk operations
Concord.put_many([{"k1", "v1"}, {"k2", "v2", 600}])
{:ok, results} = Concord.get_many(["k1", "k2"])

# Conditional update (compare-and-swap)
Concord.put_if("counter", 1, expected: 0)

# All accepted consistency names currently use a linearizable VSR query barrier
Concord.get("key", consistency: :eventual)
Concord.get("key", consistency: :leader)
Concord.get("key", consistency: :strong)
```

### Storage APIs

Concord's default API uses the VSR-backed cluster:

```elixir
Concord.put("cluster:key", "value")
Concord.Cluster.put("cluster:key", "value")
```

For data that must stay on only the current node, call the local API:

```elixir
Concord.Local.put("local:key", "value")
Concord.Local.KV.put("local:record", %{value: 1})
```

The local API uses the same Concord command/query semantics with separate
node-local ETS tables. It does not submit writes to VSR and does not replicate
data to cluster peers.

For durable node-local storage backed by Turso/libSQL, enable the Turso engine
and call `Concord.Turso`:

```elixir
Concord.Turso.put("turso:key", %{value: 1})
Concord.Turso.get("turso:key")
Concord.Turso.txn(%{
  compare: [{:exists, "turso:key", :==, true}],
  success: [{:put, "turso:key", %{value: 2}, %{}}],
  failure: []
})
```

`Concord.Turso` uses `ex_turso` and persists data to a local database file. It
does not submit writes to VSR and does not provide Concord cluster membership,
leases, watches, or secondary indexes. If `remote_url` and `auth_token` are
configured, `Concord.Turso.sync/1` triggers Turso Cloud sync.

Applications that only need the durable Turso KV engine can disable the Concord
VSR cluster runtime while still starting the Turso pool:

```elixir
config :concord,
  cluster_enabled: false,
  turso: [
    enabled: true,
    database: "./data/turso.db",
    pool_size: 1
  ]
```

For applications that need a regular Ecto SQL repository backed by
Turso/libSQL, use the optional Ecto adapter shipped by `ex_turso`:

```elixir
def deps do
  [
    {:concord, "~> 3.0.0-beta"},
    {:ex_turso, "~> 0.4"},
    {:ecto_sql, "~> 3.14"}
  ]
end

defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Turso
end

config :my_app, MyApp.Repo,
  database: "my_app.db",
  pool_size: 5
```

`Ecto.Adapters.Turso` is the supported equivalent when you need schema/query
semantics, migrations, constraints, indexes, transactions, and map/JSON fields.
Swap the adapter and connection options in the host application when using
PostgreSQL instead.

### Multi-Node Cluster

Every replica must use the same ordered membership list. Bootstrap is enabled
only for the first start of a new cluster; restart durable replicas with
`CONCORD_VSR_BOOTSTRAP=false`.

```bash
export CONCORD_VSR_MEMBERS=n1@127.0.0.1,n2@127.0.0.1,n3@127.0.0.1
export CONCORD_VSR_BOOTSTRAP=true

CONCORD_VSR_REPLICA_ID=n1@127.0.0.1 iex --name n1@127.0.0.1 --cookie concord -S mix
CONCORD_VSR_REPLICA_ID=n2@127.0.0.1 iex --name n2@127.0.0.1 --cookie concord -S mix
CONCORD_VSR_REPLICA_ID=n3@127.0.0.1 iex --name n3@127.0.0.1 --cookie concord -S mix
```

## Performance

Performance varies significantly depending on hardware, cluster size, and network topology. All accepted consistency names use the same VSR read path. Run `mix run benchmarks/run_benchmarks.exs` on your own hardware to get representative numbers.

## When to Use Concord

| Use Case | Fit |
|----------|-----|
| Feature Flags | Excellent |
| Session Storage | Excellent |
| Distributed Locks | Excellent |
| Config Management | Excellent |
| Rate Limiting | Good |
| API Response Cache | Great |
| Primary Database | Avoid (use PostgreSQL) |
| Large Blob Storage | Avoid (use S3) |

## Comparison

| Feature | Concord | etcd | Consul | ZooKeeper |
|---------|---------|------|--------|-----------|
| Language | Elixir | Go | Go | Java |
| Consistency | Strong (VSR) | Strong (Raft) | Strong (Raft) | Strong (Zab) |
| Storage | In-memory (ETS) | Disk (WAL) | Memory + Disk | Disk |
| Read Latency | 1-5ms | 5-20ms | 5-15ms | 5-20ms |
| Embedded | Yes | No | No | No |
| Multi-DC | No | Yes | Yes | Yes |

## Documentation

- **[Getting Started](../../docs/v1/getting-started.md)** — Installation, quick start, common use cases
- **[Elixir API Guide](../../docs/v1/elixir-guide.md)** — Read consistency aliases, CAS, queries, compression
- **[Backup & Restore](../../docs/v1/backup-restore.md)** — Data safety and disaster recovery
- **[Configuration](../../docs/v1/configuration.md)** — All configuration options
- **[Architecture](../../docs/v1/DESIGN.md)** — Design blueprint

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass (`mix test`)
5. Submit a pull request

## License

MIT License — See [LICENSE](LICENSE) for details.

## Acknowledgments

- The Viewstamped Replication and Viewstamped Replication Revisited papers
