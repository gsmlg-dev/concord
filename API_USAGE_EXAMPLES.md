# Concord HTTP API Usage Examples

This document provides practical examples of using the Concord HTTP API with curl commands. Make sure the Concord server is running before trying these examples.

## Starting Concord Server

```bash
# Development mode (port 4000) - auth disabled by default
mix start

# Production mode with custom port - auth enabled by default
CONCORD_API_PORT=8080 CONCORD_API_IP=0.0.0.0 mix start

# Development mode with custom port
CONCORD_API_PORT=4002 mix start
```

> **Note**: By default, authentication is disabled in development mode and enabled in production mode. You can enable it in development by setting `auth_enabled: true` in `config/config.exs`.

## Authentication

Concord API supports two authentication methods:

### 1. Bearer Token Authentication

```bash
# First, create a token using the CLI
mix concord.cluster token create
# Output: Token created: gn8kZrvWDdYU2K83sQDnBgWM4XaclkWh56T3zAFULcE

# Use the token in API requests
export CONCORD_TOKEN="gn8kZrvWDdYU2K83sQDnBgWM4XaclkWh56T3zAFULcE"
curl -H "Authorization: Bearer $CONCORD_TOKEN" http://localhost:4000/api/v1/kv
```

### 2. API Key Authentication

```bash
# Use the same token with "api_" prefix as API key
export CONCORD_API_KEY="api_gn8kZrvWDdYU2K83sQDnBgWM4XaclkWh56T3zAFULcE"
curl -H "X-API-Key: $CONCORD_API_KEY" http://localhost:4000/api/v1/kv
```

## Basic CRUD Operations

### Health Check

```bash
curl http://localhost:4000/api/v1/health
```

**Response:**
```json
{
  "status": "healthy",
  "timestamp": "2025-10-21T12:47:27.231034Z",
  "service": "concord-api"
}
```

### Store a Key-Value Pair

```bash
curl -X PUT \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"value": "Hello, Concord!"}' \
  http://localhost:4000/api/v1/kv/greeting
```

**Response:**
```json
{
  "status": "ok"
}
```

### Store a Key-Value Pair with TTL

```bash
curl -X PUT \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"value": "Expires in 1 hour", "ttl": 3600}' \
  http://localhost:4000/api/v1/kv/temporary
```

### Retrieve a Value

```bash
curl -H "Authorization: Bearer $CONCORD_TOKEN" \
  http://localhost:4000/api/v1/kv/greeting
```

**Response:**
```json
{
  "status": "ok",
  "data": {
    "value": "Hello, Concord!"
  }
}
```

### Retrieve a Value with TTL Information

```bash
curl -H "Authorization: Bearer $CONCORD_TOKEN" \
  "http://localhost:4000/api/v1/kv/temporary?with_ttl=true"
```

**Response:**
```json
{
  "status": "ok",
  "data": {
    "value": "Expires in 1 hour",
    "ttl": 3595
  }
}
```

### List All Keys

```bash
curl -H "Authorization: Bearer $CONCORD_TOKEN" \
  http://localhost:4000/api/v1/kv
```

**Response:**
```json
{
  "status": "ok",
  "data": ["greeting", "temporary", "config"]
}
```

### Delete a Key

```bash
curl -X DELETE \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  http://localhost:4000/api/v1/kv/temporary
```

**Response:**
```json
{
  "status": "ok"
}
```

## TTL Operations

### Get TTL for a Key

```bash
curl -H "Authorization: Bearer $CONCORD_TOKEN" \
  http://localhost:4000/api/v1/kv/temporary/ttl
```

**Response:**
```json
{
  "status": "ok",
  "data": {
    "ttl": 1800
  }
}
```

### Extend TTL (Touch)

```bash
curl -X POST \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"ttl": 7200}' \
  http://localhost:4000/api/v1/kv/temporary/touch
```

**Response:**
```json
{
  "status": "ok"
}
```

## Bulk Operations

### Bulk Store Multiple Keys

```bash
curl -X POST \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "operations": [
      {"key": "user:1", "value": {"name": "Alice", "age": 30}},
      {"key": "user:2", "value": {"name": "Bob", "age": 25}, "ttl": 1800},
      {"key": "config:app", "value": {"debug": true, "version": "1.0.0"}}
    ]
  }' \
  http://localhost:4000/api/v1/kv/bulk
```

**Response:**
```json
{
  "status": "ok",
  "data": [
    {"key": "user:1", "status": "ok"},
    {"key": "user:2", "status": "ok"},
    {"key": "config:app", "status": "ok"}
  ]
}
```

### Bulk Retrieve Multiple Keys

```bash
curl -X POST \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "keys": ["user:1", "user:2", "nonexistent"],
    "with_ttl": true
  }' \
  http://localhost:4000/api/v1/kv/bulk/get
```

**Response:**
```json
{
  "status": "ok",
  "data": {
    "user:1": {
      "status": "ok",
      "value": {"name": "Alice", "age": 30}
    },
    "user:2": {
      "status": "ok",
      "value": {"name": "Bob", "age": 25},
      "ttl": 1755
    },
    "nonexistent": {
      "status": "error",
      "error": "not_found"
    }
  }
}
```

### Bulk Delete Multiple Keys

```bash
curl -X POST \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "keys": ["user:1", "old:config"]
  }' \
  http://localhost:4000/api/v1/kv/bulk/delete
```

**Response:**
```json
{
  "status": "ok",
  "data": [
    {"key": "user:1", "status": "ok"},
    {"key": "old:config", "status": "error", "error": "not_found"}
  ]
}
```

### Bulk TTL Operations

```bash
curl -X POST \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "operations": [
      {"key": "session:1", "ttl": 3600},
      {"key": "session:2", "ttl": 7200}
    ]
  }' \
  http://localhost:4000/api/v1/kv/bulk/touch
```

**Response:**
```json
{
  "status": "ok",
  "data": [
    {"key": "session:1", "status": "ok"},
    {"key": "session:2", "status": "ok"}
  ]
}
```

## Cluster Administration

### Get Cluster Status

```bash
curl -H "Authorization: Bearer $CONCORD_TOKEN" \
  http://localhost:4000/api/v1/status
```

**Response:**
```json
{
  "status": "ok",
  "data": {
    "cluster": {
      "name": "concord_cluster",
      "nodes": [
        {
          "name": "concord@127.0.0.1",
          "status": "leader",
          "address": "127.0.0.1"
        }
      ],
      "leader": "concord@127.0.0.1"
    },
    "metrics": {
      "keys_total": 42,
      "operations_per_second": 15.2
    }
  }
}
```

## Error Handling Examples

### Invalid Key (Empty or Too Long)

```bash
curl -X PUT \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"value": "test"}' \
  http://localhost:4000/api/v1/kv/
```

**Response (400):**
```json
{
  "status": "error",
  "error": {
    "code": "INVALID_KEY",
    "message": "Key cannot be empty and must be <= 1024 bytes"
  }
}
```

### Missing Authentication

```bash
curl http://localhost:4000/api/v1/kv/test
```

**Response (401):**
```json
{
  "status": "error",
  "error": {
    "code": "UNAUTHORIZED",
    "message": "Authentication required"
  }
}
```

### Key Not Found

```bash
curl -H "Authorization: Bearer $CONCORD_TOKEN" \
  http://localhost:4000/api/v1/kv/nonexistent
```

**Response (404):**
```json
{
  "status": "error",
  "error": {
    "code": "NOT_FOUND",
    "message": "Key not found"
  }
}
```

### Batch Too Large

```bash
# Create a batch with 501 operations (limit is 500)
curl -X POST \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"operations": [{"key": "test", "value": "data"}]}' \
  http://localhost:4000/api/v1/kv/bulk
```

**Response (413):**
```json
{
  "status": "error",
  "error": {
    "code": "BATCH_TOO_LARGE",
    "message": "Batch size exceeds 500 operations limit"
  }
}
```

## API Documentation

### Interactive Swagger UI

Open your browser and navigate to:
```
http://localhost:4000/api/docs
```

This provides an interactive API documentation interface where you can:
- Explore all available endpoints
- Test API calls directly from your browser
- View request/response schemas
- Download the OpenAPI specification

### OpenAPI Specification

Download the complete OpenAPI 3.0 specification:
```bash
curl http://localhost:4000/api/v1/openapi.json -o concord-openapi.json
```

## Advanced Usage Examples

### Configuration Management

```bash
# Store application configuration
curl -X PUT \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "value": {
      "database": {
        "host": "localhost",
        "port": 5432,
        "name": "myapp_prod"
      },
      "features": {
        "new_ui": true,
        "beta_features": false
      },
      "limits": {
        "max_connections": 100,
        "timeout": 30000
      }
    }
  }' \
  http://localhost:4000/api/v1/kv/config:production

# Retrieve configuration
curl -H "Authorization: Bearer $CONCORD_TOKEN" \
  http://localhost:4000/api/v1/kv/config:production
```

### Session Management

```bash
# Create user session with 30-minute TTL
curl -X PUT \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "value": {
      "user_id": 12345,
      "username": "alice",
      "role": "admin",
      "last_activity": "2025-10-21T12:47:27Z"
    },
    "ttl": 1800
  }' \
  http://localhost:4000/api/v1/kv/session:abc123

# Extend session when user is active
curl -X POST \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"ttl": 1800}' \
  http://localhost:4000/api/v1/kv/session:abc123/touch

# Check session TTL
curl -H "Authorization: Bearer $CONCORD_TOKEN" \
  http://localhost:4000/api/v1/kv/session:abc123/ttl
```

### Feature Flags

```bash
# Set feature flags for different user segments
curl -X POST \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "operations": [
      {"key": "feature:new_dashboard:enabled", "value": true},
      {"key": "feature:beta_ui:enabled", "value": false},
      {"key": "feature:advanced_search:users:premium", "value": true},
      {"key": "feature:advanced_search:users:basic", "value": false}
    ]
  }' \
  http://localhost:4000/api/v1/kv/bulk

# Check feature flag for user
curl -H "Authorization: Bearer $CONCORD_TOKEN" \
  http://localhost:4000/api/v1/kv/feature:new_dashboard:enabled
```

## Performance Tips

1. **Use Bulk Operations**: When handling multiple keys, use bulk endpoints to reduce network round trips.

2. **Batch Size Limits**: Keep bulk operations under 500 items per request for optimal performance.

3. **TTL Management**: Set appropriate TTL values to automatically clean up expired data.

4. **Connection Reuse**: Use HTTP keep-alive connections for better performance.

5. **Compression**: For large payloads, consider using HTTP compression.

## Integration Examples

### Python Example

```python
import requests
import json

# Configuration
BASE_URL = "http://localhost:4000/api/v1"
TOKEN = "your-concord-token"

headers = {
    "Authorization": f"Bearer {TOKEN}",
    "Content-Type": "application/json"
}

# Store data
response = requests.put(
    f"{BASE_URL}/kv/python:example",
    headers=headers,
    json={"value": {"message": "Hello from Python!", "version": 3.9}}
)

# Retrieve data
response = requests.get(f"{BASE_URL}/kv/python:example", headers=headers)
data = response.json()
print(f"Status: {data['status']}")
print(f"Value: {data['data']['value']}")
```

### JavaScript Example

```javascript
const BASE_URL = 'http://localhost:4000/api/v1';
const TOKEN = 'your-concord-token';

const headers = {
  'Authorization': `Bearer ${TOKEN}`,
  'Content-Type': 'application/json'
};

// Store data
async function storeData(key, value) {
  const response = await fetch(`${BASE_URL}/kv/${key}`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ value })
  });
  return response.json();
}

// Retrieve data
async function getData(key) {
  const response = await fetch(`${BASE_URL}/kv/${key}`, {
    method: 'GET',
    headers
  });
  return response.json();
}

// Usage
storeData('js:example', { message: 'Hello from JavaScript!' })
  .then(() => getData('js:example'))
  .then(result => console.log(result));
```

### Go Example

```go
package main

import (
    "bytes"
    "encoding/json"
    "fmt"
    "net/http"
)

const (
    BaseURL = "http://localhost:4000/api/v1"
    Token   = "your-concord-token"
)

func main() {
    client := &http.Client{}

    // Store data
    data := map[string]interface{}{
        "value": map[string]string{
            "message": "Hello from Go!",
            "lang":    "golang",
        },
    }

    jsonData, _ := json.Marshal(data)

    req, _ := http.NewRequest("PUT", BaseURL+"/kv/go:example", bytes.NewBuffer(jsonData))
    req.Header.Set("Authorization", "Bearer "+Token)
    req.Header.Set("Content-Type", "application/json")

    resp, err := client.Do(req)
    if err != nil {
        panic(err)
    }
    defer resp.Body.Close()

    fmt.Printf("Status: %d\n", resp.StatusCode)
}
```

## Monitoring and Debugging

### Check API Response Times

```bash
# Use curl with timing info
curl -w "@curl-format.txt" \
  -H "Authorization: Bearer $CONCORD_TOKEN" \
  http://localhost:4000/api/v1/kv/test
```

Create `curl-format.txt`:
```
     time_namelookup:  %{time_namelookup}\n
        time_connect:  %{time_connect}\n
     time_appconnect:  %{time_appconnect}\n
    time_pretransfer:  %{time_pretransfer}\n
       time_redirect:  %{time_redirect}\n
  time_starttransfer:  %{time_starttransfer}\n
                     ----------\n
          time_total:  %{time_total}\n
```

### Monitor Cluster Health

```bash
# Continuous monitoring
while true; do
  echo "=== $(date) ==="
  curl -s -H "Authorization: Bearer $CONCORD_TOKEN" \
    http://localhost:4000/api/v1/status | jq '.data.cluster'
  echo ""
  sleep 5
done
```

This comprehensive guide should help you get started with the Concord HTTP API. For more detailed information about specific endpoints, refer to the interactive Swagger UI at `http://localhost:4000/api/docs`.