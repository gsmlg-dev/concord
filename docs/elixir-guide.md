# Elixir API Guide

Complete guide to using Concord's Elixir API for read consistency, conditional updates, query language, and value compression.

## Read Consistency Levels

Concord supports configurable read consistency levels per operation, allowing you to balance performance and data freshness.

### Available Levels

**`:eventual` — Fastest, eventually consistent**

```elixir
Concord.get("user:123", consistency: :eventual)
```

Reads from any available node. May return slightly stale data. Best for high-throughput reads, dashboards, analytics, and cached data.

**`:leader` — Balanced (default)**

```elixir
Concord.get("user:123", consistency: :leader)
# Or simply:
Concord.get("user:123")
```

Reads from the leader node. Good balance between performance and freshness. Suitable for most application needs.

**`:strong` — Linearizable**

```elixir
Concord.get("user:123", consistency: :strong)
```

Reads from leader with heartbeat verification. Most up-to-date. Use for critical financial data, security-sensitive operations, and strict consistency requirements.

### Configuration

Set the default in `config/config.exs`:

```elixir
config :concord,
  default_read_consistency: :leader  # :eventual, :leader, or :strong
```

### All Read Operations Support Consistency

```elixir
Concord.get("key", consistency: :eventual)
Concord.get_many(["k1", "k2"], consistency: :strong)
Concord.get_with_ttl("key", consistency: :leader)
Concord.ttl("key", consistency: :eventual)
Concord.get_all(consistency: :strong)
Concord.get_all_with_ttl(consistency: :eventual)
Concord.status(consistency: :leader)
```

### Performance Characteristics

| Consistency | Latency | Staleness | Use Case |
|------------|---------|-----------|----------|
| `:eventual` | ~1-5ms | May be stale | High-throughput reads, analytics |
| `:leader` | ~5-10ms | Minimal | General application data |
| `:strong` | ~10-20ms | Zero | Critical operations |

### Read Load Balancing

With `:eventual` consistency, reads are automatically distributed across cluster members:

```elixir
1..1000 |> Enum.each(fn i ->
  Concord.get("metric:#{i}", consistency: :eventual)
end)
```

### Telemetry Integration

All read operations emit telemetry events with the consistency level:

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

## Conditional Updates (Compare-and-Swap)

Atomic conditional operations for CAS, distributed locks, and optimistic concurrency control.

### Compare-and-Swap with Expected Value

```elixir
# Initialize counter
:ok = Concord.put("counter", 0)

# Read current value
{:ok, current} = Concord.get("counter")

# Update only if value hasn't changed
case Concord.put_if("counter", current + 1, expected: current) do
  :ok -> IO.puts("Counter updated to #{current + 1}")
  {:error, :condition_failed} -> IO.puts("Conflict, retrying...")
  {:error, :not_found} -> IO.puts("Key no longer exists")
end

# Conditional delete
:ok = Concord.put("session", "user-123")
:ok = Concord.delete_if("session", expected: "user-123")
```

### Predicate-Based Conditions

```elixir
# Version-based updates (optimistic locking)
:ok = Concord.put("config", %{version: 1, settings: %{enabled: true}})

new_config = %{version: 2, settings: %{enabled: false}}
:ok = Concord.put_if("config", new_config,
  condition: fn current -> current.version < new_config.version end
)

# Conditional delete based on age
cutoff = ~U[2025-01-01 00:00:00Z]
:ok = Concord.delete_if("temp_file",
  condition: fn file -> DateTime.compare(file.created_at, cutoff) == :lt end
)
```

### Distributed Lock Pattern

```elixir
defmodule DistributedLock do
  @lock_key "my_critical_resource"
  @lock_ttl 30

  def acquire(owner_id) do
    case Concord.get(@lock_key) do
      {:error, :not_found} ->
        Concord.put(@lock_key, owner_id, ttl: @lock_ttl)
        {:ok, :acquired}
      {:ok, ^owner_id} ->
        {:ok, :already_owned}
      {:ok, _other} ->
        {:error, :locked}
    end
  end

  def release(owner_id) do
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
```

### Optimistic Concurrency Control

```elixir
defmodule BankAccount do
  def transfer(from_account, to_account, amount) do
    {:ok, from_balance} = Concord.get(from_account)
    {:ok, to_balance} = Concord.get(to_account)

    if from_balance >= amount do
      with :ok <- Concord.put_if(from_account, from_balance - amount, expected: from_balance),
           :ok <- Concord.put_if(to_account, to_balance + amount, expected: to_balance) do
        {:ok, :transferred}
      else
        {:error, :condition_failed} ->
          transfer(from_account, to_account, amount)  # Retry
        error -> error
      end
    else
      {:error, :insufficient_funds}
    end
  end
end
```

### API Options

**Condition options** (required, mutually exclusive):
- `:expected` — Exact value match (`==` comparison)
- `:condition` — Predicate function receiving current value

**Additional options** (for `put_if/3`):
- `:ttl` — TTL in seconds on success
- `:timeout` — Operation timeout in ms (default: 5000)

**Return values:**
- `:ok` — Condition met, operation succeeded
- `{:error, :condition_failed}` — Value doesn't match
- `{:error, :not_found}` — Key doesn't exist or expired
- `{:error, :missing_condition}` — No condition provided
- `{:error, :conflicting_conditions}` — Both `:expected` and `:condition` provided

### TTL Interaction

Conditional operations treat expired keys as not found:

```elixir
:ok = Concord.put("temp", "value", ttl: 1)
Process.sleep(2000)
{:error, :not_found} = Concord.put_if("temp", "new", expected: "value")
```

## Query Language

Pattern matching, range queries, and filtering for efficient data retrieval.

### Key Matching

```elixir
# Prefix matching
{:ok, keys} = Concord.Query.keys(prefix: "user:")

# Suffix matching
{:ok, keys} = Concord.Query.keys(suffix: ":admin")

# Contains substring
{:ok, keys} = Concord.Query.keys(contains: "2024-02")

# Regex pattern
{:ok, keys} = Concord.Query.keys(pattern: ~r/user:\d{3}/)
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
{:ok, pairs} = Concord.Query.where(
  prefix: "product:",
  filter: fn {_k, v} -> v.price > 100 end
)

{:ok, pairs} = Concord.Query.where(
  prefix: "user:",
  filter: fn {_k, v} -> v.age >= 30 and v.role == "admin" end
)
```

### Pagination

```elixir
{:ok, keys} = Concord.Query.keys(prefix: "user:", limit: 50)
{:ok, keys} = Concord.Query.keys(prefix: "user:", offset: 100, limit: 50)
```

### Count and Delete

```elixir
{:ok, count} = Concord.Query.count(prefix: "temp:")
{:ok, deleted_count} = Concord.Query.delete_where(prefix: "temp:")
{:ok, count} = Concord.Query.delete_where(range: {"old:2020-01-01", "old:2020-12-31"})
```

### Combined Filters

```elixir
{:ok, keys} = Concord.Query.keys(
  prefix: "user:",
  pattern: ~r/\d{3}/,
  limit: 10
)
```

## Value Compression

Automatic compression for large values to reduce memory usage.

### Configuration

Compression is **enabled by default**:

```elixir
config :concord,
  compression: [
    enabled: true,
    algorithm: :zlib,        # :zlib (faster) or :gzip (better ratio)
    threshold_bytes: 1024,   # Compress values > 1KB
    level: 6                 # 0-9 (0=none, 9=max)
  ]
```

### Transparent Operation

```elixir
# Large value — automatically compressed on put
large_data = String.duplicate("x", 10_000)
Concord.put("large_key", large_data)

# Automatically decompressed on get
{:ok, value} = Concord.get("large_key")
# Returns original uncompressed value
```

### Per-Operation Override

```elixir
# Force compression regardless of size
Concord.put("small_key", "small value", compress: true)

# Disable compression for this operation
Concord.put("large_key", large_value, compress: false)
```

### Compression Statistics

```elixir
stats = Concord.Compression.stats(large_data)
# %{
#   original_size: 10_047,
#   compressed_size: 67,
#   compression_ratio: 0.67,
#   savings_bytes: 9_980,
#   savings_percent: 99.33
# }
```

### Performance

| Value Size | Compression Ratio | Overhead |
|------------|------------------|----------|
| < 1KB | N/A | None (skipped) |
| 1-10KB | 60-90% | Minimal |
| 10-100KB | 70-95% | Small |
| > 100KB | 80-98% | Moderate |

**Trade-offs:** ~5-15% CPU overhead, 60-98% memory reduction, ~0.1-1ms added latency.

## API Reference

### Core Operations

```elixir
Concord.put(key, value, opts \\ [])
# Options: :timeout, :token, :ttl, :compress

Concord.get(key, opts \\ [])
# Returns: {:ok, value} | {:error, :not_found} | {:error, reason}
# Options: :timeout, :token, :consistency

Concord.delete(key, opts \\ [])
# Returns: :ok | {:error, reason}

Concord.get_all(opts \\ [])
# Returns: {:ok, map}

Concord.status(opts \\ [])
# Returns: {:ok, %{cluster: ..., storage: ..., node: ...}}

Concord.members()
# Returns: {:ok, [member_ids]}
```

### Batch Operations

```elixir
Concord.put_many([{key, value} | {key, value, ttl}], opts)
Concord.get_many([keys], opts)
Concord.delete_many([keys], opts)
Concord.touch_many([{key, ttl_seconds}], opts)
```

Max batch size: 500 items.

### TTL Operations

```elixir
Concord.put(key, value, ttl: seconds)
Concord.touch(key, additional_ttl_seconds, opts)
Concord.ttl(key, opts)
Concord.get_with_ttl(key, opts)
Concord.get_all_with_ttl(opts)
```

### Conditional Operations

```elixir
Concord.put_if(key, value, expected: current_value)
Concord.put_if(key, value, condition: fn current -> ... end)
Concord.delete_if(key, expected: current_value)
Concord.delete_if(key, condition: fn current -> ... end)
```

### Common Options

- `:timeout` — Operation timeout in ms (default: 5000)
- `:token` — Authentication token (required when auth enabled)
- `:consistency` — Read consistency (`:eventual`, `:leader`, `:strong`)
- `:ttl` — Time-to-live in seconds
- `:compress` — Override auto-compression (`true`/`false`)

### Error Types

```elixir
:timeout              # Operation timed out
:unauthorized         # Invalid or missing auth token
:cluster_not_ready    # Cluster not initialized
:invalid_key          # Key validation failed
:not_found            # Key doesn't exist
:noproc               # Ra process not running
:condition_failed     # Conditional update failed
```
