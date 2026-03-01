# HTTP API Reference

Base URL: `http://localhost:4000/api/v1`

## Authentication

Two methods (header-based):
- `Authorization: Bearer <token>`
- `X-API-Key: <token>`

Auth disabled in dev, enabled in prod. Public endpoints skip auth.

## Public Endpoints

### GET /api/v1/health
```json
{"status": "healthy", "timestamp": "2025-10-23T12:00:00Z", "service": "concord-api"}
```

### GET /api/v1/openapi.json
Returns OpenAPI 3.0 specification.

### GET /api/docs
Swagger UI for interactive API exploration.

## Core CRUD

### PUT /api/v1/kv/:key
Store a value. Body:
```json
{"value": "any JSON value", "ttl": 3600}
```
`ttl` is optional (seconds).

Response (200):
```json
{"status": "ok", "key": "mykey"}
```

### GET /api/v1/kv/:key
Retrieve a value.

Response (200):
```json
{"status": "ok", "key": "mykey", "value": "stored value", "ttl": 3595}
```

Response (404):
```json
{"status": "error", "error": {"code": "NOT_FOUND", "message": "Key not found"}}
```

### DELETE /api/v1/kv/:key
Delete a key.

Response (200):
```json
{"status": "ok", "key": "mykey"}
```

## TTL Operations

### GET /api/v1/kv/:key/ttl
Get remaining TTL.

Response:
```json
{"status": "ok", "key": "mykey", "ttl": 3595}
```

### POST /api/v1/kv/:key/touch
Extend TTL. Body:
```json
{"ttl": 3600}
```

## Bulk Operations

Max 500 items per request.

### POST /api/v1/kv/bulk
Batch store. Body:
```json
{
  "items": [
    {"key": "k1", "value": "v1"},
    {"key": "k2", "value": "v2", "ttl": 3600}
  ]
}
```

### POST /api/v1/kv/bulk/get
Batch retrieve. Body:
```json
{"keys": ["k1", "k2", "k3"]}
```

Response:
```json
{
  "status": "ok",
  "results": {
    "k1": {"status": "ok", "value": "v1"},
    "k2": {"status": "ok", "value": "v2"},
    "k3": {"status": "error", "error": "not_found"}
  }
}
```

### POST /api/v1/kv/bulk/delete
Batch delete. Body:
```json
{"keys": ["k1", "k2"]}
```

### POST /api/v1/kv/bulk/touch
Batch TTL extend. Body:
```json
{
  "items": [
    {"key": "k1", "ttl": 3600},
    {"key": "k2", "ttl": 7200}
  ]
}
```

## Administrative

### GET /api/v1/kv
List all keys and values.

### GET /api/v1/status
Cluster status including storage stats, member info, leader, commit index.

## Error Responses

All errors follow:
```json
{
  "status": "error",
  "error": {
    "code": "ERROR_CODE",
    "message": "Human-readable message"
  }
}
```

Error codes: `NOT_FOUND`, `UNAUTHORIZED`, `INVALID_KEY`, `TIMEOUT`, `CLUSTER_NOT_READY`, `INTERNAL_ERROR`

## curl Examples

```bash
# Health check
curl http://localhost:4000/api/v1/health

# Store (dev mode, no auth)
curl -X PUT -H "Content-Type: application/json" \
  -d '{"value": "hello", "ttl": 3600}' \
  http://localhost:4000/api/v1/kv/greeting

# Store (with auth)
curl -X PUT -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"value": {"name": "Alice"}}' \
  http://localhost:4000/api/v1/kv/user:1

# Get
curl http://localhost:4000/api/v1/kv/greeting

# Delete
curl -X DELETE http://localhost:4000/api/v1/kv/greeting

# Bulk put
curl -X POST -H "Content-Type: application/json" \
  -d '{"items": [{"key": "k1", "value": "v1"}, {"key": "k2", "value": "v2"}]}' \
  http://localhost:4000/api/v1/kv/bulk

# Bulk get
curl -X POST -H "Content-Type: application/json" \
  -d '{"keys": ["k1", "k2"]}' \
  http://localhost:4000/api/v1/kv/bulk/get

# Status
curl http://localhost:4000/api/v1/status
```
