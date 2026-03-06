# Observability

Concord provides comprehensive observability through telemetry events, Prometheus metrics, OpenTelemetry distributed tracing, audit logging, and real-time event streaming.

## Telemetry

Concord emits structured telemetry events for all operations.

### Available Events

```elixir
# API Operations
[:concord, :api, :put]         # Measurements: %{duration: integer}
[:concord, :api, :get]         # Metadata: %{result: :ok | :error}
[:concord, :api, :delete]

# Raft Operations
[:concord, :operation, :apply] # Metadata: %{operation: atom, key: any, index: integer}

# State Changes
[:concord, :state, :change]    # Metadata: %{status: atom, node: node()}

# Snapshots
[:concord, :snapshot, :created]   # Measurements: %{size: integer}
[:concord, :snapshot, :installed] # Metadata: %{node: node()}

# Cluster Health (periodic)
[:concord, :cluster, :status]  # Measurements: %{storage_size: integer, storage_memory: integer}
```

### Custom Metrics Handler

```elixir
defmodule MyApp.ConcordMetrics do
  def setup do
    events = [
      [:concord, :api, :put],
      [:concord, :api, :get],
      [:concord, :state, :change]
    ]

    :telemetry.attach_many("my-app-concord", events, &handle_event/4, nil)
  end

  def handle_event([:concord, :api, operation], %{duration: duration}, metadata, _) do
    MyMetrics.histogram("concord.#{operation}.duration", duration)
    MyMetrics.increment("concord.#{operation}.#{metadata.result}")
  end

  def handle_event([:concord, :state, :change], _, %{status: status, node: node}, _) do
    MyMetrics.gauge("concord.node.status", 1, tags: [node: node, status: status])
  end
end
```

## Prometheus

Built-in Prometheus metrics export for production monitoring.

### Configuration

```elixir
config :concord,
  prometheus_enabled: true,
  prometheus_port: 9568
```

### Access Metrics

```bash
curl http://localhost:9568/metrics
```

### Metrics Exposed

**API Operations:**
- `concord_api_put_duration_milliseconds` — PUT latency (summary)
- `concord_api_get_duration_milliseconds` — GET latency with consistency level
- `concord_api_delete_duration_milliseconds` — DELETE latency
- `concord_api_*_count_total` — Throughput counters

**Cluster Health:**
- `concord_cluster_size` — Total keys
- `concord_cluster_memory` — Memory usage in bytes
- `concord_cluster_member_count` — Cluster members
- `concord_cluster_commit_index` — Raft commit index
- `concord_cluster_is_leader` — Leader status (1/0)

**Raft Operations:**
- `concord_operation_apply_duration_milliseconds` — State machine latency
- `concord_operation_apply_count_total` — Operation count

**Snapshots:**
- `concord_snapshot_created_size` — Last snapshot size
- `concord_snapshot_installed_size` — Installed snapshot size

### Prometheus Scrape Config

```yaml
scrape_configs:
  - job_name: 'concord'
    static_configs:
      - targets: ['localhost:9568']
    scrape_interval: 15s
```

### Alert Examples

```yaml
groups:
  - name: concord
    rules:
      - alert: ConcordHighLatency
        expr: concord_api_get_duration_milliseconds{quantile="0.99"} > 100
        for: 5m
        labels:
          severity: warning

      - alert: ConcordNoLeader
        expr: sum(concord_cluster_is_leader) == 0
        for: 1m
        labels:
          severity: critical

      - alert: ConcordHighMemory
        expr: concord_cluster_memory > 1073741824
        for: 10m
        labels:
          severity: warning
```

## Distributed Tracing (OpenTelemetry)

Track requests across your cluster with OpenTelemetry.

### Configuration

```elixir
config :concord,
  tracing_enabled: true,
  tracing_exporter: :stdout  # :stdout, :otlp, or :none
```

```elixir
# Development — stdout
config :opentelemetry,
  traces_exporter: {:otel_exporter_stdout, []}

# Production — OTLP (Jaeger, Zipkin, etc.)
config :opentelemetry,
  traces_exporter: {:otel_exporter_otlp, %{endpoint: "http://localhost:4317"}}
```

### Automatic Tracing

All operations are automatically traced:

```elixir
Concord.put("user:123", %{name: "Alice"})
# Trace: concord.api.put with duration, result, TTL info

Concord.get("user:123")
# Trace: concord.api.get with duration, consistency level
```

### HTTP Trace Propagation

W3C Trace Context is automatically extracted and propagated:

```bash
curl -H "traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" \
     -H "Authorization: Bearer $TOKEN" \
     http://localhost:4000/api/v1/kv/mykey
```

### Manual Instrumentation

```elixir
require Concord.Tracing

Concord.Tracing.with_span "process_user_data", %{user_id: "123"} do
  Concord.Tracing.set_attribute(:cache_hit, true)
  Concord.Tracing.add_event("data_processed", %{rows: 100})
  result
end
```

### Trace Attributes

**HTTP:** `http.method`, `http.target`, `http.status_code`, `http.user_agent`, `net.peer.ip`

**Concord:** `concord.operation`, `concord.key`, `concord.consistency`, `concord.has_ttl`, `concord.result`

### Backend Integration

**Jaeger:**
```bash
docker run -d --name jaeger \
  -e COLLECTOR_OTLP_ENABLED=true \
  -p 4317:4317 -p 16686:16686 \
  jaegertracing/all-in-one:latest
```

```elixir
config :opentelemetry_exporter,
  otlp_protocol: :grpc,
  otlp_endpoint: "http://localhost:4317"
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

### Sampling

```elixir
# Sample 10% of traces
config :opentelemetry,
  sampler: {:parent_based, %{root: {:trace_id_ratio_based, 0.1}}}
```

### Performance Impact

- **CPU:** ~1-5% overhead
- **Memory:** ~100-500KB per active trace
- **Latency:** ~0.1-0.5ms per span

## Audit Logging

Immutable, append-only audit logs for compliance and security.

### Configuration

```elixir
config :concord,
  audit_log: [
    enabled: true,
    log_dir: "./audit_logs",
    rotation_size_mb: 100,
    retention_days: 90,
    log_reads: false,
    sensitive_keys: false
  ]
```

### Automatic Auditing

All write operations are automatically logged:

```elixir
Concord.put("user:123", %{name: "Alice"})
# Audit entry created with operation, timestamp, result
```

### Log Format

Each entry is a structured JSON object:

```json
{
  "timestamp": "2025-10-23T08:30:45.123456Z",
  "event_id": "550e8400-e29b-41d4-a716-446655440000",
  "operation": "put",
  "key_hash": "sha256:abc123def456...",
  "result": "ok",
  "user": "token:sk_concord_...",
  "node": "node1@127.0.0.1",
  "metadata": {"has_ttl": true, "ttl_seconds": 3600},
  "trace_id": "a1b2c3d4e5f6...",
  "span_id": "789012345678..."
}
```

### Querying

```elixir
{:ok, logs} = Concord.AuditLog.query(limit: 100)
{:ok, logs} = Concord.AuditLog.query(operation: "put", limit: 50)
{:ok, logs} = Concord.AuditLog.query(
  from: ~U[2025-10-23 00:00:00Z],
  to: ~U[2025-10-23 23:59:59Z]
)
{:ok, logs} = Concord.AuditLog.query(user: "token:sk_concord_abc...", limit: 50)
{:ok, logs} = Concord.AuditLog.query(result: :error, limit: 100)
```

### Exporting

```elixir
:ok = Concord.AuditLog.export("/backup/audit_export.jsonl")
:ok = Concord.AuditLog.export("/backup/errors.jsonl", result: :error)
```

### Rotation and Retention

```elixir
Concord.AuditLog.rotate()
Concord.AuditLog.cleanup()
Concord.AuditLog.stats()
# %{enabled: true, current_log_size: 45678912, total_size: 234567890}
```

### Compliance

**PCI-DSS:**
```elixir
config :concord, audit_log: [enabled: true, log_reads: true, retention_days: 90]
```

**HIPAA:**
```elixir
config :concord, audit_log: [enabled: true, log_reads: true, sensitive_keys: true, retention_days: 365]
```

**GDPR — Data subject access requests:**
```elixir
{:ok, logs} = Concord.AuditLog.query(user: "user_id", from: ~U[2024-01-01 00:00:00Z])
```

### SIEM Integration

**Splunk:**
```
[monitor://./audit_logs]
sourcetype = concord_audit
index = security
```

**Elasticsearch:**
```elixir
File.stream!("./audit_logs/audit_2025-10-23.jsonl")
|> Stream.map(&Jason.decode!/1)
|> Enum.each(fn log -> Elasticsearch.post("/concord-audit/_doc", log) end)
```

## Event Streaming (CDC)

Real-time Change Data Capture using GenStage for back-pressure.

### Configuration

```elixir
config :concord,
  event_stream: [
    enabled: true,
    buffer_size: 10_000
  ]
```

### Subscribing

```elixir
# Subscribe to all events
{:ok, subscription} = Concord.EventStream.subscribe()

# Filter by key pattern
{:ok, subscription} = Concord.EventStream.subscribe(key_pattern: ~r/^user:/)

# Filter by event type
{:ok, subscription} = Concord.EventStream.subscribe(event_types: [:delete, :delete_many])

# Combined filters
{:ok, subscription} = Concord.EventStream.subscribe(
  key_pattern: ~r/^product:/,
  event_types: [:put, :put_many]
)
```

### Event Format

**Single operations:**
```elixir
%{
  type: :put | :delete | :touch,
  key: "user:123",
  value: %{name: "Alice"},
  timestamp: ~U[2025-10-23 12:00:00Z],
  node: :node1@127.0.0.1,
  metadata: %{ttl: 3600}
}
```

**Bulk operations:**
```elixir
%{
  type: :put_many | :delete_many,
  keys: ["user:1", "user:2"],
  timestamp: ~U[2025-10-23 12:00:00Z],
  node: :node1@127.0.0.1,
  metadata: %{count: 2}
}
```

### Use Cases

**Cache invalidation:**
```elixir
{:ok, sub} = Concord.EventStream.subscribe()
receive do
  {:concord_event, %{type: type, key: key}} when type in [:put, :delete] ->
    MyApp.Cache.invalidate(key)
end
```

**Phoenix LiveView:**
```elixir
defmodule MyAppWeb.DashboardLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    if connected?(socket) do
      {:ok, sub} = Concord.EventStream.subscribe(key_pattern: ~r/^dashboard:/)
      {:ok, assign(socket, subscription: sub)}
    else
      {:ok, socket}
    end
  end

  def handle_info({:concord_event, %{type: :put, key: key, value: value}}, socket) do
    {:noreply, assign(socket, String.to_atom(key), value)}
  end

  def terminate(_reason, socket) do
    if sub = socket.assigns[:subscription], do: Concord.EventStream.unsubscribe(sub)
  end
end
```

**Phoenix PubSub bridge:**
```elixir
{:ok, sub} = Concord.EventStream.subscribe(key_pattern: ~r/^config:/)
receive do
  {:concord_event, %{type: :put, key: key, value: value}} ->
    Phoenix.PubSub.broadcast(MyApp.PubSub, "config_changes", {:config_updated, key, value})
end
```

### Monitoring

```elixir
Concord.EventStream.stats()
# %{enabled: true, queue_size: 42, pending_demand: 958, events_published: 1543}
```

### Performance

- Event emission: < 100us overhead per operation
- Filtering: ~50us per event (regex matching)
- Memory: ~200 bytes per queued event
- Throughput: 100K+ events/second
