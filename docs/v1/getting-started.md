# Getting Started

## Installation

Add Concord to your `mix.exs`:

```elixir
def deps do
  [
    {:concord, "~> 0.1.0"}
  ]
end
```

## Quick Start — Embedded Database

Concord starts automatically with your application. No separate infrastructure needed.

```elixir
# Store data
Concord.put("user:1001", %{name: "Alice", role: "admin"})
#=> :ok

# Retrieve data
Concord.get("user:1001")
#=> {:ok, %{name: "Alice", role: "admin"}}

# Store with TTL (auto-expires after 1 hour)
Concord.put("feature:dark_mode", "enabled", ttl: 3600)

# Get value with remaining TTL
Concord.get_with_ttl("feature:dark_mode")
#=> {:ok, {"enabled", 3595}}

# Delete
Concord.delete("user:1001")
#=> :ok
```

## Quick Start — HTTP API

**1. Start the HTTP API server:**

```bash
# Development mode (auth disabled)
iex -S mix

# With HTTP API enabled (see config/dev.exs)
CONCORD_API_PORT=4000 iex -S mix
```

**2. Use the REST API:**

```bash
# Health check
curl http://localhost:4000/api/v1/health

# Store data
curl -X PUT \
  -H "Content-Type: application/json" \
  -d '{"value": "Hello, World!"}' \
  http://localhost:4000/api/v1/kv/greeting

# Retrieve data
curl http://localhost:4000/api/v1/kv/greeting

# Interactive Swagger UI
open http://localhost:4000/api/docs
```

See [HTTP API Guide](API_USAGE_EXAMPLES.md) for full examples including authentication.

## Multi-Node Cluster

```bash
# Terminal 1
iex --name n1@127.0.0.1 --cookie concord -S mix

# Terminal 2
iex --name n2@127.0.0.1 --cookie concord -S mix

# Terminal 3
iex --name n3@127.0.0.1 --cookie concord -S mix
```

Nodes discover each other automatically via libcluster gossip.

## Authentication

Authentication is disabled in dev and enabled in prod by default.

```elixir
# config/prod.exs
config :concord,
  auth_enabled: true
```

```bash
# Create a token
mix concord.cluster token create
# => Created token: sk_concord_abc123def456...

# Revoke when needed
mix concord.cluster token revoke sk_concord_abc123def456...
```

```elixir
# Use tokens in code
token = System.fetch_env!("CONCORD_TOKEN")
Concord.put("config:api_rate_limit", 1000, token: token)
Concord.get("config:api_rate_limit", token: token)
```

## Common Use Cases

### Feature Flags

```elixir
Concord.put("flags:new_dashboard", "enabled")

if Concord.get("flags:new_dashboard") == {:ok, "enabled"} do
  render_new_dashboard()
end
```

### Session Storage

```elixir
# Store session with 30-minute TTL
Concord.put("session:#{session_id}", session_data, ttl: 1800)

# Retrieve session
Concord.get_with_ttl("session:#{session_id}")
#=> {:ok, {%{user_id: 123, ...}, 1755}}

# Extend session on activity
Concord.touch("session:#{session_id}", 1800)
```

### Rate Limiting

```elixir
user_key = "rate_limit:#{user_id}:#{Date.utc_today()}"
case Concord.get(user_key) do
  {:ok, count} when count < 1000 ->
    Concord.put(user_key, count + 1, ttl: 86400)
    :allow
  _ -> :deny
end
```

### Service Discovery

```elixir
Concord.put("services:web:1", %{
  host: "10.0.1.100",
  port: 8080,
  health: "healthy"
})

{:ok, all} = Concord.get_all()
healthy = all
  |> Enum.filter(fn {k, _} -> String.starts_with?(k, "services:web:") end)
  |> Enum.filter(fn {_, v} -> v.health == "healthy" end)
```

### Distributed Locks

```elixir
case Concord.put("locks:job:123", "node:worker1", timeout: 5000) do
  :ok ->
    # Do work
    Concord.delete("locks:job:123")
  {:error, :timeout} ->
    # Lock already held
end
```

## Management Commands

```bash
# Check cluster health
mix concord.cluster status

# List cluster members
mix concord.cluster members

# Create authentication token
mix concord.cluster token create

# Revoke a token
mix concord.cluster token revoke <token>
```

## HTTP API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| PUT | `/api/v1/kv/:key` | Store key-value pair |
| GET | `/api/v1/kv/:key` | Retrieve value |
| DELETE | `/api/v1/kv/:key` | Delete key |
| POST | `/api/v1/kv/:key/touch` | Extend TTL |
| GET | `/api/v1/kv/:key/ttl` | Get remaining TTL |
| POST | `/api/v1/kv/bulk` | Bulk store (up to 500) |
| POST | `/api/v1/kv/bulk/get` | Bulk retrieve |
| POST | `/api/v1/kv/bulk/delete` | Bulk delete |
| POST | `/api/v1/kv/bulk/touch` | Bulk TTL extend |
| GET | `/api/v1/kv` | List all keys |
| GET | `/api/v1/status` | Cluster status |
| GET | `/api/v1/health` | Health check |
| GET | `/api/v1/openapi.json` | OpenAPI spec |
| GET | `/api/docs` | Swagger UI |

## Next Steps

- [Elixir API Guide](elixir-guide.md) — Read consistency, conditional updates, queries, compression
- [HTTP API Reference](API_DESIGN.md) — Full HTTP endpoint documentation
- [HTTP API Examples](API_USAGE_EXAMPLES.md) — curl examples
- [Observability](observability.md) — Telemetry, Prometheus, tracing, audit logging
- [Backup & Restore](backup-restore.md) — Data safety and disaster recovery
- [Configuration](configuration.md) — All configuration options
- [Production Deployment](deployment.md) — Docker, Kubernetes, security hardening
