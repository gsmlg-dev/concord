# Concord HTTP API Design

## Overview
RESTful HTTP API for Concord distributed key-value store with JSON request/response format.

## Base URL
```
http://localhost:4000/api/v1
```

## Authentication
Two authentication methods supported:
1. **Bearer Token**: `Authorization: Bearer <token>`
2. **API Key**: `X-API-Key: <token>`

Both use the existing Concord token system.

## Endpoints

### Core CRUD Operations

#### PUT /api/v1/kv/{key}
Store a single key-value pair.
- **Method**: PUT
- **Path**: `/api/v1/kv/{key}`
- **Body**:
  ```json
  {
    "value": "any JSON-serializable value",
    "ttl": 3600  // optional, seconds
  }
  ```
- **Response**:
  ```json
  {
    "status": "ok"
  }
  ```

#### GET /api/v1/kv/{key}
Retrieve a single value.
- **Method**: GET
- **Path**: `/api/v1/kv/{key}`
- **Query Params**:
  - `with_ttl` (boolean): Include TTL information
- **Response**:
  ```json
  {
    "status": "ok",
    "data": {
      "value": "stored value",
      "ttl": 3600  // only if with_ttl=true
    }
  }
  ```

#### DELETE /api/v1/kv/{key}
Delete a single key.
- **Method**: DELETE
- **Path**: `/api/v1/kv/{key}`
- **Response**:
  ```json
  {
    "status": "ok"
  }
  ```

### Bulk Operations

#### POST /api/v1/kv/bulk
Store multiple key-value pairs atomically.
- **Method**: POST
- **Path**: `/api/v1/kv/bulk`
- **Body**:
  ```json
  {
    "operations": [
      {"key": "key1", "value": "value1"},
      {"key": "key2", "value": "value2", "ttl": 3600}
    ]
  }
  ```
- **Response**:
  ```json
  {
    "status": "ok",
    "data": {
      "key1": "ok",
      "key2": "ok"
    }
  }
  ```

#### POST /api/v1/kv/bulk/get
Retrieve multiple values.
- **Method**: POST
- **Path**: `/api/v1/kv/bulk/get`
- **Body**:
  ```json
  {
    "keys": ["key1", "key2", "key3"],
    "with_ttl": false
  }
  ```
- **Response**:
  ```json
  {
    "status": "ok",
    "data": {
      "key1": {"status": "ok", "value": "value1"},
      "key2": {"status": "error", "error": "not_found"},
      "key3": {"status": "ok", "value": "value3", "ttl": 1800}
    }
  }
  ```

#### POST /api/v1/kv/bulk/delete
Delete multiple keys atomically.
- **Method**: POST
- **Path**: `/api/v1/kv/bulk/delete`
- **Body**:
  ```json
  {
    "keys": ["key1", "key2", "key3"]
  }
  ```
- **Response**:
  ```json
  {
    "status": "ok",
    "data": {
      "key1": "ok",
      "key2": "ok",
      "key3": {"status": "error", "error": "not_found"}
    }
  }
  ```

### TTL Operations

#### POST /api/v1/kv/{key}/touch
Extend TTL for a key.
- **Method**: POST
- **Path**: `/api/v1/kv/{key}/touch`
- **Body**:
  ```json
  {
    "ttl": 3600  // additional TTL seconds
  }
  ```
- **Response**:
  ```json
  {
    "status": "ok"
  }
  ```

#### POST /api/v1/kv/bulk/touch
Extend TTL for multiple keys.
- **Method**: POST
- **Path**: `/api/v1/kv/bulk/touch`
- **Body**:
  ```json
  {
    "operations": [
      {"key": "key1", "ttl": 3600},
      {"key": "key2", "ttl": 7200}
    ]
  }
  ```
- **Response**:
  ```json
  {
    "status": "ok",
    "data": {
      "key1": "ok",
      "key2": "ok"
    }
  }
  ```

#### GET /api/v1/kv/{key}/ttl
Get remaining TTL for a key.
- **Method**: GET
- **Path**: `/api/v1/kv/{key}/ttl`
- **Response**:
  ```json
  {
    "status": "ok",
    "data": {
      "ttl": 3600
    }
  }
  ```

### Administrative Operations

#### GET /api/v1/kv
Get all key-value pairs (use sparingly).
- **Method**: GET
- **Path**: `/api/v1/kv`
- **Query Params**:
  - `with_ttl` (boolean): Include TTL information
  - `limit` (integer): Limit number of results
- **Response**:
  ```json
  {
    "status": "ok",
    "data": {
      "key1": {"value": "value1", "ttl": 3600},
      "key2": {"value": "value2"}
    }
  }
  ```

#### GET /api/v1/health
Health check endpoint.
- **Method**: GET
- **Path**: `/api/v1/health`
- **Response**:
  ```json
  {
    "status": "healthy",
    "timestamp": "2025-01-20T12:00:00Z",
    "cluster": {
      "status": "leader",
      "nodes": 3,
      "storage": {
        "size": 1000,
        "memory": 1048576
      }
    }
  }
  ```

#### GET /api/v1/status
Detailed cluster status.
- **Method**: GET
- **Path**: `/api/v1/status`
- **Response**:
  ```json
  {
    "status": "ok",
    "data": {
      "cluster": {...},
      "storage": {...},
      "node": "node@hostname"
    }
  }
  ```

## Error Responses

All error responses follow this format:
```json
{
  "status": "error",
  "error": {
    "code": "INVALID_KEY",
    "message": "Key cannot be empty",
    "details": {...}
  }
}
```

### Common Error Codes
- `INVALID_REQUEST` - Malformed JSON or missing required fields
- `INVALID_KEY` - Invalid key format
- `UNAUTHORIZED` - Missing or invalid authentication
- `NOT_FOUND` - Key does not exist
- `TIMEOUT` - Operation timed out
- `CLUSTER_UNAVAILABLE` - Cluster not ready
- `BATCH_TOO_LARGE` - Batch exceeds size limits
- `VALIDATION_ERROR` - Input validation failed

## Rate Limiting
- Configurable rate limits per API key
- Response headers: `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`

## CORS
- Configurable CORS policies for cross-origin requests