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
