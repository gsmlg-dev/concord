# Observability

Concord emits structured telemetry events for all operations. Host applications can attach handlers for metrics, tracing, and alerting using the standard `:telemetry` library.

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
