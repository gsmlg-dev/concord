# Configuration

Complete reference for all Concord configuration options.

## Base Configuration (config/config.exs)

```elixir
config :concord,
  cluster_name: :concord_cluster,
  data_dir: "./data",
  auth_enabled: false,
  max_batch_size: 500,
  default_read_consistency: :leader,  # :eventual, :leader, or :strong

  ttl: [
    default_seconds: 86_400,
    cleanup_interval_seconds: 300,
    enabled: true
  ],

  compression: [
    enabled: true,
    algorithm: :zlib,          # :zlib or :gzip
    threshold_bytes: 1024,
    level: 6                   # 0-9
  ],

  http: [
    enabled: false,
    port: 4000,
    ip: {127, 0, 0, 1}
  ],

  tls: [
    enabled: false,
    certfile: nil,
    keyfile: nil,
    cacertfile: nil,
    versions: [:"tlsv1.2", :"tlsv1.3"]
  ],

  prometheus_enabled: false,
  prometheus_port: 9568,

  tracing_enabled: false,
  tracing_exporter: :stdout,   # :stdout, :otlp, or :none

  audit_log: [
    enabled: false,
    log_dir: "./audit_logs",
    rotation_size_mb: 100,
    retention_days: 90,
    log_reads: false,
    sensitive_keys: false
  ],

  event_stream: [
    enabled: false,
    buffer_size: 10_000
  ]
```

## Storage APIs

Storage/concurrency selection is API-based, not global configuration-based.

| API | Behavior |
|-----|----------|
| `Concord` / `Concord.Cluster` | Default Raft-backed cluster API. Writes go through Raft quorum replication. |
| `Concord.Local` | Node-local KV API. Data stays on the current BEAM node and is not written to the Raft cluster. |
| `Concord.Turso` | Durable node-local KV API backed by `ex_turso`. Data is written to a local Turso database file and is not written to the Raft cluster. |

Canonical sub-APIs follow the same split: `Concord.KV` and
`Concord.Cluster.KV` use the cluster engine, while `Concord.Local.KV` uses the
local engine. Pass `engine: :turso` to canonical APIs when using Turso-specific
calls such as `Concord.KV.history/2` or `Concord.Txn.commit/2`.

### Turso

Turso support is disabled by default:

```elixir
config :concord,
  turso: [
    enabled: true,
    database: "./data/turso.db",
    pool_size: 1
  ]
```

Runtime releases can use environment variables:

```bash
CONCORD_TURSO_ENABLED=true
CONCORD_TURSO_DATABASE=/var/lib/concord/turso.db
CONCORD_TURSO_POOL_SIZE=1
CONCORD_TURSO_REMOTE_URL=libsql://example.turso.io
CONCORD_TURSO_AUTH_TOKEN=...
```

`Concord.Turso.sync/1` is available only when both remote URL and auth token are
configured. Turso does not provide Concord Raft semantics, leases, watches, or
secondary indexes; those operations return explicit unsupported-operation
errors.

### Ecto SQL adapter

`Concord.Turso` is a Concord KV API. Applications that need normal Ecto schema,
query, migration, transaction, constraint/index, and map/JSON-field semantics
should configure an Ecto repo with the optional adapter provided by `ex_turso`:

```elixir
def deps do
  [
    {:concord, "~> 2.3"},
    {:ex_turso, "~> 0.2.0"},
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

`Ecto.Adapters.Turso` is the supported Turso/libSQL Ecto adapter name. It is the
documented equivalent for applications that might otherwise look for an
`Ecto.Adapters.Concord` module.

Use a normal PostgreSQL adapter and connection configuration in the host
application when PostgreSQL is selected instead.

## Development (config/dev.exs)

```elixir
config :concord,
  data_dir: "./data/dev",
  auth_enabled: false,
  http: [enabled: true, port: 4000, ip: {127, 0, 0, 1}]

config :logger, level: :debug
```

## Test (config/test.exs)

```elixir
config :concord,
  data_dir: "./data/test",
  auth_enabled: false,
  http: [enabled: false]

config :logger, level: :warning
```

## Production (config/prod.exs)

```elixir
config :concord,
  data_dir: {:system, "CONCORD_DATA_DIR", "/var/lib/concord"},
  auth_enabled: true,
  http: [
    enabled: {:system, "CONCORD_HTTP_ENABLED", true},
    port: {:system, "CONCORD_API_PORT", 8080},
    ip: {:system, "CONCORD_API_IP", {0, 0, 0, 0}}
  ]

config :logger, level: :info
```

## Runtime Configuration (config/runtime.exs)

The data directory is resolved at runtime:

```elixir
node_name = System.get_env("NODE_NAME", "node")

data_dir =
  case config_env() do
    :prod ->
      System.get_env("CONCORD_DATA_DIR", "/var/lib/concord/data/#{node_name}")
    _dev_or_test ->
      Path.join(System.tmp_dir!(), "concord_data/#{node_name}")
  end
```

**Important:** In dev/test, data is stored in `/tmp` and will be lost on reboot. In production, set `CONCORD_DATA_DIR` to a persistent location.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CONCORD_DATA_DIR` | `/var/lib/concord/data` | Persistent data directory (prod) |
| `CONCORD_API_PORT` | `8080` | HTTP API port (prod) |
| `CONCORD_API_IP` | `0.0.0.0` | HTTP API bind address (prod) |
| `CONCORD_HTTP_ENABLED` | `true` | Enable HTTP API (prod) |
| `CONCORD_AUTH_ENABLED` | `true` | Enable authentication (prod) |
| `CONCORD_COOKIE` | — | Erlang cookie for cluster |
| `NODE_NAME` | `node` | Node name for data directory |

## E2E Test (config/e2e_test.exs)

```elixir
config :concord,
  cluster_name: :concord_cluster,
  data_dir: "./data/e2e_test",
  auth_enabled: false

config :libcluster,
  topologies: [
    concord: [strategy: Cluster.Strategy.Gossip]
  ]

config :concord, :http, enabled: true, port: 4000
```

## Key Configuration Decisions

### Read Consistency

- `:eventual` — Fastest, reads from any node, may be stale
- `:leader` — Default, reads from leader, minimal staleness
- `:strong` — Slowest, linearizable, zero staleness

### Authentication

Disabled in dev for convenience. Always enable in production:

```elixir
config :concord, auth_enabled: true
```

### Compression

Enabled by default with sensible defaults. Tune for your workload:

- **High-throughput small values:** Increase `threshold_bytes` or disable
- **Large JSON payloads:** Lower compression `level` for speed
- **Storage-constrained:** Increase `level` to 9

### TLS

For production HTTP API:

```elixir
config :concord,
  tls: [
    enabled: true,
    certfile: "/path/to/cert.pem",
    keyfile: "/path/to/key.pem",
    cacertfile: "/path/to/ca.pem"
  ]
```
