# Concord [![Build Status](https://github.com/your-org/concord/workflows/CI/badge.svg)](https://github.com/your-org/concord/actions) [![Hex.pm](https://img.shields.io/hexpm/v/concord.svg)](https://hex.pm/packages/concord) [![Documentation](https://img.shields.io/badge/docs-latest-blue.svg)](https://hexdocs.pm/concord/) [![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> A distributed, strongly-consistent embedded key-value store built in Elixir using the Raft consensus algorithm.

**Concord** is designed as an **embedded database** that Elixir applications can include as a dependency, providing distributed coordination, configuration management, and service discovery with strong consistency guarantees and microsecond-level performance.

## ✨ Key Features

- ⚡ **Exceptional Performance** - 600K-870K ops/sec with 1-7μs latency
- 🌐 **HTTP API Included** - Complete REST API with OpenAPI/Swagger documentation
- 🔒 **Secure by Default** - Token-based and API key authentication
- 📊 **Observability First** - Comprehensive telemetry and monitoring
- 🛠️ **Production Ready** - Battle-tested with extensive tooling
- 🎯 **Embedded Design** - Starts with your application, no separate infrastructure

### Core Capabilities

- **Strong Consistency** - Raft consensus algorithm ensures all nodes agree on data
- **Configurable Read Consistency** - Choose between eventual, leader, or strong consistency per operation
- **HTTP API** - Complete REST API for management and integration
- **TTL Support** - Automatic key expiration with time-to-live
- **Bulk Operations** - Efficient batch processing (up to 500 operations)
- **Value Compression** - Automatic compression for large values to reduce memory usage
- **Fault Tolerant** - Continues operating despite node failures (requires quorum)
- **Read Load Balancing** - Automatic read distribution across cluster for eventual consistency reads
- **In-Memory Storage** - Fast ETS-based storage with automatic snapshots
- **Real-time Metrics** - Built-in telemetry for all operations and cluster health

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:concord, "~> 0.1.0"}
  ]
end
```

## 🚀 Quick Start

### Embedded Database Setup (2 minutes)

**1. Add Concord to your project:**

```elixir
# mix.exs
def deps do
  [
    {:concord, "~> 0.1.0"}
  ]
end
```

**2. Start using it immediately:**

```elixir
# In your application
iex> # Start Concord (automatic when using as dependency)
iex> Concord.put("user:1001", %{name: "Alice", role: "admin", last_login: DateTime.utc_now()})
:ok

iex> Concord.get("user:1001")
{:ok, %{name: "Alice", role: "admin", last_login: ~U[2025-10-21 12:47:27.231034Z]}}

iex> Concord.put("feature:dark_mode", "enabled", [ttl: 3600])
:ok

iex> Concord.get_with_ttl("feature:dark_mode")
{:ok, {"enabled", 3595}}

iex> Concord.delete("user:1001")
:ok
```

### HTTP API Usage

**1. Start the HTTP API server:**

```bash
# Development mode (auth disabled)
mix start

# Production mode (auth enabled)
CONCORD_API_PORT=8080 CONCORD_AUTH_ENABLED=true mix start
```

**2. Use the REST API:**

```bash
# Health check
curl http://localhost:4000/api/v1/health

# Store data with Bearer token
export CONCORD_TOKEN="your-token-here"
curl -X PUT \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"value": "Hello, World!"}' \
  http://localhost:4000/api/v1/kv/greeting

# Retrieve data
curl -H "Authorization: Bearer $CONCORD_TOKEN" \
  http://localhost:4000/api/v1/kv/greeting

# View interactive documentation
open http://localhost:4000/api/docs
```

### Multi-Node Cluster (Optional)

```bash
# Terminal 1
iex --name n1@127.0.0.1 --cookie concord -S mix

# Terminal 2
iex --name n2@127.0.0.1 --cookie concord -S mix

# Terminal 3
iex --name n3@127.0.0.1 --cookie concord -S mix
```

### Production Usage with Authentication

**1. Configure authentication:**

```elixir
# config/prod.exs
config :concord,
  auth_enabled: true,
  data_dir: System.get_env("CONCORD_DATA_DIR", "/var/lib/concord")
```

**2. Create and use tokens:**

```bash
# Generate secure token
mix concord.cluster token create
# ✓ Created token: sk_concord_abc123def456...

# Revoke when needed
mix concord.cluster token revoke sk_concord_abc123def456...
```

```elixir
# Use in application code
token = System.fetch_env!("CONCORD_TOKEN")

Concord.put("config:api_rate_limit", 1000, token: token)
Concord.get("config:api_rate_limit", token: token)
# {:ok, 1000}
```

### HTTP API Endpoints

Concord provides a complete REST API when the HTTP server is enabled:

**Core Operations:**
- `PUT /api/v1/kv/:key` - Store key-value pair
- `GET /api/v1/kv/:key` - Retrieve value (with optional TTL)
- `DELETE /api/v1/kv/:key` - Delete key

**TTL Operations:**
- `POST /api/v1/kv/:key/touch` - Extend TTL
- `GET /api/v1/kv/:key/ttl` - Get remaining TTL

**Bulk Operations:**
- `POST /api/v1/kv/bulk` - Bulk store (up to 500 items)
- `POST /api/v1/kv/bulk/get` - Bulk retrieve
- `POST /api/v1/kv/bulk/delete` - Bulk delete
- `POST /api/v1/kv/bulk/touch` - Bulk TTL operations

**Management:**
- `GET /api/v1/kv` - List all keys (with pagination)
- `GET /api/v1/status` - Cluster status
- `GET /api/v1/openapi.json` - OpenAPI specification
- `GET /api/docs` - Interactive Swagger UI

### Common Use Cases

**Feature Flags:**
```elixir
Concord.put("flags:new_dashboard", "enabled")
Concord.put("flags:maintenance_mode", "disabled")

if Concord.get("flags:new_dashboard") == {:ok, "enabled"} do
  render_new_dashboard()
end
```

**Phoenix Session Storage:**
```elixir
# Store user session with 30-minute TTL
Concord.put("session:#{session_id}", session_data, [ttl: 1800])

# Retrieve session with TTL
Concord.get_with_ttl("session:#{session_id}")
# {:ok, {%{user_id: 123, ...}, 1755}}

# Extend session on activity
Concord.touch("session:#{session_id}", 1800)
```

**Rate Limiting:**
```elixir
# Check rate limit for user
user_key = "rate_limit:#{user_id}:#{Date.utc_today()}"
case Concord.get(user_key) do
  {:ok, count} when count < 1000 ->
    Concord.put(user_key, count + 1, [ttl: 86400])
    :allow
  _ -> :deny
end
```

**Service Discovery:**
```elixir
# Register service
Concord.put("services:web:1", %{
  host: "10.0.1.100",
  port: 8080,
  health: "healthy",
  last_check: DateTime.utc_now()
})

# Discover healthy services
Concord.get_all()
|> elem(1)
|> Enum.filter(fn {k, _} -> String.starts_with?(k, "services:web:") end)
|> Enum.filter(fn {_, v} -> v.health == "healthy" end)
```

**Distributed Locks:**
```elixir
# Acquire lock
case Concord.put("locks:job:123", "node:worker1", timeout: 5000) do
  :ok ->
    # Do work
    Concord.delete("locks:job:123")
  {:error, :timeout} ->
    # Lock already held
end
```

## Read Consistency Levels

Concord supports configurable read consistency levels, allowing you to balance between performance and data freshness based on your application needs.

### Available Consistency Levels

**`:eventual` - Fastest, Eventually Consistent Reads**
```elixir
# Read from any available node (may be slightly stale)
Concord.get("user:123", consistency: :eventual)

# Perfect for:
# - High-throughput read operations
# - Dashboard metrics and analytics
# - Cached data where staleness is acceptable
```

**`:leader` - Balanced, Default Consistency (Default)**
```elixir
# Read from the leader node (more up-to-date)
Concord.get("user:123", consistency: :leader)
# Or simply:
Concord.get("user:123")  # Uses configured default

# Perfect for:
# - Most application needs
# - General data retrieval
# - Balance between performance and freshness
```

**`:strong` - Strongest, Linearizable Reads**
```elixir
# Read from leader with heartbeat verification (most up-to-date)
Concord.get("user:123", consistency: :strong)

# Perfect for:
# - Critical financial data
# - Security-sensitive operations
# - Scenarios requiring strict consistency guarantees
```

### Configuration

Set your default read consistency level in `config/config.exs`:

```elixir
config :concord,
  default_read_consistency: :leader  # :eventual, :leader, or :strong
```

### All Read Operations Support Consistency Levels

```elixir
# Single get
Concord.get("key", consistency: :eventual)

# Batch get
Concord.get_many(["key1", "key2"], consistency: :strong)

# Get with TTL
Concord.get_with_ttl("key", consistency: :leader)

# Get TTL only
Concord.ttl("key", consistency: :eventual)

# Get all
Concord.get_all(consistency: :strong)

# Get all with TTL
Concord.get_all_with_ttl(consistency: :eventual)

# Cluster status
Concord.status(consistency: :leader)
```

### Performance Characteristics

| Consistency | Latency | Staleness | Use Case |
|------------|---------|-----------|----------|
| `:eventual` | ~1-5ms | May be stale | High-throughput reads, analytics |
| `:leader` | ~5-10ms | Minimal staleness | General application data |
| `:strong` | ~10-20ms | Zero staleness | Critical operations |

### Read Load Balancing

When using `:eventual` consistency, Concord automatically distributes reads across available cluster members for improved performance:

```elixir
# These reads are automatically load-balanced across the cluster
1..1000
|> Enum.each(fn i ->
  Concord.get("metric:#{i}", consistency: :eventual)
end)
```

### Telemetry Integration

All read operations emit telemetry events that include the consistency level used:

```elixir
:telemetry.attach(
  "my-handler",
  [:concord, :api, :get],
  fn _event, %{duration: duration}, %{consistency: consistency}, _config ->
    Logger.info("Read with #{consistency} consistency took #{duration}ns")
  end,
  nil
)
```

## Management Commands

```bash
# Check cluster health
mix concord.cluster status

# Output:
# Cluster Status:
# Node: n1@127.0.0.1
#
# Cluster Overview:
# %{
#   commit_index: 42,
#   current_term: 5,
#   leader: {:concord_cluster, :"n1@127.0.0.1"},
#   members: [...],
#   state: :leader
# }
#
# Storage Stats:
#   Size: 1337 entries
#   Memory: 45892 words

# List cluster members
mix concord.cluster members

# Create authentication token
mix concord.cluster token create

# Revoke a token
mix concord.cluster token revoke <token>
```

## Backup and Restore

Concord provides comprehensive backup and restore capabilities for data safety and disaster recovery.

### Quick Start

**Create a backup:**

```bash
# Create backup in default directory (./backups)
mix concord.backup create

# Create backup in custom directory
mix concord.backup create --path /mnt/backups

# Output:
# Creating backup...
# ✓ Backup created successfully!
#   Path: ./backups/concord_backup_20251023T143052.backup
#   Size: 2.45 MB
```

**List available backups:**

```bash
mix concord.backup list

# Output:
# Found 3 backup(s):
#
# Backup: concord_backup_20251023T143052.backup
#   Created: 2025-10-23 14:30:52Z
#   Entries: 15420
#   Size: 2.45 MB
#   Node: node1@127.0.0.1
#   Version: 0.1.0
```

**Restore from backup:**

```bash
# Interactive restore (asks for confirmation)
mix concord.backup restore ./backups/concord_backup_20251023T143052.backup

# Force restore (skip confirmation)
mix concord.backup restore ./backups/concord_backup_20251023T143052.backup --force

# Output:
# ⚠️  WARNING: This will overwrite all data in the cluster!
# Are you sure you want to continue? (yes/no): yes
#
# Restoring from backup: ./backups/concord_backup_20251023T143052.backup
# ✓ Backup restored successfully!
```

**Verify backup integrity:**

```bash
mix concord.backup verify ./backups/concord_backup_20251023T143052.backup

# Output:
# Verifying backup: ./backups/concord_backup_20251023T143052.backup
# ✓ Backup is valid
```

**Clean up old backups:**

```bash
# Keep only the 5 most recent backups
mix concord.backup cleanup --keep-count 5

# Keep backups from last 7 days
mix concord.backup cleanup --keep-days 7

# Output:
# Cleaning up backups in: ./backups
#   Keep count: 5
#   Keep days: 30
# ✓ Deleted 8 old backup(s)
```

### Programmatic Usage

```elixir
# Create backup
{:ok, backup_path} = Concord.Backup.create(path: "/mnt/backups")
IO.puts("Backup saved to: #{backup_path}")

# List backups
{:ok, backups} = Concord.Backup.list("/mnt/backups")
Enum.each(backups, fn backup ->
  IO.puts("#{backup.path} - #{backup.entry_count} entries")
end)

# Restore from backup
:ok = Concord.Backup.restore("/mnt/backups/concord_backup_20251023.backup")

# Verify backup
case Concord.Backup.verify("/path/to/backup.backup") do
  {:ok, :valid} -> IO.puts("Backup is valid")
  {:ok, :invalid} -> IO.puts("Backup is corrupted")
  {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
end

# Cleanup old backups
{:ok, deleted_count} = Concord.Backup.cleanup(
  path: "/mnt/backups",
  keep_count: 10,
  keep_days: 30
)
IO.puts("Deleted #{deleted_count} old backups")
```

### Backup Format

Backups are stored as compressed Erlang term files (`.backup`) containing:

- **Metadata**: Timestamp, cluster info, entry count, checksum
- **Snapshot Data**: Full copy of all key-value pairs
- **Integrity Check**: SHA-256 checksum for verification

**Features:**
- Compressed storage for efficient disk usage
- Atomic snapshots via Ra consensus
- Integrity verification with checksums
- Metadata tracking for audit trails
- Compatible across cluster nodes

### Automated Backups

For production deployments, schedule automated backups using cron:

```bash
# Add to crontab: backup every hour
0 * * * * cd /app && mix concord.backup create --path /mnt/backups

# Add to crontab: cleanup old backups daily
0 2 * * * cd /app && mix concord.backup cleanup --keep-count 24 --keep-days 7
```

Or use a GenServer for in-app scheduling:

```elixir
defmodule MyApp.BackupScheduler do
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    # Schedule backup every hour
    schedule_backup()
    {:ok, state}
  end

  def handle_info(:backup, state) do
    case Concord.Backup.create(path: "/mnt/backups") do
      {:ok, path} ->
        Logger.info("Backup created: #{path}")

        # Cleanup old backups
        Concord.Backup.cleanup(path: "/mnt/backups", keep_count: 24)

      {:error, reason} ->
        Logger.error("Backup failed: #{inspect(reason)}")
    end

    schedule_backup()
    {:noreply, state}
  end

  defp schedule_backup do
    # Schedule next backup in 1 hour
    Process.send_after(self(), :backup, :timer.hours(1))
  end
end
```

### Best Practices

1. **Regular Backups**: Schedule automated backups hourly or daily
2. **Off-site Storage**: Copy backups to remote storage (S3, GCS, etc.)
3. **Test Restores**: Periodically test backup restoration
4. **Retention Policy**: Keep multiple backup versions
5. **Monitor**: Set up alerts for backup failures
6. **Verify**: Always verify backups after creation

### Disaster Recovery

**Complete disaster recovery procedure:**

```bash
# 1. Stop the application (if running)
# 2. Restore from backup
mix concord.backup restore /mnt/backups/latest.backup --force

# 3. Verify data
mix concord.cluster status

# 4. Start the application
mix run --no-halt
```

## Telemetry Integration

Concord emits comprehensive telemetry events for monitoring:

### Available Events

```elixir
# API Operations
[:concord, :api, :put]       # Measurements: %{duration: integer}
[:concord, :api, :get]       # Metadata: %{result: :ok | :error}
[:concord, :api, :delete]    

# Raft Operations
[:concord, :operation, :apply]  # Measurements: %{duration: integer}
                                 # Metadata: %{operation: atom, key: any, index: integer}

# State Changes
[:concord, :state, :change]     # Metadata: %{status: atom, node: node()}

# Snapshots
[:concord, :snapshot, :created]    # Measurements: %{size: integer}
[:concord, :snapshot, :installed]  # Metadata: %{node: node()}

# Cluster Health (periodic)
[:concord, :cluster, :status]   # Measurements: %{storage_size: integer, storage_memory: integer}
```

### Example: Custom Metrics Handler

```elixir
defmodule MyApp.ConcordMetrics do
  def setup do
    events = [
      [:concord, :api, :put],
      [:concord, :api, :get],
      [:concord, :state, :change]
    ]

    :telemetry.attach_many(
      "my-app-concord",
      events,
      &handle_event/4,
      nil
    )
  end

  def handle_event([:concord, :api, operation], %{duration: duration}, metadata, _) do
    # Send to your metrics system (Prometheus, StatsD, etc.)
    MyMetrics.histogram("concord.#{operation}.duration", duration)
    MyMetrics.increment("concord.#{operation}.#{metadata.result}")
  end

  def handle_event([:concord, :state, :change], _, %{status: status, node: node}, _) do
    MyMetrics.gauge("concord.node.status", 1, tags: [node: node, status: status])

    if status == :leader do
      Logger.warn("New leader elected: #{node}")
      # Alert your team!
    end
  end
end
```

## Prometheus Integration

Concord includes built-in Prometheus metrics export for production monitoring.

### Quick Start

**1. Configure Prometheus (enabled by default):**

```elixir
# config/config.exs
config :concord,
  prometheus_enabled: true,  # Enable/disable Prometheus exporter
  prometheus_port: 9568      # Metrics endpoint port
```

**2. Access metrics endpoint:**

```bash
# Metrics are automatically exposed at:
curl http://localhost:9568/metrics

# Sample output:
# # HELP concord_api_get_duration_milliseconds Duration of GET operations
# # TYPE concord_api_get_duration_milliseconds summary
# concord_api_get_duration_milliseconds{result="ok",consistency="leader",quantile="0.5"} 2.3
# concord_api_get_duration_milliseconds{result="ok",consistency="leader",quantile="0.9"} 3.8
# concord_api_get_duration_milliseconds{result="ok",consistency="leader",quantile="0.99"} 5.2
#
# # HELP concord_cluster_size Number of entries in the store
# # TYPE concord_cluster_size gauge
# concord_cluster_size 15420
```

### Metrics Exposed

**API Operation Metrics:**
- `concord_api_put_duration_milliseconds` - PUT operation latency (summary)
- `concord_api_get_duration_milliseconds` - GET operation latency with consistency level
- `concord_api_delete_duration_milliseconds` - DELETE operation latency
- `concord_api_*_count_total` - Operation throughput counters

**Cluster Health Metrics:**
- `concord_cluster_size` - Total keys in store
- `concord_cluster_memory` - Memory usage in bytes
- `concord_cluster_member_count` - Number of cluster members
- `concord_cluster_commit_index` - Current Raft commit index
- `concord_cluster_is_leader` - Leader status (1=leader, 0=follower)

**Raft Operation Metrics:**
- `concord_operation_apply_duration_milliseconds` - State machine operation latency
- `concord_operation_apply_count_total` - State machine operation count

**Snapshot Metrics:**
- `concord_snapshot_created_size` - Last snapshot size
- `concord_snapshot_installed_size` - Installed snapshot size

### Prometheus Configuration

Add Concord to your Prometheus scrape config:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'concord'
    static_configs:
      - targets: ['localhost:9568']
        labels:
          app: 'concord'
          env: 'production'
    scrape_interval: 15s
```

### Grafana Dashboard

Import the included Grafana dashboard for instant visualization:

```bash
# Import the dashboard template
cat grafana-dashboard.json | curl -X POST \
  -H "Content-Type: application/json" \
  -d @- \
  http://admin:admin@localhost:3000/api/dashboards/db
```

**Dashboard Features:**
- Real-time API operation latency graphs
- Operations per second (throughput)
- Cluster health overview (keys, memory, members)
- Leader status indicator
- Raft commit index progression

### Example: Prometheus Alerts

```yaml
# prometheus-alerts.yml
groups:
  - name: concord
    rules:
      - alert: ConcordHighLatency
        expr: concord_api_get_duration_milliseconds{quantile="0.99"} > 100
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Concord GET operations are slow"
          description: "P99 latency is {{ $value }}ms"

      - alert: ConcordNoLeader
        expr: sum(concord_cluster_is_leader) == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Concord cluster has no leader"
          description: "Cluster is unavailable"

      - alert: ConcordHighMemory
        expr: concord_cluster_memory > 1073741824  # 1GB
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Concord memory usage is high"
          description: "Memory usage: {{ $value | humanize }}B"
```

### Disable Prometheus (Optional)

If you don't need Prometheus metrics:

```elixir
# config/config.exs
config :concord,
  prometheus_enabled: false
```

## Distributed Tracing

Concord includes built-in OpenTelemetry distributed tracing support for tracking requests across your cluster and identifying performance bottlenecks.

### Quick Start

**1. Enable distributed tracing:**

```elixir
# config/config.exs
config :concord,
  tracing_enabled: true,
  tracing_exporter: :stdout  # :stdout, :otlp, or :none
```

**2. Configure OpenTelemetry exporter:**

```elixir
# For development - stdout exporter
config :opentelemetry,
  traces_exporter: {:otel_exporter_stdout, []}

# For production - OTLP exporter (Jaeger, Zipkin, etc.)
config :opentelemetry,
  traces_exporter: {:otel_exporter_otlp, %{
    endpoint: "http://localhost:4317"
  }}
```

**3. Operations are automatically traced:**

```elixir
# All Concord operations emit traces
Concord.put("user:123", %{name: "Alice"})
# Trace: concord.api.put with duration, result, TTL info

Concord.get("user:123")
# Trace: concord.api.get with duration, consistency level
```

### HTTP API Trace Propagation

Concord automatically extracts and propagates W3C Trace Context from HTTP requests:

```bash
# Send request with trace context
curl -H "traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" \
     -H "Authorization: Bearer $TOKEN" \
     http://localhost:4000/api/v1/kv/mykey

# Response includes trace headers
# traceparent: 00-0af7651916cd43dd8448eb211c80319c-new-span-id-01
```

### Manual Instrumentation

Add custom spans to your application code:

```elixir
require Concord.Tracing

# Wrap operations in spans
Concord.Tracing.with_span "process_user_data", %{user_id: "123"} do
  # Your code here
  Concord.Tracing.set_attribute(:cache_hit, true)
  Concord.Tracing.add_event("data_processed", %{rows: 100})

  result
end

# Get current trace information
trace_id = Concord.Tracing.current_trace_id()
span_id = Concord.Tracing.current_span_id()
Logger.info("Processing request", trace_id: trace_id, span_id: span_id)
```

### Integration with Trace Backends

**Jaeger (Recommended):**

```bash
# Start Jaeger all-in-one
docker run -d --name jaeger \
  -e COLLECTOR_OTLP_ENABLED=true \
  -p 4317:4317 \
  -p 16686:16686 \
  jaegertracing/all-in-one:latest

# Configure Concord
config :opentelemetry_exporter,
  otlp_protocol: :grpc,
  otlp_endpoint: "http://localhost:4317"

# View traces at http://localhost:16686
```

**Zipkin:**

```bash
# Start Zipkin
docker run -d -p 9411:9411 openzipkin/zipkin

# Configure Concord
config :opentelemetry,
  traces_exporter: {:otel_exporter_zipkin, %{
    endpoint: "http://localhost:9411/api/v2/spans"
  }}
```

**Honeycomb:**

```elixir
config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: "https://api.honeycomb.io",
  otlp_headers: [
    {"x-honeycomb-team", "YOUR_API_KEY"},
    {"x-honeycomb-dataset", "concord"}
  ]
```

### Telemetry Integration

Concord automatically bridges existing telemetry events to OpenTelemetry spans:

- `[:concord, :api, :put]` → Span with PUT operation metrics
- `[:concord, :api, :get]` → Span with GET operation and consistency level
- `[:concord, :operation, :apply]` → Span for Raft state machine operations
- `[:concord, :snapshot, :created]` → Snapshot creation events

### Trace Attributes

**HTTP Request Attributes:**
- `http.method` - HTTP method (GET, PUT, DELETE)
- `http.target` - Request path
- `http.status_code` - Response status
- `http.user_agent` - Client user agent
- `net.peer.ip` - Client IP address

**Concord Operation Attributes:**
- `concord.operation` - Operation type (put, get, delete)
- `concord.key` - Key being accessed (if safe to log)
- `concord.consistency` - Read consistency level
- `concord.has_ttl` - Whether TTL was set
- `concord.result` - Operation result (:ok, :error)

### Performance Impact

Distributed tracing adds minimal overhead:

- **CPU**: ~1-5% overhead when enabled
- **Memory**: ~100-500KB per active trace
- **Latency**: ~0.1-0.5ms per span
- **Network**: Depends on exporter (OTLP, stdout, etc.)

### Best Practices

1. **Enable in Production**: Tracing is invaluable for debugging distributed systems
2. **Sample Appropriately**: Use sampling to reduce overhead in high-traffic systems
3. **Sensitive Data**: Avoid logging sensitive keys/values in trace attributes
4. **Exporter Choice**: Use stdout for development, OTLP for production
5. **Monitor Costs**: Some trace backends charge per span, configure sampling

### Sampling Configuration

```elixir
# Sample 10% of traces
config :opentelemetry,
  sampler: {:parent_based, %{
    root: {:trace_id_ratio_based, 0.1}
  }}

# Always sample errors, 5% of success
config :opentelemetry,
  sampler: {:parent_based, %{
    root: {:trace_id_ratio_based, 0.05}
  }}
```

### Disable Tracing

```elixir
# config/config.exs
config :concord,
  tracing_enabled: false
```

## Audit Logging

Concord provides comprehensive audit logging for compliance, security, and debugging. All data-modifying operations are automatically logged to immutable, append-only files.

### Quick Start

**1. Enable audit logging:**

```elixir
# config/config.exs
config :concord,
  audit_log: [
    enabled: true,
    log_dir: "./audit_logs",
    rotation_size_mb: 100,      # Rotate at 100MB
    retention_days: 90,          # Keep logs for 90 days
    log_reads: false,            # Don't log read operations
    sensitive_keys: false        # Hash keys instead of logging values
  ]
```

**2. Operations are automatically audited:**

```elixir
# All write operations are automatically logged
Concord.put("user:123", %{name: "Alice"})
# Audit log entry created with operation, timestamp, result, etc.

Concord.delete("user:123")
# Deletion is logged with full context
```

### Audit Log Format

Each audit log entry is a structured JSON object:

```json
{
  "timestamp": "2025-10-23T08:30:45.123456Z",
  "event_id": "550e8400-e29b-41d4-a716-446655440000",
  "operation": "put",
  "key_hash": "sha256:abc123def456...",
  "result": "ok",
  "user": "token:sk_concord_...",
  "node": "node1@127.0.0.1",
  "metadata": {
    "has_ttl": true,
    "ttl_seconds": 3600,
    "compressed": false
  },
  "trace_id": "a1b2c3d4e5f6...",
  "span_id": "789012345678..."
}
```

### Querying Audit Logs

```elixir
# Get recent audit logs
{:ok, logs} = Concord.AuditLog.query(limit: 100)

# Filter by operation type
{:ok, logs} = Concord.AuditLog.query(operation: "put", limit: 50)

# Filter by time range
{:ok, logs} = Concord.AuditLog.query(
  from: ~U[2025-10-23 00:00:00Z],
  to: ~U[2025-10-23 23:59:59Z],
  limit: 1000
)

# Filter by user
{:ok, logs} = Concord.AuditLog.query(
  user: "token:sk_concord_abc123...",
  limit: 50
)

# Filter by result
{:ok, logs} = Concord.AuditLog.query(result: :error, limit: 100)
```

### Exporting Audit Logs

```elixir
# Export all logs
:ok = Concord.AuditLog.export("/backup/audit_export_20251023.jsonl")

# Export with filters
:ok = Concord.AuditLog.export(
  "/backup/errors_20251023.jsonl",
  result: :error,
  from: ~U[2025-10-23 00:00:00Z]
)
```

### Log Rotation and Retention

Audit logs automatically rotate and clean up based on configuration:

```elixir
# Manual rotation
Concord.AuditLog.rotate()

# Manual cleanup of old logs
Concord.AuditLog.cleanup()

# Check audit log statistics
stats = Concord.AuditLog.stats()
# %{
#   enabled: true,
#   current_log_size: 45678912,
#   total_size: 234567890,
#   log_dir: "./audit_logs"
# }
```

### Log Files

Audit logs are stored as append-only JSONL files:

```
./audit_logs/
├── audit_2025-10-23.jsonl           # Current day's log
├── audit_2025-10-23_1729665045.jsonl # Rotated log (timestamp)
├── audit_2025-10-22.jsonl
└── audit_2025-10-21.jsonl
```

### Manual Audit Logging

Log custom events beyond automatic operation tracking:

```elixir
Concord.AuditLog.log(%{
  operation: "data_import",
  key: "batch:20251023",
  result: :ok,
  metadata: %{
    source: "legacy_system",
    records_imported: 5000,
    duration_ms: 12345
  }
})
```

### Compliance Support

Audit logs support compliance requirements:

**PCI-DSS**: Track and monitor all access to cardholder data
```elixir
# Configure to log all operations including reads
config :concord,
  audit_log: [
    enabled: true,
    log_reads: true,  # Required for PCI-DSS
    retention_days: 90  # Minimum 90 days
  ]
```

**HIPAA**: Audit controls for PHI access
```elixir
# Log with user identification
config :concord,
  audit_log: [
    enabled: true,
    log_reads: true,
    sensitive_keys: true,  # Log actual keys for HIPAA audit trails
    retention_days: 365  # Minimum 6 years in production
  ]
```

**GDPR**: Data processing activity logs
```elixir
# Export audit logs for data subject access requests
Concord.AuditLog.query(
  user: "user_id_from_dsar",
  from: ~U[2024-01-01 00:00:00Z]
)
|> elem(1)
|> Jason.encode!()
|> File.write!("dsar_audit_log.json")
```

**SOC 2**: Detailed audit trails for security events
```elixir
# Monitor for suspicious activity
{:ok, failed_ops} = Concord.AuditLog.query(result: :error, limit: 1000)

Enum.each(failed_ops, fn log ->
  if log["metadata"]["unauthorized_attempt"] do
    alert_security_team(log)
  end
end)
```

### Security Features

**Immutable Logs**: Append-only files prevent tampering
- Files are never modified after creation
- Hash verification ensures integrity
- Timestamps are UTC-based and monotonic

**Key Hashing**: Protect sensitive data
```elixir
# By default, keys are hashed (SHA-256)
config :concord,
  audit_log: [sensitive_keys: false]  # Only hashes logged

# For compliance that requires actual keys
config :concord,
  audit_log: [sensitive_keys: true]  # Actual keys logged
```

**Trace Context Integration**: Link audit logs to distributed traces
- Automatically includes `trace_id` and `span_id` when tracing is enabled
- Correlate audit events with performance traces
- End-to-end request tracking across services

### Best Practices

1. **Enable for Production**: Audit logging is essential for security and compliance
2. **Secure Storage**: Store audit logs on separate, read-only mounts if possible
3. **Regular Exports**: Export audit logs to long-term storage (S3, archive)
4. **Monitor Size**: Set appropriate rotation thresholds for your workload
5. **Test Restores**: Periodically verify audit log exports are readable
6. **Access Control**: Restrict audit log directory permissions (chmod 700)

### Performance Impact

Audit logging has minimal performance impact:

- **CPU**: < 1% overhead (async writes)
- **Memory**: ~1-5MB buffer
- **Disk I/O**: Buffered writes, ~10-100KB/sec depending on operation rate
- **Latency**: No impact on operation latency (async)

### Integration with SIEM

Export audit logs to Security Information and Event Management (SIEM) systems:

**Splunk:**
```bash
# Configure Splunk forwarder to monitor audit log directory
[monitor://./audit_logs]
disabled = false
sourcetype = concord_audit
index = security
```

**Elasticsearch:**
```elixir
# Stream audit logs to Elasticsearch
File.stream!("./audit_logs/audit_2025-10-23.jsonl")
|> Stream.map(&Jason.decode!/1)
|> Enum.each(fn log ->
  Elasticsearch.post("/concord-audit/_doc", log)
end)
```

### Disable Audit Logging

```elixir
# config/config.exs
config :concord,
  audit_log: [enabled: false]
```

## Event Streaming

Concord provides real-time event streaming for Change Data Capture (CDC), allowing applications to subscribe to data changes as they happen using GenStage for back-pressure management.

### Quick Start

**Enable event streaming:**

```elixir
# config/config.exs
config :concord,
  event_stream: [
    enabled: true,
    buffer_size: 10_000  # Max events to buffer before back-pressure
  ]
```

**Subscribe to all events:**

```elixir
# Subscribe to receive all events
{:ok, subscription} = Concord.EventStream.subscribe()

# Process events
receive do
  {:concord_event, event} ->
    IO.inspect(event)
    # %{
    #   type: :put,
    #   key: "user:123",
    #   value: %{name: "Alice"},
    #   timestamp: ~U[2025-10-23 12:00:00Z],
    #   node: :node1@127.0.0.1,
    #   metadata: %{}
    # }
end

# Unsubscribe when done
Concord.EventStream.unsubscribe(subscription)
```

### Event Filtering

**Filter by key pattern:**

```elixir
# Only receive events for user-related keys
{:ok, subscription} = Concord.EventStream.subscribe(
  key_pattern: ~r/^user:/
)

# This will receive events for "user:123", "user:456", etc.
# But not for "product:789" or "order:101"
```

**Filter by event type:**

```elixir
# Only receive delete events
{:ok, subscription} = Concord.EventStream.subscribe(
  event_types: [:delete, :delete_many]
)

# This will only receive delete operations
# Put operations will be filtered out
```

**Combine filters:**

```elixir
# Receive only put operations on product keys
{:ok, subscription} = Concord.EventStream.subscribe(
  key_pattern: ~r/^product:/,
  event_types: [:put, :put_many]
)
```

### Event Format

Events are maps with the following structure:

**Single operations (put, get, delete, touch):**

```elixir
%{
  type: :put | :get | :delete | :touch,
  key: "user:123",           # The key being operated on
  value: %{name: "Alice"},   # Value (for put/get operations)
  timestamp: ~U[2025-10-23 12:00:00Z],
  node: :node1@127.0.0.1,    # Node that processed the operation
  metadata: %{ttl: 3600}     # Additional metadata (ttl, compress, etc.)
}
```

**Bulk operations (put_many, delete_many, etc.):**

```elixir
%{
  type: :put_many | :delete_many | :get_many | :touch_many,
  keys: ["user:1", "user:2", "user:3"],  # List of affected keys
  timestamp: ~U[2025-10-23 12:00:00Z],
  node: :node1@127.0.0.1,
  metadata: %{count: 3}
}
```

### Use Cases

**1. Cache Invalidation:**

```elixir
# Subscribe to changes
{:ok, subscription} = Concord.EventStream.subscribe()

# Invalidate application cache when data changes
Task.start(fn ->
  receive do
    {:concord_event, %{type: type, key: key}} when type in [:put, :delete] ->
      MyApp.Cache.invalidate(key)
  end
end)
```

**2. Real-time Notifications:**

```elixir
# Notify users of configuration changes
{:ok, subscription} = Concord.EventStream.subscribe(
  key_pattern: ~r/^config:/
)

receive do
  {:concord_event, %{type: :put, key: key, value: value}} ->
    Phoenix.PubSub.broadcast(MyApp.PubSub, "config_changes", {:config_updated, key, value})
end
```

**3. Audit Trail:**

```elixir
# Stream all changes to external system
{:ok, subscription} = Concord.EventStream.subscribe()

Task.start(fn ->
  Stream.repeatedly(fn ->
    receive do
      {:concord_event, event} -> event
    end
  end)
  |> Stream.each(fn event ->
    ExternalAuditSystem.log(event)
  end)
  |> Stream.run()
end)
```

**4. Data Replication:**

```elixir
# Replicate changes to secondary system
{:ok, subscription} = Concord.EventStream.subscribe(
  key_pattern: ~r/^replicate:/
)

receive do
  {:concord_event, %{type: :put, key: key, value: value}} ->
    SecondaryDB.insert(key, value)

  {:concord_event, %{type: :delete, key: key}} ->
    SecondaryDB.delete(key)
end
```

### Configuration Options

```elixir
config :concord,
  event_stream: [
    # Enable/disable event streaming
    enabled: true,

    # Maximum events to buffer before applying back-pressure
    # If consumers are slow, producer will pause at this limit
    buffer_size: 10_000
  ]
```

### Subscription Options

```elixir
Concord.EventStream.subscribe(
  # Regex pattern to filter keys
  key_pattern: ~r/^user:/,

  # List of event types to receive
  event_types: [:put, :delete],

  # Maximum demand for back-pressure
  # Higher values = more throughput, more memory
  max_demand: 1000
)
```

### Monitoring

**Check event stream statistics:**

```elixir
iex> Concord.EventStream.stats()
%{
  enabled: true,
  queue_size: 42,           # Events waiting to be dispatched
  pending_demand: 958,      # Available demand from consumers
  events_published: 1543    # Total events published since startup
}
```

**Disable event streaming:**

```elixir
# config/config.exs
config :concord,
  event_stream: [enabled: false]
```

### Back-pressure Management

Event streaming uses GenStage for automatic back-pressure:

1. **Consumers signal demand** - Each subscriber tells the producer how many events it wants
2. **Producer buffers events** - Events are queued until there's demand
3. **Automatic flow control** - If consumers are slow, producer pauses automatically
4. **No message loss** - Events are never dropped, only buffered

**Example with slow consumer:**

```elixir
{:ok, subscription} = Concord.EventStream.subscribe(
  max_demand: 10  # Process 10 events at a time
)

# This subscriber will only receive 10 events at once
# GenStage automatically manages the flow
```

### Performance Characteristics

- **Event emission:** < 100μs overhead per operation
- **Filtering:** Regex matching adds ~50μs per event
- **Memory:** ~200 bytes per queued event
- **Throughput:** Supports 100K+ events/second with multiple subscribers

### Best Practices

**1. Use specific filters to reduce load:**

```elixir
# Bad: Subscribe to everything when you only need user events
{:ok, sub} = Concord.EventStream.subscribe()

# Good: Filter at subscription time
{:ok, sub} = Concord.EventStream.subscribe(key_pattern: ~r/^user:/)
```

**2. Handle events asynchronously:**

```elixir
{:ok, subscription} = Concord.EventStream.subscribe()

# Process events in separate task to avoid blocking
Task.start(fn ->
  Stream.repeatedly(fn ->
    receive do
      {:concord_event, event} -> event
    after
      5000 -> nil
    end
  end)
  |> Stream.reject(&is_nil/1)
  |> Stream.each(&process_event/1)
  |> Stream.run()
end)
```

**3. Monitor queue size:**

```elixir
# Set up periodic monitoring
:timer.send_interval(60_000, :check_event_queue)

receive do
  :check_event_queue ->
    stats = Concord.EventStream.stats()
    if stats.queue_size > 5000 do
      Logger.warn("Event stream queue growing: #{stats.queue_size}")
    end
end
```

**4. Clean up subscriptions:**

```elixir
# Always unsubscribe when done
on_exit(fn ->
  Concord.EventStream.unsubscribe(subscription)
end)
```

### Troubleshooting

**Events not being received:**

```elixir
# Check if event streaming is enabled
Concord.EventStream.enabled?()  # Should return true

# Check subscription is active
Process.alive?(subscription)  # Should return true

# Check event stream stats
Concord.EventStream.stats()
```

**High memory usage:**

```elixir
# Check queue size
stats = Concord.EventStream.stats()
IO.inspect(stats.queue_size)  # Should be < buffer_size

# If queue is full, consumers are too slow
# Either speed up consumers or increase max_demand
```

**Missing events:**

Events are only emitted after they're committed to the Raft log. If you subscribe after an operation, you won't receive that event. Event streaming is **not a replay system** - it only streams new events from the time of subscription.

### Integration Examples

**Phoenix LiveView:**

```elixir
defmodule MyAppWeb.DashboardLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    if connected?(socket) do
      {:ok, subscription} = Concord.EventStream.subscribe(
        key_pattern: ~r/^dashboard:/
      )
      {:ok, assign(socket, subscription: subscription)}
    else
      {:ok, socket}
    end
  end

  def handle_info({:concord_event, %{type: :put, key: key, value: value}}, socket) do
    {:noreply, assign(socket, String.to_atom(key), value)}
  end

  def terminate(_reason, socket) do
    if subscription = socket.assigns[:subscription] do
      Concord.EventStream.unsubscribe(subscription)
    end
  end
end
```

**Broadway Integration:**

```elixir
defmodule MyApp.ConcordBroadway do
  use Broadway

  def start_link(_opts) do
    {:ok, subscription} = Concord.EventStream.subscribe()

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {MyApp.ConcordProducer, subscription: subscription}
      ],
      processors: [
        default: [concurrency: 10]
      ]
    )
  end

  def handle_message(_processor, message, _context) do
    %{type: type, key: key} = message.data
    process_change(type, key)
    message
  end
end
```

## Query Language

Concord provides a powerful query language for filtering and searching keys with pattern matching, range queries, and value-based filtering.

### Key Matching

```elixir
# Prefix matching
{:ok, keys} = Concord.Query.keys(prefix: "user:")
# => ["user:1", "user:2", "user:100"]

# Suffix matching
{:ok, keys} = Concord.Query.keys(suffix: ":admin")

# Contains substring
{:ok, keys} = Concord.Query.keys(contains: "2024-02")

# Regex pattern
{:ok, keys} = Concord.Query.keys(pattern: ~r/user:\d{3}/)
# => ["user:100"]
```

### Range Queries

```elixir
# Lexicographic range (inclusive)
{:ok, keys} = Concord.Query.keys(range: {"user:100", "user:200"})

# Date range queries
{:ok, keys} = Concord.Query.keys(range: {"order:2024-01-01", "order:2024-12-31"})
```

### Value Filtering

```elixir
# Get key-value pairs with filter
{:ok, pairs} = Concord.Query.where(
  prefix: "product:",
  filter: fn {_k, v} -> v.price > 100 end
)
# => [{"product:2", %{price: 150}}, {"product:3", %{price: 199}}]

# Complex predicates
{:ok, pairs} = Concord.Query.where(
  prefix: "user:",
  filter: fn {_k, v} -> v.age >= 30 and v.role == "admin" end
)
```

### Pagination

```elixir
# Limit results
{:ok, keys} = Concord.Query.keys(prefix: "user:", limit: 50)

# Skip and limit
{:ok, keys} = Concord.Query.keys(prefix: "user:", offset: 100, limit: 50)
```

### Count and Delete

```elixir
# Count matching keys
{:ok, count} = Concord.Query.count(prefix: "temp:")
# => {:ok, 42}

# Delete all matching keys
{:ok, deleted_count} = Concord.Query.delete_where(prefix: "temp:")
# => {:ok, 42}

# Delete with range
{:ok, count} = Concord.Query.delete_where(range: {"old:2020-01-01", "old:2020-12-31"})
```

### Combined Filters

```elixir
# Multiple filters are ANDed together
{:ok, keys} = Concord.Query.keys(
  prefix: "user:",
  pattern: ~r/\d{3}/,
  limit: 10
)
```

## Conditional Updates

Concord provides atomic conditional update operations for implementing advanced patterns like compare-and-swap (CAS), distributed locks, and optimistic concurrency control.

### Compare-and-Swap with Expected Value

Update or delete a key only if its current value matches an expected value:

```elixir
# Initialize counter
:ok = Concord.put("counter", 0)

# Read current value
{:ok, current} = Concord.get("counter")

# Update only if value hasn't changed (CAS operation)
case Concord.put_if("counter", current + 1, expected: current) do
  :ok ->
    # Successfully incremented
    IO.puts("Counter updated to #{current + 1}")

  {:error, :condition_failed} ->
    # Value changed by another process, retry
    IO.puts("Conflict detected, retrying...")

  {:error, :not_found} ->
    # Key was deleted or expired
    IO.puts("Key no longer exists")
end

# Conditional delete
:ok = Concord.put("session", "user-123")
:ok = Concord.delete_if("session", expected: "user-123")  # Only deletes if value matches
```

### Predicate-Based Conditions

Use custom functions for complex conditional logic:

```elixir
# Version-based updates (optimistic locking)
:ok = Concord.put("config", %{version: 1, settings: %{enabled: true}})

new_config = %{version: 2, settings: %{enabled: false}}

:ok = Concord.put_if(
  "config",
  new_config,
  condition: fn current -> current.version < new_config.version end
)

# Conditional delete based on age
:ok = Concord.put("temp_file", %{created_at: ~U[2024-01-01 00:00:00Z], size: 100})

cutoff = ~U[2025-01-01 00:00:00Z]
:ok = Concord.delete_if(
  "temp_file",
  condition: fn file -> DateTime.compare(file.created_at, cutoff) == :lt end
)

# Price threshold updates
:ok = Concord.put("product", %{price: 100, discount: 0})

:ok = Concord.put_if(
  "product",
  %{price: 80, discount: 20},
  condition: fn p -> p.price >= 80 end
)
```

### Distributed Lock Implementation

```elixir
defmodule DistributedLock do
  @lock_key "my_critical_resource"
  @lock_ttl 30  # seconds

  def acquire(owner_id) do
    # Try to create lock with owner ID
    # If key already exists, this will fail
    case Concord.get(@lock_key) do
      {:error, :not_found} ->
        # Lock is free, try to acquire
        Concord.put(@lock_key, owner_id, ttl: @lock_ttl)
        {:ok, :acquired}

      {:ok, ^owner_id} ->
        # We already own the lock
        {:ok, :already_owned}

      {:ok, _other_owner} ->
        {:error, :locked}
    end
  end

  def release(owner_id) do
    # Only release if we own the lock
    case Concord.delete_if(@lock_key, expected: owner_id) do
      :ok -> {:ok, :released}
      {:error, :condition_failed} -> {:error, :not_owner}
      {:error, :not_found} -> {:error, :not_locked}
    end
  end

  def with_lock(owner_id, fun) do
    case acquire(owner_id) do
      {:ok, _} ->
        try do
          fun.()
        after
          release(owner_id)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end

# Usage
DistributedLock.with_lock("process-1", fn ->
  # Critical section - only one process can execute this at a time
  IO.puts("Processing critical operation...")
end)
```

### Optimistic Concurrency Control

```elixir
defmodule BankAccount do
  def transfer(from_account, to_account, amount) do
    # Read current balances
    {:ok, from_balance} = Concord.get(from_account)
    {:ok, to_balance} = Concord.get(to_account)

    # Check sufficient funds
    if from_balance >= amount do
      # Attempt atomic transfer using CAS
      with :ok <- Concord.put_if(from_account, from_balance - amount, expected: from_balance),
           :ok <- Concord.put_if(to_account, to_balance + amount, expected: to_balance) do
        {:ok, :transferred}
      else
        {:error, :condition_failed} ->
          # Concurrent modification detected, retry
          transfer(from_account, to_account, amount)

        error ->
          error
      end
    else
      {:error, :insufficient_funds}
    end
  end
end
```

### API Options

Both `put_if/3` and `delete_if/2` support these options:

**Condition Options** (required, mutually exclusive):
- `:expected` - Exact value to match (uses `==` comparison)
- `:condition` - Function that receives current value and returns boolean

**Additional Options** (for `put_if/3` only):
- `:ttl` - TTL in seconds for the new value if condition succeeds
- `:timeout` - Operation timeout in milliseconds (default: 5000)

**Return Values:**
- `:ok` - Condition met, operation succeeded
- `{:error, :condition_failed}` - Current value doesn't match condition
- `{:error, :not_found}` - Key doesn't exist or has expired
- `{:error, :missing_condition}` - Neither `:expected` nor `:condition` provided
- `{:error, :conflicting_conditions}` - Both `:expected` and `:condition` provided
- `{:error, :invalid_key}` - Invalid key format
- `{:error, :timeout}` - Operation timed out
- `{:error, :cluster_not_ready}` - Cluster not initialized

### TTL Interaction

Conditional operations correctly handle expired keys:

```elixir
# Set key with short TTL
:ok = Concord.put("temp", "value", ttl: 1)

# Wait for expiration
Process.sleep(2000)

# Conditional operations fail on expired keys
{:error, :not_found} = Concord.put_if("temp", "new", expected: "value")
{:error, :not_found} = Concord.delete_if("temp", expected: "value")
```

### Use Cases

**1. Rate Limiting**
```elixir
def check_rate_limit(user_id, max_requests) do
  key = "rate_limit:#{user_id}"

  case Concord.get(key) do
    {:ok, count} when count >= max_requests ->
      {:error, :rate_limited}

    {:ok, count} ->
      # Increment if value hasn't changed
      case Concord.put_if(key, count + 1, expected: count, ttl: 60) do
        :ok -> {:ok, :allowed}
        {:error, :condition_failed} -> check_rate_limit(user_id, max_requests)
      end

    {:error, :not_found} ->
      Concord.put(key, 1, ttl: 60)
      {:ok, :allowed}
  end
end
```

**2. Leader Election**
```elixir
def elect_leader(node_id) do
  case Concord.get("cluster_leader") do
    {:error, :not_found} ->
      # No leader, try to become leader
      Concord.put("cluster_leader", node_id, ttl: 30)

    {:ok, ^node_id} ->
      # Already leader, extend lease
      Concord.put("cluster_leader", node_id, ttl: 30)

    {:ok, _other_node} ->
      # Another node is leader
      {:error, :not_leader}
  end
end
```

**3. Cache Invalidation**
```elixir
def update_with_version(key, new_value) do
  case Concord.get(key) do
    {:ok, %{version: v, data: _}} ->
      new_versioned = %{version: v + 1, data: new_value}
      Concord.put_if(
        key,
        new_versioned,
        condition: fn current -> current.version == v end
      )

    {:error, :not_found} ->
      Concord.put(key, %{version: 1, data: new_value})
  end
end
```

## Value Compression

Concord includes automatic value compression to reduce memory usage and improve performance for large datasets.

### Quick Start

**Compression is enabled by default** with these settings:

```elixir
# config/config.exs
config :concord,
  compression: [
    enabled: true,           # Enable automatic compression
    algorithm: :zlib,        # :zlib or :gzip
    threshold_bytes: 1024,   # Compress values larger than 1KB
    level: 6                 # Compression level 0-9 (0=none, 9=max)
  ]
```

**Compression is completely transparent:**

```elixir
# Store large value - automatically compressed if > 1KB
large_data = String.duplicate("x", 10_000)
Concord.put("large_key", large_data)
# Stored as {:compressed, :zlib, <<...>>} internally

# Retrieve - automatically decompressed
{:ok, value} = Concord.get("large_key")
# Returns original uncompressed value
```

### Configuration Options

**Algorithm Selection:**

```elixir
# Use zlib (default, faster)
config :concord,
  compression: [algorithm: :zlib]

# Use gzip (better compression ratio)
config :concord,
  compression: [algorithm: :gzip]
```

**Compression Level:**

```elixir
# Fast compression (lower CPU, less compression)
config :concord,
  compression: [level: 1]

# Balanced (default)
config :concord,
  compression: [level: 6]

# Maximum compression (higher CPU, best compression)
config :concord,
  compression: [level: 9]
```

**Size Threshold:**

```elixir
# Only compress values larger than 5KB
config :concord,
  compression: [threshold_bytes: 5120]

# Compress all values
config :concord,
  compression: [threshold_bytes: 0]
```

### Force Compression

Override automatic thresholds for specific operations:

```elixir
# Force compression regardless of size
Concord.put("small_key", "small value", compress: true)

# Disable compression for this operation
Concord.put("large_key", large_value, compress: false)
```

### Compression Statistics

Monitor compression effectiveness:

```elixir
# Get compression stats for a value
large_data = String.duplicate("x", 10_000)
stats = Concord.Compression.stats(large_data)

# Example output:
%{
  original_size: 10_047,
  compressed_size: 67,
  compression_ratio: 0.67,      # Percent of original size
  savings_bytes: 9_980,
  savings_percent: 99.33        # Space saved
}
```

### Programmatic API

Use compression functions directly:

```elixir
# Manual compression
compressed = Concord.Compression.compress("large data...")
# {:compressed, :zlib, <<...>>}

# Manual decompression
value = Concord.Compression.decompress(compressed)
# "large data..."

# Check if value should be compressed
Concord.Compression.should_compress?("small")  # false
Concord.Compression.should_compress?(large_data)  # true

# Get configuration
Concord.Compression.config()
# [enabled: true, algorithm: :zlib, threshold_bytes: 1024, level: 6]
```

### Performance Characteristics

| Value Size | Compression Ratio | Overhead | Recommended |
|------------|------------------|----------|-------------|
| < 1KB | N/A | None | No compression (default) |
| 1-10KB | 60-90% | Minimal | Yes (default threshold) |
| 10-100KB | 70-95% | Small | Yes |
| > 100KB | 80-98% | Moderate | Yes, consider level tuning |

**Compression Trade-offs:**

- **CPU**: ~5-15% overhead during put/get operations
- **Memory**: 60-98% reduction in storage size
- **Latency**: ~0.1-1ms additional latency
- **Throughput**: Minimal impact for values > 10KB

### Best Practices

1. **Enable for Large Values**: Keep default threshold at 1KB
2. **Monitor**: Use stats API to track compression effectiveness
3. **Tune Level**: Start at level 6, increase for storage-constrained systems
4. **Disable for Small Values**: Compression adds overhead for < 1KB values
5. **Test Your Data**: Compression effectiveness varies by data type

### Use Cases

**Perfect for:**
- Large JSON payloads (API responses, configs)
- Text data (logs, documents, HTML)
- Serialized data structures

**Avoid for:**
- Already compressed data (images, videos, archives)
- Small values (< 1KB)
- Real-time critical paths (microsecond requirements)

### Disable Compression

If you don't need compression:

```elixir
# config/config.exs
config :concord,
  compression: [enabled: false]
```

## API Reference

### Core Operations

```elixir
# Put a value
Concord.put(key, value, opts \\ [])
# Options: :timeout, :token

# Get a value
Concord.get(key, opts \\ [])
# Returns: {:ok, value} | {:error, :not_found} | {:error, reason}

# Delete a value
Concord.delete(key, opts \\ [])
# Returns: :ok | {:error, reason}

# Get all entries (use sparingly!)
Concord.get_all(opts \\ [])
# Returns: {:ok, map} | {:error, reason}

# Cluster status
Concord.status(opts \\ [])
# Returns: {:ok, %{cluster: ..., storage: ..., node: ...}}

# Cluster members
Concord.members()
# Returns: {:ok, [member_ids]}
```

### Error Types

```elixir
:timeout              # Operation timed out
:unauthorized         # Invalid or missing auth token
:cluster_not_ready    # Cluster not initialized
:invalid_key          # Key validation failed
:not_found           # Key doesn't exist
:noproc              # Ra process not running
```

## Configuration

### Development (config/dev.exs)

```elixir
import Config

config :concord,
  data_dir: "./data/dev",
  auth_enabled: false

config :logger, level: :debug
```

### Production (config/prod.exs)

```elixir
import Config

config :concord,
  data_dir: System.get_env("CONCORD_DATA_DIR", "/var/lib/concord"),
  auth_enabled: true

config :logger, level: :info

# Use environment variables for secrets
config :concord,
  cluster_cookie: System.fetch_env!("CONCORD_COOKIE")
```

## Testing

```bash
# Run all tests
mix test

# Run specific test file
mix test test/concord_test.exs

# Run with coverage
mix test --cover
```

### Test Categories

- **Unit Tests**: Basic CRUD operations, validation
- **Auth Tests**: Token management, authorization
- **Telemetry Tests**: Event emission verification
- **Integration Tests**: Multi-operation workflows

## Architecture

### Components

```
┌─────────────────────────────────────────────┐
│         Concord.Application                 │
│  ┌────────────┐  ┌──────────────────────┐  │
│  │ libcluster │  │ Telemetry.Poller     │  │
│  │  (Gossip)  │  │ (10s interval)       │  │
│  └────────────┘  └──────────────────────┘  │
│  ┌────────────┐  ┌──────────────────────┐  │
│  │ Auth Store │  │ Ra Cluster           │  │
│  │   (ETS)    │  │ (Raft Consensus)     │  │
│  └────────────┘  └──────────────────────┘  │
└─────────────────────────────────────────────┘
                     │
                     ▼
         ┌───────────────────────┐
         │ Concord.StateMachine  │
         │  - ETS storage        │
         │  - Apply commands     │
         │  - Handle queries     │
         │  - Snapshots          │
         └───────────────────────┘
```

### Data Flow

**Write Operation:**
1. Client calls `Concord.put/2`
2. Auth verification (if enabled)
3. Key validation
4. Command sent to Raft leader
5. Leader replicates to quorum
6. Command applied to state machine
7. ETS table updated
8. Telemetry event emitted
9. Success returned to client

**Read Operation:**
1. Client calls `Concord.get/1`
2. Auth verification (if enabled)
3. Query sent to leader
4. Direct ETS lookup (no log entry)
5. Telemetry event emitted
6. Result returned to client

## 📊 Performance & Benchmarks

### Embedded Database Performance (Single Node)

Concord delivers **exceptional performance** as an embedded database:

| Operation | Performance | Latency | Ideal Use Case |
|-----------|------------|---------|-------------|
| **Small Values (100B)** | **621K-870K ops/sec** | 1.15-1.61μs | Configuration, counters |
| **Medium Values (1KB)** | **134K-151K ops/sec** | 6.61-7.45μs | User sessions, API responses |
| **Large Values (10KB)** | **16K ops/sec** | 62-63μs | Large documents, cached files |
| **TTL Operations** | **943K-25M ops/sec** | 0.04-1.06μs | Session management |
| **Delete Operations** | **901K ops/sec** | 1.11μs | Temporary data cleanup |
| **HTTP Health Checks** | **5K req/sec** | 197μs | Monitoring |

### HTTP API Performance

| Endpoint | Performance | Latency | Notes |
|----------|------------|---------|-------|
| Health Check | **5K req/sec** | 197μs | Load balancer health checks |
| OpenAPI Spec | **2.3K req/sec** | 437μs | Large JSON response (~8KB) |
| Swagger UI | **~2K req/sec** | ~500μs | Interactive documentation |

### Memory Efficiency

| Data Volume | Memory Overhead | Lookup Speed |
|-------------|----------------|--------------|
| 100 items (~10KB) | ~821 bytes | **12M lookups/sec** |
| 1,000 items (~100KB) | **50 bytes/item** | 878K lookups/sec |
| 5,000 items (~500KB) | **10 bytes/item** | 850K lookups/sec |

### Embedded Application Scenarios

| Scenario | Performance | Latency | Real-World Application |
|----------|------------|---------|---------------------|
| User Session Store | **439K ops/sec** | 2.28μs | Phoenix session management |
| Rate Limiting | **Variable** | - | Failed due to cluster issues |
| Feature Flag Lookup | **Failed** | - | Cluster not ready errors |
| API Response Caching | **1.1M ops/sec** | 0.9μs | Response caching layer |
| Distributed Locking | **901K ops/sec** | 1.11μs | Resource coordination |

### Performance Optimization Tips

```elixir
# 1. Use direct Concord API for best performance
Concord.put("config:feature", enabled)  # 870K ops/sec
# vs HTTP API: ~5K ops/sec

# 2. Batch operations when possible
values = [{"key1", "val1"}, {"key2", "val2"}]
Enum.each(values, fn {k, v} -> Concord.put(k, v) end)

# 3. Monitor and tune timeouts based on network latency
Concord.put("key", "value", timeout: 5000)  # 5s for high-latency networks

# 4. Pre-warm the cluster with common data at startup
```

### Running Performance Benchmarks

Concord includes comprehensive performance testing tools:

```bash
# Run embedded database benchmarks
mix run run_benchmarks.exs

# View performance analysis
cat PERFORMANCE_ANALYSIS.md

# See performance summary
cat PERFORMANCE_SUMMARY.md
```

**Key Findings from Performance Testing:**
- ✅ **600K-870K ops/sec** for typical embedded use cases
- ✅ **Microsecond-level latency** suitable for real-time applications
- ✅ **Memory efficient** at ~10 bytes per stored item
- ✅ **Excellent TTL performance** for session management
- ✅ **HTTP API adequate** for management operations

### When to Use Concord

| Use Case | Recommendation | Reason |
|---------|----------------|--------|
| **Phoenix Session Storage** | ✅ Excellent | 439K ops/sec with TTL support |
| **Feature Flag Systems** | ✅ Perfect | Fast lookups, real-time updates |
| **Distributed Caching** | ✅ Great | 1.1M ops/sec, automatic expiration |
| **Rate Limiting** | ✅ Good | Fast counting with TTL windows |
| **Configuration Management** | ✅ Ideal | Real-time updates across cluster |
| **Large Blob Storage** | ❌ Avoid | Use S3/MinIO instead |
| **Primary Database** | ❌ Avoid | Use PostgreSQL/MongoDB |
| **High-Frequency Writes** | ⚠️ Consider | Benchmark your specific use case |

## 🆚 Comparison with Alternatives

| Feature | Concord | etcd | Consul | ZooKeeper |
|---------|---------|------|--------|-----------|
| **Language** | Elixir | Go | Go | Java |
| **Consistency** | Strong (Raft) | Strong (Raft) | Strong (Raft) | Strong (Zab) |
| **Storage** | In-memory (ETS) | Disk (WAL) | Memory + Disk | Disk |
| **Write Latency** | 5-20ms | 10-50ms | 10-30ms | 10-100ms |
| **Read Latency** | 1-5ms | 5-20ms | 5-15ms | 5-20ms |
| **Built-in Auth** | ✅ Tokens | ✅ mTLS | ✅ ACLs | ✅ ACLs |
| **Multi-DC** | ❌ | ✅ | ✅ | ✅ |
| **Service Discovery** | Basic | ✅ | ✅ | ❌ |
| **Health Checking** | Basic | ✅ | ✅ | ✅ |
| **Key TTL** | ❌ | ✅ | ✅ | ✅ |
| **Complex Queries** | ❌ | ❌ | ✅ | ❌ |

### When to Choose Concord

✅ **Perfect for:**
- Microservices configuration management
- Feature flag systems
- Distributed locking and coordination
- Service discovery in single-region deployments
- Session storage for web applications
- Rate limiting counters

❌ **Consider alternatives when:**
- Need multi-datacenter replication
- Require persistent disk storage
- Need >10K writes/sec throughput
- Want automatic key expiration (TTL)
- Require complex query capabilities

## 🚀 Production Deployment

### Production Checklist

- [ ] **Resource Planning**: 2GB RAM minimum per node, 1-2 CPU cores
- [ ] **Network Setup**: Low-latency network between nodes (<10ms)
- [ ] **Security**: Firewall rules, VPN for external access
- [ ] **Monitoring**: Telemetry collection and alerting
- [ ] **Backup Strategy**: Automated data directory backups
- [ ] **High Availability**: Odd number of nodes (3 or 5)
- [ ] **Load Balancing**: Client-side leader routing or external LB

### Docker Deployment

**1. Build the image:**
```dockerfile
# Dockerfile
FROM elixir:1.15-alpine AS builder

WORKDIR /app
COPY mix.exs mix.lock ./
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only prod

COPY . .
RUN mix compile && \
    mix release --overwrite

FROM alpine:3.18
RUN apk add --no-cache openssl ncurses-libs
WORKDIR /app

COPY --from=builder /app/_build/prod/rel/concord ./
RUN chown -R nobody:nobody /app
USER nobody

EXPOSE 4000 4369 9000-10000
CMD ["bin/concord", "start"]
```

**2. Docker Compose for production:**
```yaml
version: '3.8'

services:
  concord1:
    image: concord:latest
    hostname: concord1
    environment:
      - NODE_NAME=concord1@concord1
      - COOKIE=${CLUSTER_COOKIE}
      - CONCORD_DATA_DIR=/data
      - CONCORD_AUTH_ENABLED=true
      - CONCORD_TELEMETRY_ENABLED=true
      - RELEASE_DISTRIBUTION=name
      - RELEASE_NODE=concord1@concord1
    volumes:
      - concord1_data:/data
      - ./logs:/app/logs
    networks:
      - concord-net
    deploy:
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 1G
    restart: unless-stopped

  concord2:
    image: concord:latest
    hostname: concord2
    environment:
      - NODE_NAME=concord2@concord2
      - COOKIE=${CLUSTER_COOKIE}
      - CONCORD_DATA_DIR=/data
      - CONCORD_AUTH_ENABLED=true
      - CONCORD_TELEMETRY_ENABLED=true
      - RELEASE_DISTRIBUTION=name
      - RELEASE_NODE=concord2@concord2
    volumes:
      - concord2_data:/data
      - ./logs:/app/logs
    networks:
      - concord-net
    deploy:
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 1G
    restart: unless-stopped

  concord3:
    image: concord:latest
    hostname: concord3
    environment:
      - NODE_NAME=concord3@concord3
      - COOKIE=${CLUSTER_COOKIE}
      - CONCORD_DATA_DIR=/data
      - CONCORD_AUTH_ENABLED=true
      - CONCORD_TELEMETRY_ENABLED=true
      - RELEASE_DISTRIBUTION=name
      - RELEASE_NODE=concord3@concord3
    volumes:
      - concord3_data:/data
      - ./logs:/app/logs
    networks:
      - concord-net
    deploy:
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 1G
    restart: unless-stopped

  # Optional: Monitoring with Prometheus
  prometheus:
    image: prom/prometheus:latest
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    networks:
      - concord-net

volumes:
  concord1_data:
  concord2_data:
  concord3_data:
  prometheus_data:

networks:
  concord-net:
    driver: bridge
```

**3. Environment file (.env):**
```bash
CLUSTER_COOKIE=your-super-secret-cluster-cookie-here
CONCORD_AUTH_TOKEN=sk_concord_production_token_here
```

### Kubernetes Deployment

**1. Secret management:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: concord-secrets
type: Opaque
stringData:
  cookie: "your-cluster-cookie"
  authToken: "sk_concord_production_token"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: concord-config
data:
  CONCORD_AUTH_ENABLED: "true"
  CONCORD_TELEMETRY_ENABLED: "true"
  CONCORD_DATA_DIR: "/data"
```

**2. StatefulSet for Concord cluster:**
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: concord
  labels:
    app: concord
spec:
  serviceName: concord-headless
  replicas: 3
  selector:
    matchLabels:
      app: concord
  template:
    metadata:
      labels:
        app: concord
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "4000"
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: concord
        image: concord:latest
        imagePullPolicy: Always
        ports:
        - name: http
          containerPort: 4000
          protocol: TCP
        - name: epmd
          containerPort: 4369
          protocol: TCP
        - name: dist
          containerPort: 9100
          protocol: TCP
        env:
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: NODE_NAME
          value: "concord-$(POD_NAME).concord-headless.default.svc.cluster.local"
        - name: COOKIE
          valueFrom:
            secretKeyRef:
              name: concord-secrets
              key: cookie
        - name: RELEASE_DISTRIBUTION
          value: "name"
        - name: RELEASE_NODE
          value: "$(NODE_NAME)"
        # Config from ConfigMap
        envFrom:
        - configMapRef:
            name: concord-config
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        volumeMounts:
        - name: data
          mountPath: /data
        - name: logs
          mountPath: /app/logs
        livenessProbe:
          httpGet:
            path: /health
            port: 4000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 4000
          initialDelaySeconds: 5
          periodSeconds: 5
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh", "-c", "sleep 15"]
      volumes:
      - name: logs
        emptyDir: {}
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: "fast-ssd"
      resources:
        requests:
          storage: "20Gi"
```

**3. Service definitions:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: concord-headless
  labels:
    app: concord
spec:
  ports:
  - port: 4000
    name: http
  - port: 4369
    name: epmd
  - port: 9100
    name: dist
  clusterIP: None
  selector:
    app: concord
---
apiVersion: v1
kind: Service
metadata:
  name: concord-client
  labels:
    app: concord
spec:
  ports:
  - port: 4000
    name: http
  selector:
    app: concord
  type: LoadBalancer
```

### Monitoring & Observability

**1. Prometheus configuration:**
```yaml
# prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'concord'
    static_configs:
      - targets: ['concord-client:4000']
    metrics_path: /metrics
    scrape_interval: 5s

  - job_name: 'concord-nodes'
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
            - default
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: concord-headless
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: http
```

**2. Grafana dashboard highlights:**
- Cluster health and leader election frequency
- Operation latency (P50, P95, P99)
- Throughput metrics (reads/writes per second)
- Memory usage and storage growth
- Error rates and authentication failures

### Security Hardening

**1. Network security:**
```yaml
# NetworkPolicy example
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: concord-netpol
spec:
  podSelector:
    matchLabels:
      app: concord
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: concord
    ports:
    - protocol: TCP
      port: 4000
    - protocol: TCP
      port: 4369
    - protocol: TCP
      port: 9100
  - from: []  # Allow monitoring
  egress:
  - to: []  # Allow all egress or restrict as needed
```

**2. RBAC for Kubernetes:**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: concord
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: concord-role
rules:
- apiGroups: [""]
  resources: ["configmaps", "secrets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: concord-binding
subjects:
- kind: ServiceAccount
  name: concord
roleRef:
  kind: Role
  name: concord-role
  apiGroup: rbac.authorization.k8s.io
```

### Backup & Recovery

**1. Automated backup script:**
```bash
#!/bin/bash
# backup-concord.sh

set -euo pipefail

BACKUP_DIR="/backup/concord"
DATA_DIR="/var/lib/concord"
DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="concord-backup-${DATE}"

# Create backup directory
mkdir -p "${BACKUP_DIR}"

# Create compressed backup
tar -czf "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" -C "${DATA_DIR}" .

# Upload to S3 (optional)
if command -v aws &> /dev/null; then
    aws s3 cp "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" "s3://your-backup-bucket/concord/${BACKUP_NAME}.tar.gz"
fi

# Clean up old backups (keep 7 days)
find "${BACKUP_DIR}" -name "concord-backup-*.tar.gz" -mtime +7 -delete

echo "Backup completed: ${BACKUP_NAME}"
```

**2. Recovery procedure:**
```bash
#!/bin/bash
# restore-concord.sh

set -euo pipefail

BACKUP_FILE=$1
DATA_DIR="/var/lib/concord"

if [ -z "$BACKUP_FILE" ]; then
    echo "Usage: $0 <backup-file>"
    exit 1
fi

# Stop Concord service
systemctl stop concord || docker-compose down

# Restore data
rm -rf "${DATA_DIR}"/*
tar -xzf "$BACKUP_FILE" -C "${DATA_DIR}"

# Fix permissions
chown -R concord:concord "${DATA_DIR}"

# Start service
systemctl start concord || docker-compose up -d

echo "Restore completed from: $BACKUP_FILE"
```

## Operational Best Practices

### Monitoring

1. **Watch for leader changes** - Frequent elections indicate instability
2. **Track commit latency** - High latency suggests network issues
3. **Monitor storage size** - Plan for snapshots and cleanup
4. **Alert on quorum loss** - Cluster becomes read-only

### Backup Strategy

```bash
# Raft logs and snapshots are in the data directory
# Back up regularly:
rsync -av /var/lib/concord/ /backup/concord-$(date +%Y%m%d)/

# Or use volume snapshots in cloud environments
```

### Adding Nodes

```elixir
# 1. Start new node with same cluster_name and cookie
# 2. libcluster will discover it automatically
# 3. Add to Raft cluster:
:ra.add_member({:concord_cluster, :existing_node@host}, {:concord_cluster, :new_node@host})
```

### Removing Nodes

```elixir
# Gracefully remove from cluster
:ra.remove_member({:concord_cluster, :leader@host}, {:concord_cluster, :old_node@host})

# Then stop the node
```

## ❓ Frequently Asked Questions

### General Questions

**Q: How is Concord different from Redis?**
A: Concord provides strong consistency through Raft consensus, while Redis is eventually consistent. Concord is designed for distributed coordination and configuration management, while Redis excels at caching and high-throughput operations.

**Q: Can I use Concord as a primary database?**
A: No. Concord is an in-memory store without persistence guarantees. It's ideal for coordination, configuration, and temporary data, but not for durable application data.

**Q: What happens when the leader node fails?**
A: The remaining nodes automatically elect a new leader. This typically takes 1-5 seconds, during which the cluster is unavailable for writes but reads may work depending on the consistency level.

### Operational Questions

**Q: How do I backup my data?**
A: Back up the data directory specified in your configuration. For production, consider automated snapshots:
```bash
# Create backup
rsync -av /var/lib/concord/ /backup/concord-$(date +%Y%m%d-%H%M%S)/

# Restore
rsync -av /backup/concord-20240115-143022/ /var/lib/concord/
```

**Q: How many nodes should I run?**
A: 3 nodes for development, 5 nodes for production. Odd numbers prevent split-brain scenarios. More than 7 nodes typically hurts performance due to increased coordination overhead.

**Q: Can I add nodes to a running cluster?**
A: Yes! New nodes with the same cluster name and cookie will automatically join via libcluster gossip. Then add them to the Raft cluster:
```elixir
:ra.add_member({:concord_cluster, :existing@host}, {:concord_cluster, :new@host})
```

### Performance Questions

**Q: Why are my writes slow?**
A: Common causes:
- High network latency between nodes
- Large value sizes (>1MB)
- Leader node under high CPU/memory pressure
- Network partitions or packet loss

**Q: How much memory do I need?**
A: Plan for 2-3x your data size due to ETS overhead and snapshots. Monitor with:
```elixir
{:ok, status} = Concord.status()
status.storage.memory  # Current memory usage in words
```

### Security Questions

**Q: How secure are the authentication tokens?**
A: Tokens are generated using cryptographically secure random numbers and stored in ETS. They should be treated like API keys - use HTTPS in production and rotate them regularly.

**Q: Can I run Concord on the public internet?**
A: Not recommended. Concord is designed for trusted networks. For internet access, use a VPN or place it behind a firewall with proper authentication.

### Development Questions

**Q: Why won't my cluster form in development?**
A: Check:
- All nodes use the same Erlang cookie
- Node names are resolvable (use IP addresses if unsure)
- No firewall blocking ports 4369 and 9100-9200
- Data directories exist and are writable

**Q: How do I reset a corrupted cluster?**
A: Stop all nodes, delete the data directory, and restart:
```bash
# On each node
pkill -f "beam.*concord"
rm -rf /var/lib/concord/*
iex --name node@host --cookie secret -S mix
```

## 🚨 Troubleshooting Guide

### Common Issues and Solutions

#### **Cluster won't form**
**Symptoms:** Nodes start but can't communicate, `mix concord.cluster status` shows single node

**Solutions:**
1. **Check Erlang cookie consistency:**
   ```bash
   # Should be identical on all nodes
   echo $ERL_COOKIE
   ```

2. **Verify network connectivity:**
   ```bash
   # Test node connectivity
   ping n2.example.com
   telnet n2.example.com 4369
   ```

3. **Check DNS resolution:**
   ```bash
   # Use IP addresses if DNS fails
   iex --name n1@192.168.1.10 --cookie secret -S mix
   ```

#### **Operations timing out**
**Symptoms:** `{:error, :timeout}` errors, slow responses

**Solutions:**
1. **Increase timeout for high-latency networks:**
   ```elixir
   Concord.put("key", "value", timeout: 10_000)
   ```

2. **Check cluster health:**
   ```elixir
   {:ok, status} = Concord.status()
   # Look for high commit_index or leader changes
   ```

3. **Monitor system resources:**
   ```bash
   top -p $(pgrep beam)
   iostat -x 1 5
   ```

#### **High memory usage**
**Symptoms:** OOM crashes, swapping, high memory reports

**Solutions:**
1. **Monitor memory usage:**
   ```elixir
   {:ok, status} = Concord.status()
   IO.inspect(status.storage)
   ```

2. **Implement manual cleanup:**
   ```elixir
   # Delete old/temporary data
   Concord.get_all()
   |> elem(1)
   |> Enum.filter(fn {k, _} -> String.starts_with?(k, "temp:") end)
   |> Enum.each(fn {k, _} -> Concord.delete(k) end)
   ```

3. **Trigger manual snapshots:**
   ```elixir
   :ra.trigger_snapshot({:concord_cluster, node()})
   ```

#### **Authentication failures**
**Symptoms:** `{:error, :unauthorized}` despite providing tokens

**Solutions:**
1. **Verify configuration:**
   ```elixir
   Application.get_env(:concord, :auth_enabled)
   ```

2. **Check token validity:**
   ```bash
   mix concord.cluster token revoke old_token
   mix concord.cluster token create
   ```

3. **Ensure token is passed correctly:**
   ```elixir
   # Wrong - missing token option
   Concord.get("key")

   # Correct - include token
   Concord.get("key", token: "your_token_here")
   ```

### Getting Help

- **Check logs:** `tail -f /var/log/concord/concord.log`
- **Cluster status:** `mix concord.cluster status`
- **Node connectivity:** `epmd -names`
- **Community:** [GitHub Discussions](https://github.com/your-org/concord/discussions)
- **Issues:** [GitHub Issues](https://github.com/your-org/concord/issues)

## 🎯 Use Case Guide

### ✅ Perfect Use Cases

| Use Case | Implementation | Data Size | Update Frequency |
|----------|----------------|-----------|------------------|
| **Feature Flags** | `flags:feature_name → enabled/disabled` | < 1MB | Medium |
| **Config Management** | `config:service:key → value` | < 10MB | Low |
| **Service Discovery** | `services:type:id → %{host, port, health}` | < 100MB | High |
| **Distributed Locks** | `locks:resource_id → node_id` | < 1MB | Very High |
| **Session Storage** | `session:user_id → session_data` | < 500MB | High |
| **Rate Limiting** | `rate:user_id:window → count` | < 10MB | Very High |

### ❌ Avoid These Use Cases

- **Large blob storage** (images, videos, large documents)
- **Primary application database** (user records, transactions)
- **Analytics data** (logs, metrics, events)
- **Cache for large datasets** (use Redis instead)
- **Message queue** (use RabbitMQ/Kafka instead)

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## License

MIT License - See LICENSE file for details

## Acknowledgments

- **ra** library by the RabbitMQ team
- **libcluster** for cluster management
- The Raft paper by Ongaro & Ousterhout
- The Elixir and Erlang communities
