# Concord - Production-Ready Edition

A distributed, strongly-consistent key-value store built in Elixir using the Raft consensus algorithm.

## 🎯 Phase 3 Features (Now Included!)

### ✅ Telemetry & Observability
- Real-time metrics for all operations
- Cluster health monitoring
- Performance tracking (latency, throughput)
- State change notifications
- Snapshot creation/installation events

### ✅ Authentication & Authorization
- Token-based authentication
- Configurable per-environment
- Token creation and revocation
- Secure token generation using strong crypto

### ✅ Operational Tools
- `mix concord.cluster status` - View cluster health
- `mix concord.cluster members` - List all members
- `mix concord.cluster token create` - Generate auth tokens
- `mix concord.cluster token revoke` - Revoke tokens

### ✅ Enhanced Error Handling
- Granular error types (`:timeout`, `:unauthorized`, `:cluster_not_ready`, `:invalid_key`)
- Proper error propagation
- Key validation (size limits, format checks)

### ✅ Comprehensive Test Suite
- Unit tests for all operations
- Authentication tests
- Telemetry verification tests
- Edge case coverage
- Validation tests

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:concord, "~> 0.1.0"}
  ]
end
```

## Quick Start

### Basic Usage (No Auth)

```bash
# Start nodes
iex --name n1@127.0.0.1 --cookie secret -S mix
iex --name n2@127.0.0.1 --cookie secret -S mix
iex --name n3@127.0.0.1 --cookie secret -S mix

# In any node
Concord.put("user:1", %{name: "Alice", email: "alice@example.com"})
Concord.get("user:1")
# => {:ok, %{name: "Alice", email: "alice@example.com"}}

Concord.delete("user:1")
# => :ok
```

### Production Usage (With Auth)

```bash
# Enable auth in config/prod.exs
config :concord, auth_enabled: true

# Create a token
mix concord.cluster token create
# => Created token: aBc123XyZ...

# Use token in operations
Concord.put("secret", "value", token: "aBc123XyZ...")
Concord.get("secret", token: "aBc123XyZ...")
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

## Performance Characteristics

### Latency
- **Writes**: ~5-20ms (depends on network, quorum size)
- **Reads**: ~1-5ms (leader query)
- **Auth check**: ~0.1ms (ETS lookup)

### Throughput
- **Writes**: ~500-2000 ops/sec (single leader)
- **Reads**: ~10,000+ ops/sec (leader only)

### Scalability
- **Cluster size**: 3-7 nodes recommended
- **Storage**: Limited by available RAM (ETS)
- **Key size**: Max 1024 bytes
- **Value size**: No hard limit (but consider memory)

## Production Deployment

### Docker Compose Example

```yaml
version: '3.8'

services:
  concord1:
    image: your-concord-image
    hostname: concord1
    environment:
      - NODE_NAME=concord1@concord1
      - COOKIE=super-secret-cookie
      - CONCORD_DATA_DIR=/data
      - CONCORD_AUTH_ENABLED=true
    volumes:
      - ./data/concord1:/data

  concord2:
    image: your-concord-image
    hostname: concord2
    environment:
      - NODE_NAME=concord2@concord2
      - COOKIE=super-secret-cookie
      - CONCORD_DATA_DIR=/data
      - CONCORD_AUTH_ENABLED=true
    volumes:
      - ./data/concord2:/data

  concord3:
    image: your-concord-image
    hostname: concord3
    environment:
      - NODE_NAME=concord3@concord3
      - COOKIE=super-secret-cookie
      - CONCORD_DATA_DIR=/data
      - CONCORD_AUTH_ENABLED=true
    volumes:
      - ./data/concord3:/data
```

### Kubernetes Example

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: concord
spec:
  serviceName: concord
  replicas: 3
  selector:
    matchLabels:
      app: concord
  template:
    metadata:
      labels:
        app: concord
    spec:
      containers:
      - name: concord
        image: your-concord-image
        env:
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: NODE_NAME
          value: "concord@$(POD_IP)"
        - name: COOKIE
          valueFrom:
            secretKeyRef:
              name: concord-secret
              key: cookie
        volumeMounts:
        - name: data
          mountPath: /data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 10Gi
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

## Troubleshooting

### Cluster won't start
- Check Erlang cookie matches across nodes
- Verify network connectivity between nodes
- Check data directory permissions
- Look for port conflicts (Erlang distribution uses ports 4369, 9100-9200 by default)

### Operations timing out
- Check network latency between nodes
- Verify quorum is available (majority of nodes up)
- Check system resources (CPU, memory, disk I/O)
- Review Raft logs for errors

### High memory usage
- Monitor ETS table size via `Concord.status/0`
- Consider implementing TTL/expiration
- Trigger manual snapshots
- Reduce stored value sizes

### Authentication issues
- Verify `auth_enabled` is set correctly
- Check token hasn't been revoked
- Ensure token is passed in all requests

## Limitations & Trade-offs

### Current Limitations
- **Single leader writes**: All writes go through one node
- **In-memory only**: Data must fit in RAM
- **No sharding**: Single keyspace
- **No TTL**: Keys don't expire automatically
- **CP system**: Prioritizes consistency over availability

### When NOT to use Concord
- ❌ Need multi-datacenter replication
- ❌ Dataset larger than available RAM
- ❌ Require >10K writes/sec
- ❌ Need AP (available + partition-tolerant) guarantees
- ❌ Complex queries (use a real database)

### When TO use Concord
- ✅ Configuration management
- ✅ Feature flags
- ✅ Service discovery
- ✅ Distributed locks
- ✅ Session storage
- ✅ Rate limiting counters
- ✅ Small-to-medium datasets (<10GB)

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
