# Configuration

Complete reference for all Concord configuration options.

## Base Configuration (config/config.exs)

```elixir
config :concord,
  cluster_name: :concord_cluster,
  cluster_enabled: true,
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
| `Concord` | Replicated VSR cluster API. |
| `Concord.Cluster` | Explicit VSR-backed cluster API. |
| `Concord.Local` | Node-local KV API. Data stays on the current BEAM node and is not written to the VSR cluster. |
| `Concord.Turso` | Durable node-local KV API backed by `ex_turso`. Data is written to a local Turso database file and is not written to the VSR cluster. |

Canonical sub-APIs follow the same split: `Concord.KV` and
`Concord.Cluster.KV` use the cluster engine, while `Concord.Local.KV` uses the
local engine. Pass `engine: :turso` to canonical APIs when using Turso-specific
calls such as `Concord.KV.history/2` or `Concord.Txn.commit/2`.

### Viewstamped Replication

VSR is Concord's replication protocol. It uses an explicit, ordered membership
list and never derives protocol membership from connected Erlang nodes.
Membership order determines the primary for each view and must be identical on
every replica.

```elixir
config :concord,
  vsr: [
    group_id: :concord_cluster,
    replica_id: :"concord1@example.net",
    members: [
      %{id: :"concord1@example.net", endpoint: :"concord1@example.net"},
      %{id: :"concord2@example.net", endpoint: :"concord2@example.net"},
      %{id: :"concord3@example.net", endpoint: :"concord3@example.net"}
    ],
    transport: :distribution,
    storage: :file,
    storage_path: "/var/lib/concord/data/vsr/concord1",
    bootstrap: false,
    retry_timeout: 100
  ]
```

VSR supports configurations of one, three, or five replicas. Set `bootstrap:
true` only when creating a new configuration, and set it back to `false` for
subsequent starts using the same durable storage. VSR reads are replicated
barriers and therefore linearizable; `:eventual`, `:leader`, and `:strong`
query options all use the same barrier path.

For releases, `CONCORD_VSR_MEMBERS` is a comma-separated ordered list. A member
can be a node name or an explicit `id=endpoint` pair:

```bash
CONCORD_VSR_REPLICA_ID=concord1@example.net
CONCORD_VSR_MEMBERS=concord1@example.net,concord2@example.net,concord3@example.net
CONCORD_VSR_BOOTSTRAP=true
```

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

Applications that only need the durable Turso KV engine can disable Concord's
VSR cluster runtime:

```elixir
config :concord,
  cluster_enabled: false,
  turso: [
    enabled: true,
    database: "./data/turso.db",
    pool_size: 1
  ]
```

Runtime releases can use environment variables:

```bash
CONCORD_CLUSTER_ENABLED=false
CONCORD_TURSO_ENABLED=true
CONCORD_TURSO_DATABASE=/var/apps/concord/lib/concord/turso.db
CONCORD_TURSO_POOL_SIZE=1
CONCORD_TURSO_REMOTE_URL=libsql://example.turso.io
CONCORD_TURSO_AUTH_TOKEN=...
```

`Concord.Turso.sync/1` is available only when both remote URL and auth token are
configured. Turso does not provide Concord VSR semantics, leases, watches, or
secondary indexes; those operations return explicit unsupported-operation
errors.

### Ecto SQL adapter

`Concord.Turso` is a Concord KV API. Applications that need normal Ecto schema,
query, migration, transaction, constraint/index, and map/JSON-field semantics
should configure an Ecto repo with the optional adapter provided by `ex_turso`:

```elixir
def deps do
  [
    {:concord, "~> 3.0.0-alpha"},
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
  data_dir: {:system, "CONCORD_DATA_DIR", "/var/apps/concord/lib/concord"},
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
      System.get_env("CONCORD_DATA_DIR", "/var/apps/concord/lib/concord/data/#{node_name}")
    _dev_or_test ->
      Path.join(System.tmp_dir!(), "concord_data/#{node_name}")
  end
```

**Important:** In dev/test, data is stored in `/tmp` and will be lost on reboot. In production, set `CONCORD_DATA_DIR` to a persistent location.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CONCORD_DATA_DIR` | `/var/apps/concord/lib/concord/data` | Persistent data directory (prod) |
| `CONCORD_CLUSTER_ENABLED` | `true` | Start Concord's configured replication runtime |
| `CONCORD_VSR_GROUP_ID` | `concord_cluster` | VSR configuration group identifier |
| `CONCORD_VSR_REPLICA_ID` | current Erlang node | Local VSR member identifier |
| `CONCORD_VSR_MEMBERS` | current replica only | Ordered comma-separated VSR members (`id` or `id=endpoint`) |
| `CONCORD_VSR_TRANSPORT` | `distribution` | VSR transport: `distribution` or `local` |
| `CONCORD_VSR_STORAGE` | `file` | VSR storage: `file` or `memory` |
| `CONCORD_VSR_STORAGE_PATH` | `<data_dir>/vsr/<replica_id>` | Durable VSR WAL/checkpoint directory |
| `CONCORD_VSR_BOOTSTRAP` | `false` | Bootstrap a new VSR configuration |
| `CONCORD_VSR_RETRY_TIMEOUT` | `100` | VSR client retry interval in milliseconds |
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

config :concord, :http, enabled: true, port: 4000
```

## Key Configuration Decisions

### Read Consistency

VSR currently implements `:eventual`, `:leader`, and `:strong` as the same
replicated query barrier. All three names are accepted for API compatibility
and currently provide linearizable reads.

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
