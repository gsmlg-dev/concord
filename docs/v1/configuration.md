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
  max_command_bytes: 64 * 1_024 * 1_024,
  default_read_consistency: :leader,  # :eventual, :leader, or :strong

  txn: [
    max_compare_ops: 64,
    max_success_ops: 128,
    max_failure_ops: 128,
    max_txn_bytes: 1_000_000,
    max_range_limit: 1_000
  ],

  kv: [
    max_key_bytes: 4_096,
    max_value_bytes: 16 * 1_024 * 1_024
  ],

  ttl: [
    default_seconds: 86_400,
    cleanup_interval_seconds: 300,
    enabled: true
  ],

  compression: [
    enabled: true,
    algorithm: :zlib,          # :zlib, :gzip, or :none
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

## Consensus and local admission limits

Version-one envelopes have immutable protocol maxima. The corresponding
settings above are local pre-consensus admission caps: a smaller value rejects
work earlier, while a larger value is clamped to the protocol maximum and
cannot widen the replicated command language. Configure the same local caps on
every node so routing a request to another node does not change admission. Caps
must be non-negative integers; an invalid value fails closed as a zero cap
instead of silently widening admission.

| Resource | Immutable v1 maximum | Local setting |
|---|---:|---|
| Operations in a bulk command | 500 | `max_batch_size` |
| Raw and logical aggregate command size | 64 MiB each | `max_command_bytes` |
| Key size | 4,096 bytes | `kv.max_key_bytes` |
| Raw and logical value size | 16 MiB each | `kv.max_value_bytes` |
| Transaction compares | 64 | `txn.max_compare_ops` |
| Operations in either transaction branch | 128 | `txn.max_success_ops`, `txn.max_failure_ops` |
| Logical serialized transaction size | 1,000,000 bytes | `txn.max_txn_bytes` |
| Transaction range result limit | 1,000 | `txn.max_range_limit` |

Raw serialized size and logical size after expanding Concord compression
envelopes must both fit. Therefore compression cannot hide an oversized value
or command, while `compress: true`, automatic compression, and
`compress: false` have the same logical policy. The 64 MiB aggregate cap also
covers `put_many` and `restore_backup`, leaving headroom below the VSR file
WAL's 256 MiB record limit. Version-one replay uses these frozen maxima rather
than local settings; exact version-zero replay remains unrestricted for
historical compatibility.

Compression decoding is an in-process trusted-input boundary, not a sandbox.
The v1 decoder bounds expanded external-term data to 16 MiB and rejects nested
ETF compression, functions, PIDs, ports, and references, but ordinary ETF atom
decoding can intern atom names and decoding allocates the logical term before
recursive validation. Do not expose raw Erlang-term command or backup input to
untrusted clients; translate an authenticated, bounded wire schema at the
application boundary.

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
    wal_version: 1,
    bootstrap: false,
    retry_timeout: 100,
    command_version: 0
  ]
```

VSR supports configurations of one through six replicas and uses a strict
majority quorum. Set `bootstrap: true` only when creating a new configuration,
and set it back to `false` for subsequent starts using the same durable
storage. VSR reads are replicated barriers and therefore linearizable;
`:eventual`, `:leader`, and `:strong` query options all use the same barrier
path.

`command_version: 0` emits the legacy command envelope while readers are being
upgraded. New writers still enforce the strict current command schema; the
version-zero replay path exists only to preserve historical behavior. Use this
rollout order:

1. Upgrade every replica while keeping `command_version: 0`.
2. Inspect `Concord.status/0`, record every exact value in
   `storage.legacy_indexes`, and pass each exact name to
   `Concord.Index.drop/2`. Do not recreate the indexes yet. The list includes
   non-declarative extractors and names that are not non-empty, valid UTF-8
   binaries of at most 255 bytes.
3. Pause writes, set `command_version: 1` on every node, and remove every old
   reader from the quorum before resuming operator commands. If an index was
   missed, only its exact listed name is admitted for the required drop.
4. Run `Concord.Engine.command(:reconcile_legacy_state)`. Normal version-one
   commands remain blocked until status reports
   `storage.legacy_state_reconciliation_required == false`,
   `storage.legacy_state_representation == :current`, and
   `storage.legacy_state_conflict_count == 0`.
5. Recreate the dropped indexes with valid names and declarative extractors,
   using `reindex: true`. A valid old name may be reused; an invalid name must
   be replaced. Calling `Concord.Index.reindex/2` immediately after plain
   creation is equivalent.

Under version-one admission, the two pre-reconciliation errors are
`{:legacy_indexes_require_migration, names}` and
`{:legacy_state_requires_reconciliation, status}`. Reindexing after
reconciliation backfills records that already exist. Status reports the active
`command_version` and configured `wal_version`. The equivalent release
variable is `CONCORD_VSR_COMMAND_VERSION`.

`wal_version: 1` is also a compatibility gate. For built-in file storage it
selects the format for both new WAL records and rewritten checkpoints; memory
and custom storage do not derive their behavior from it. The current reader
accepts versions one and two, but a release that predates version two can
mistake version-two data for a disposable tail during rollback. Deploy the new
reader everywhere while continuing to emit version one. Set `wal_version: 2`
only after the old binary is outside the rollback window. Once a version-two
WAL record or checkpoint exists, setting the option back to 1 does not convert
it: do not open that directory with an old reader. A later binary rollback
requires restoring a separately verified version-one-compatible backup because
there is no automatic downgrade. Version two checksums the record length and
can therefore distinguish a corrupt length from a genuinely incomplete append.
The equivalent release variable is `CONCORD_VSR_WAL_VERSION`.

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
    {:concord, "~> 3.0.0-beta"},
    {:ex_turso, "~> 3.0.0-beta"},
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
| `CONCORD_VSR_WAL_VERSION` | `1` | Built-in file-storage WAL/checkpoint write format (`1` during the rollback window, then one-way opt-in to `2`) |
| `CONCORD_VSR_BOOTSTRAP` | `false` | Bootstrap a new VSR configuration |
| `CONCORD_VSR_RETRY_TIMEOUT` | `100` | VSR client retry interval in milliseconds |
| `CONCORD_VSR_COMMAND_VERSION` | `0` | Emitted Concord command envelope (`0` during compatibility rollout, then `1`) |
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
quorum-confirmed read barrier. The barrier does not append to the replicated
log. All three names are accepted for API compatibility and currently provide
linearizable reads.

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
