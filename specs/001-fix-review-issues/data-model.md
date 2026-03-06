# Data Model: Fix Review Issues

**Date**: 2026-03-03
**Branch**: `001-fix-review-issues`

## Entity Changes

This feature does not introduce new entities. It fixes how existing entities are maintained across write paths, backups, and snapshots.

### Modified: Backup Format (V2)

The backup data format changes from a flat list to a versioned map.

**V1 (current):**
```
backup_data = [{key, formatted_value}, ...]
```

**V2 (new):**
```
backup_data = %{
  version: 2,
  kv_data: [{key, formatted_value}, ...],
  tokens: %{token => permissions},
  roles: %{role => permissions},
  role_grants: %{token => [roles]},
  acls: [{pattern, role, permissions}],
  tenants: %{tenant_id => tenant_definition},
  indexes: %{name => extractor_spec}
}
```

**Migration**: The restore command handler must detect V1 (list) vs V2 (map) format and handle both.

### Unchanged: State Machine State

The state machine state shape is unchanged:
```
{:concord_kv, %{
  indexes: %{name => extractor_spec},
  tokens: %{token => permissions},
  roles: %{role => permissions},
  role_grants: %{token => [roles]},
  acls: [{pattern, role, permissions}],
  tenants: %{tenant_id => tenant_definition},
  command_count: non_neg_integer()
}}
```

### Unchanged: Snapshot Format (V3)

The V3 snapshot format is already comprehensive and unchanged:
```
{:concord_kv, %{
  __snapshot_version__: 3,
  __kv_data__: [{key, value}, ...],
  __index_ets__: %{name => [{index_key, key}, ...]},
  indexes: %{...},
  tokens: %{...},
  roles: %{...},
  role_grants: %{...},
  acls: [...],
  tenants: %{...},
  command_count: integer()
}}
```

## ETS Table Access Changes

| Table | Current | Proposed | Owner Process |
|-------|---------|----------|---------------|
| `:concord_store` | `:public` | `:protected` | Ra server |
| `:concord_tokens` | `:public` | `:public` * | Auth module (bootstrap fallback) |
| `:concord_roles` | `:public` | `:public` * | RBAC module (bootstrap fallback) |
| `:concord_role_grants` | `:public` | `:public` * | RBAC module (bootstrap fallback) |
| `:concord_acls` | `:public` | `:public` * | RBAC module (bootstrap fallback) |
| `:concord_tenants` | `:public` | `:protected` | Ra server |
| Index tables (dynamic) | `:public` | `:protected` | Ra server |

\* Auth/RBAC tables must remain `:public` because of the bootstrap fallback path where direct ETS writes occur when the Ra cluster is not yet ready (`:noproc`). These writes come from processes other than the Ra server.
