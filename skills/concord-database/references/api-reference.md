# Concord API Reference

## Write Operations

### `Concord.put(key, value, opts \\ [])`
Store a key-value pair. Auto-compresses values > 1KB.

Options: `:timeout` (ms, default 5000), `:token`, `:ttl` (seconds), `:compress` (true/false)

Returns: `:ok | {:error, :timeout | :unauthorized | :cluster_not_ready | :invalid_key | :noproc}`

### `Concord.put_many(operations, opts \\ [])`
Atomic batch write. Max 500 items.

```elixir
Concord.put_many([{"k1", "v1"}, {"k2", "v2", 3600}], token: token)
```

Format: `[{key, value} | {key, value, ttl_seconds}]`

### `Concord.delete(key, opts \\ [])`
Returns: `:ok | {:error, reason}`

### `Concord.delete_many(keys, opts \\ [])`
Atomic batch delete. `keys` is list of strings.

### `Concord.touch(key, additional_ttl_seconds, opts \\ [])`
Extend TTL on existing key.

### `Concord.touch_many(operations, opts \\ [])`
Format: `[{key, ttl_seconds}]`

## Conditional Operations

### `Concord.put_if(key, value, opts)`
Requires exactly one of `:expected` or `:condition`.

```elixir
# CAS — update only if current value matches
Concord.put_if("counter", 1, expected: 0)

# Predicate — update if condition returns true
Concord.put_if("config", new_cfg, condition: fn old -> old.version < 2 end)
```

Returns: `:ok | {:error, :condition_failed | :not_found | :missing_condition | :conflicting_conditions}`

**Important**: Condition functions are evaluated at the API layer pre-consensus, then converted to CAS commands with `expected: current_value` before entering the Raft log. This keeps the log deterministic.

### `Concord.delete_if(key, opts)`
Same options as `put_if` (`:expected` or `:condition`).

## Read Operations

### `Concord.get(key, opts \\ [])`
Options: `:timeout`, `:token`, `:consistency` (`:eventual | :leader | :strong`)

Returns: `{:ok, value} | {:error, :not_found | :timeout | :unauthorized | :cluster_not_ready}`

### `Concord.get_many(keys, opts \\ [])`
Returns: `{:ok, %{key => {:ok, value} | {:error, :not_found}}}`

### `Concord.get_all(opts \\ [])`
Returns: `{:ok, %{key => value}}`

### `Concord.get_with_ttl(key, opts \\ [])`
Returns: `{:ok, {value, remaining_seconds}} | {:error, :not_found}`

### `Concord.get_all_with_ttl(opts \\ [])`
Returns: `{:ok, %{key => {value, remaining_seconds | nil}}}`

### `Concord.ttl(key, opts \\ [])`
Returns: `{:ok, seconds | nil} | {:error, :not_found}`

### `Concord.exists?(key, opts \\ [])`
Returns: `{:ok, boolean}`

### `Concord.status(opts \\ [])`
Returns: `{:ok, %{cluster: ..., storage: %{size: n, memory: n}, node: ...}}`

### `Concord.members()`
Returns: `{:ok, [server_ids]}`

## Auth API (`Concord.Auth`)

All mutations go through Raft consensus.

```elixir
Concord.Auth.create_token(permissions)   # => {:ok, token_string}
Concord.Auth.revoke_token(token)         # => :ok
Concord.Auth.verify_token(token)         # => :ok | {:error, :unauthorized}
```

## RBAC API (`Concord.RBAC`)

Predefined roles: `:admin`, `:editor`, `:viewer`, `:none`
Permissions: `:read`, `:write`, `:delete`, `:admin`, `:*`

```elixir
Concord.RBAC.create_role(role, permissions)
Concord.RBAC.delete_role(role)
Concord.RBAC.list_roles()
Concord.RBAC.grant_role(token, role)
Concord.RBAC.revoke_role(token, role)
Concord.RBAC.list_token_roles(token)
Concord.RBAC.create_acl(key_pattern, role, permissions)
Concord.RBAC.delete_acl(pattern, role)
Concord.RBAC.list_acls()
Concord.RBAC.check_permission(token, operation, key)
```

## Multi-Tenancy (`Concord.MultiTenancy`)

Tenant definitions via Raft; usage counters are node-local.

```elixir
Concord.MultiTenancy.create_tenant(id, opts)    # auto-creates RBAC role + ACLs
Concord.MultiTenancy.get_tenant(id)
Concord.MultiTenancy.list_tenants()
Concord.MultiTenancy.delete_tenant(id)
Concord.MultiTenancy.update_quota(id, quota_type, value)
```

Tenant definition shape:
```elixir
%{id: atom(), name: String.t(), namespace: "tenant_id:*",
  quotas: %{max_keys: n, max_storage_bytes: n, max_ops_per_sec: n},
  role: atom(), created_at: DateTime.t()}
```

## Backup (`Concord.Backup`)

```elixir
Concord.Backup.create(path: "/backups")          # => {:ok, path}
Concord.Backup.restore(path)                      # => :ok (submits {:restore_backup, entries} via Raft)
Concord.Backup.list(path)                         # => {:ok, [backup_info]}
Concord.Backup.verify(path)                       # => {:ok, :valid | :invalid}
Concord.Backup.cleanup(path: p, keep_count: 10)   # => {:ok, deleted_count}
```

## Event Streaming (`Concord.EventStream`)

GenStage-based CDC with back-pressure.

```elixir
{:ok, sub} = Concord.EventStream.subscribe(
  key_pattern: ~r/^user:/,
  event_types: [:put, :delete],
  max_demand: 1000
)

# Receive events
receive do
  {:concord_event, %{type: :put, key: key, value: value, timestamp: ts}} -> ...
end

Concord.EventStream.unsubscribe(sub)
Concord.EventStream.stats()   # => %{queue_size: n, events_published: n}
```

## Index API (`Concord.Index`)

```elixir
Concord.Index.create(name, extractor_spec, opts)  # opts: reindex: true
Concord.Index.drop(name)
Concord.Index.lookup(name, value)                  # => {:ok, [keys]}
Concord.Index.list()
Concord.Index.reindex_all()
```

Extractor specs (declarative, safe for Raft):
- `{:map_get, :field}` — extract map field
- `{:nested, [:path, :to, :field]}` — nested extraction
- `{:identity}` — index raw value
- `{:element, n}` — nth element of tuple/list

## Compression (`Concord.Compression`)

```elixir
Concord.Compression.compress(value, opts)          # => {:compressed, algo, binary}
Concord.Compression.decompress(value)              # => original value
Concord.Compression.should_compress?(value)        # => boolean
Concord.Compression.stats(value)                   # => %{original_size: n, compressed_size: n, ...}
```

## Error Types

```elixir
:timeout              # Operation timed out
:unauthorized         # Invalid or missing auth token
:cluster_not_ready    # Ra cluster not initialized
:invalid_key          # Key must be binary string, 1-1024 bytes
:not_found            # Key doesn't exist or expired
:noproc               # Ra process not running
:condition_failed     # CAS condition not met
:missing_condition    # put_if/delete_if without expected or condition
:conflicting_conditions  # Both expected and condition provided
```
