# Contract: Backup Format V2

## Overview

The backup file format changes from a flat KV list to a versioned map that captures all state categories.

## Backup Creation Output

```elixir
%{
  metadata: %{
    version: 2,
    timestamp: DateTime.t(),
    node: atom(),
    entry_count: non_neg_integer(),
    state_categories: [:kv, :auth, :rbac, :tenants, :indexes]
  },
  data: %{
    version: 2,
    kv_data: [{binary(), term()}],
    tokens: %{binary() => term()},
    roles: %{atom() => term()},
    role_grants: %{binary() => [atom()]},
    acls: [{term(), atom(), term()}],
    tenants: %{binary() => term()},
    indexes: %{binary() => tuple()}
  }
}
```

## Restore Command

```elixir
# V2 format (new)
{:restore_backup, %{version: 2, kv_data: [...], tokens: %{}, ...}}

# V1 format (backward compatible)
{:restore_backup, [{key, value}, ...]}
```

## Backward Compatibility

The restore handler detects format by checking if the payload is a list (V1) or map (V2):
- `when is_list(payload)` → V1 path (existing behavior)
- `when is_map(payload)` → V2 path (full state restore)
