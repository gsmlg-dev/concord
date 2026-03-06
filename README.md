# Concord

[![Build Status](https://github.com/gsmlg-dev/concord/workflows/CI/badge.svg)](https://github.com/gsmlg-dev/concord/actions)
[![Hex.pm](https://img.shields.io/hexpm/v/concord.svg)](https://hex.pm/packages/concord)
[![Documentation](https://img.shields.io/badge/docs-latest-blue.svg)](https://hexdocs.pm/concord/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> A distributed, strongly-consistent embedded key-value store built in Elixir using the Raft consensus algorithm.

**Concord** is an **embedded database** for Elixir applications — think SQLite for distributed coordination. Starts with your application, no separate infrastructure needed. Strong consistency guarantees with microsecond-level performance.

## Key Features

- **Strong Consistency** — Raft consensus ensures all nodes agree on data
- **High Performance** — ETS-backed reads with microsecond-level latency
- **Embedded Design** — Starts with your app, no external infrastructure
- **HTTP REST API** — Complete API with OpenAPI/Swagger documentation
- **Configurable Consistency** — Choose eventual, leader, or strong per operation
- **TTL Support** — Automatic key expiration with time-to-live
- **Bulk Operations** — Efficient batch processing (up to 500 items)
- **Value Compression** — Automatic compression for large values
- **Conditional Updates** — Compare-and-swap for optimistic concurrency
- **Secondary Indexes** — Query by indexed fields
- **Event Streaming** — Real-time change data capture (CDC) via GenStage
- **Observability** — Telemetry, Prometheus, OpenTelemetry tracing, audit logs
- **Token Auth + RBAC** — Role-based access control with ACL patterns
- **Multi-Tenancy** — Namespace isolation with quotas
- **Backup/Restore** — Compressed backups with integrity verification

## Installation

```elixir
def deps do
  [{:concord, "~> 0.1.0"}]
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

# Read consistency levels
Concord.get("key", consistency: :eventual)  # Fast, may be stale
Concord.get("key", consistency: :leader)    # Default, balanced
Concord.get("key", consistency: :strong)    # Linearizable
```

### HTTP API

```bash
curl http://localhost:4000/api/v1/health

curl -X PUT -H "Content-Type: application/json" \
  -d '{"value": "hello"}' \
  http://localhost:4000/api/v1/kv/greeting

curl http://localhost:4000/api/v1/kv/greeting
```

### Multi-Node Cluster

```bash
iex --name n1@127.0.0.1 --cookie concord -S mix  # Terminal 1
iex --name n2@127.0.0.1 --cookie concord -S mix  # Terminal 2
iex --name n3@127.0.0.1 --cookie concord -S mix  # Terminal 3
```

## Performance

Performance varies significantly depending on hardware, cluster size, network topology, and consistency level. ETS-backed reads are inherently fast, but actual throughput and latency depend on your deployment. Run `mix run benchmarks/run_benchmarks.exs` on your own hardware to get representative numbers.

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

## Known Limitations

- **Bootstrap ETS Fallback**: Auth, RBAC, and tenant data written via ETS fallback during the bootstrap window (before a Raft cluster forms) is not replicated. Once the cluster establishes quorum, subsequent writes go through Raft consensus normally.

- **Node-Local Rate Limiting**: Multi-tenancy rate limiting is tracked per-node. A tenant can exceed its configured quota by up to N× across N nodes in the cluster.

- **Query TTL Clock Sensitivity**: TTL expiration checks in queries use wall-clock time (`System.system_time`) which may differ from leader-assigned time (`meta.system_time`) during clock drift between nodes.

## Comparison

| Feature | Concord | etcd | Consul | ZooKeeper |
|---------|---------|------|--------|-----------|
| Language | Elixir | Go | Go | Java |
| Consistency | Strong (Raft) | Strong (Raft) | Strong (Raft) | Strong (Zab) |
| Storage | In-memory (ETS) | Disk (WAL) | Memory + Disk | Disk |
| Read Latency | 1-5ms | 5-20ms | 5-15ms | 5-20ms |
| Embedded | Yes | No | No | No |
| Built-in Auth | Tokens + RBAC | mTLS | ACLs | ACLs |
| Multi-DC | No | Yes | Yes | Yes |

## Documentation

- **[Getting Started](docs/getting-started.md)** — Installation, quick start, common use cases
- **[Elixir API Guide](docs/elixir-guide.md)** — Consistency levels, CAS, queries, compression
- **[HTTP API Reference](docs/API_DESIGN.md)** — REST endpoint specification
- **[HTTP API Examples](docs/API_USAGE_EXAMPLES.md)** — Curl examples
- **[Observability](docs/observability.md)** — Telemetry, Prometheus, tracing, audit logging, event streaming
- **[Backup & Restore](docs/backup-restore.md)** — Data safety and disaster recovery
- **[Configuration](docs/configuration.md)** — All configuration options
- **[Production Deployment](docs/deployment.md)** — Docker, Kubernetes, security, operations
- **[Architecture](docs/DESIGN.md)** — Design blueprint

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass (`mix test`)
5. Submit a pull request

## License

MIT License — See [LICENSE](LICENSE) for details.

## Acknowledgments

- [Ra](https://github.com/rabbitmq/ra) library by the RabbitMQ team
- [libcluster](https://github.com/bitwalker/libcluster) for cluster management
- The Raft paper by Ongaro & Ousterhout
