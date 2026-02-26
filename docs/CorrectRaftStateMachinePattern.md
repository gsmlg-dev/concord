# Correct Raft State Machine Pattern for Concord

**Date:** 2026-02-11
**Scope:** Deterministic replay, snapshot correctness, high-throughput ETS hot-path, Ra integration
**Architecture:** Ra + ETS (no CubDB)

---

## Table of Contents

1. [Audit & Risks: Determinism Under Replay](#1-audit--risks-determinism-under-replay)
2. [The Correct Pattern: Authoritative State + Side Effects](#2-the-correct-pattern-authoritative-state--side-effects)
3. [Snapshot Correctness](#3-snapshot-correctness)
4. [Indexing Strategy](#4-indexing-strategy)
5. [High-Throughput Command & Query APIs](#5-high-throughput-command--query-apis)
6. [Hardening Checklist](#6-hardening-checklist)
7. [Architecture Diagram](#7-architecture-diagram)
8. [Deterministic Replay Safety Checklist (Invariants)](#8-deterministic-replay-safety-checklist)
9. [Step-by-Step Migration Plan](#9-step-by-step-migration-plan)

---

## 1. Audit & Risks: Determinism Under Replay

### Fundamental Rule

> In a Raft state machine, `apply/3` must be a **pure function** of (command, current_state) → (new_state, result, effects). Given the same input, it must produce the same output on every node and on every replay, regardless of wall-clock time, node identity, or execution context.

Concord currently violates this rule in multiple places.

---

### Issue 1: Wall-Clock Time Inside `apply_command/3`

**Location:** `lib/concord/state_machine.ex:31,34`

```elixir
# Line 31 — called during :cleanup_expired, :touch, query handlers
defp expired?(expires_at) do
  System.system_time(:second) > expires_at  # ← NON-DETERMINISTIC
end

# Line 34 — called during :touch, :touch_many
defp current_timestamp, do: System.system_time(:second)  # ← NON-DETERMINISTIC
```

**How it breaks:**

The `:cleanup_expired` command (line 243) iterates all keys, calls `expired?/1` on each, and deletes the expired ones. On the leader, this runs at time T₁. When a follower replays the same log entry at time T₂ > T₁, `expired?/1` may return `true` for additional keys that were not expired at T₁. The follower deletes more keys than the leader did. **The states diverge.**

The `:touch` command (line 214) computes `new_expires_at = current_timestamp() + additional_ttl_seconds`. On replay, `current_timestamp()` returns a different value. The follower stores a different `expires_at` than the leader. **The states diverge.**

**Classification:** Breaks Raft safety. Followers will have different state than the leader after replay. This can cascade — any subsequent command that reads the diverged state produces further divergence.

**Fix:**

Use Ra's metadata timestamp instead of wall-clock time. Ra's `meta` map contains `system_time` (set by the leader at proposal time) which is the same across all replays:

```elixir
# CORRECT: Use Ra's metadata for deterministic time
def apply_command(meta, :cleanup_expired, {:concord_kv, data}) do
  now = Map.get(meta, :system_time, System.system_time(:millisecond))
  now_seconds = div(now, 1000)
  # Use now_seconds instead of System.system_time(:second)
  ...
end

def apply_command(meta, {:touch, key, additional_ttl_seconds}, {:concord_kv, data}) do
  now = Map.get(meta, :system_time, System.system_time(:millisecond))
  now_seconds = div(now, 1000)
  new_expires_at = now_seconds + additional_ttl_seconds
  ...
end
```

The `system_time` in Ra's metadata is set by the leader when the command is proposed and is replicated in the log entry. All followers use the same value during replay. This is the standard approach in all production Raft implementations.

---

### Issue 2: Anonymous Functions Stored in Raft Log and State

**Location:**
- `lib/concord/index.ex:112` — index extractor functions
- `lib/concord.ex:204` — `put_if` condition functions
- `lib/concord.ex:260` — `delete_if` condition functions

**How it breaks:**

Anonymous functions in Erlang/Elixir carry a reference to the module version (the "new fun" representation includes the module, function index, and uniq hash). When serialized into the Raft log via `:erlang.term_to_binary`, they embed this module reference.

After a code upgrade (hot code reload or deployment), the old module version may no longer exist. Replaying a log entry containing the old function reference causes `{:badfun, ...}` at runtime. Similarly, if a snapshot contains an anonymous function from an old module version, `snapshot_installed/4` will receive an unusable function.

For `put_if`/`delete_if`, the condition function is in the command (log entry only). For indexes, the extractor function is in the machine state (persisted in snapshots and live state).

**Classification:** Breaks Raft safety on code upgrade. Breaks snapshot restore across versions.

**Fix for indexes:** Replace anonymous functions with a declarative extractor specification:

```elixir
# INSTEAD OF: fn value -> Map.get(value, :email) end
# USE: {:map_get, :email}
# OR: {:json_path, ["user", "email"]}

# Index extractors become data, not code:
defmodule Concord.Index.Extractor do
  def extract({:map_get, key}, value) when is_map(value), do: Map.get(value, key)
  def extract({:map_get, key}, _value), do: nil

  def extract({:nested, keys}, value) when is_map(value), do: get_in(value, keys)
  def extract({:nested, _keys}, _value), do: nil

  def extract({:identity}, value), do: value
end
```

**Fix for `put_if`/`delete_if`:** Replace the condition function with a declarative condition specification:

```elixir
# INSTEAD OF: condition: fn old -> old.version < 5 end
# USE: condition: {:lt, [:version], 5}

# Or use :expected (which is already data, not a function) as the primary API:
# Concord.put_if("key", new_val, expected: old_val)
```

If arbitrary predicate functions are needed, evaluate them **before** submitting the command (at the API layer), and convert the result into a deterministic CAS command:

```elixir
# Pre-consensus: read current value, evaluate predicate client-side
{:ok, current} = Concord.get(key)
if user_predicate.(current) do
  Concord.put_if(key, new_value, expected: current)  # CAS with data, not functions
end
```

---

### Issue 3: Auth Tokens Bypass Raft Entirely

**Location:** `lib/concord/auth.ex:63,75` — `TokenStore.put/2`, `TokenStore.delete/1`

```elixir
# Direct ETS write — no Ra consensus
def put(token, permissions) do
  :ets.insert(:concord_tokens, {token, permissions})
end
```

**How it breaks:**

Tokens are created via `:crypto.strong_rand_bytes(32)` (non-deterministic) and stored directly in a node-local ETS table. In a 3-node cluster:
- Token created on node A exists only on node A
- Client routed to node B gets `{:error, :unauthorized}`
- After node A restarts, the token is lost

**Classification:** Does not break Raft safety (tokens are not part of the replicated state machine). Breaks application-level consistency — authentication becomes node-dependent.

**Fix:** Route token mutations through Ra. Generate the token on the client side (pre-consensus), then replicate the token as a Raft command:

```elixir
# In the API layer (pre-consensus):
def create_token(opts \\ []) do
  token = :crypto.strong_rand_bytes(32) |> Base.url_encode64()
  permissions = Keyword.get(opts, :permissions, [:read, :write])
  # Send deterministic command through Raft:
  command({:auth_create_token, token, permissions})
end

# In apply_command (deterministic — token value is in the command, not generated here):
def apply_command(_meta, {:auth_create_token, token, permissions}, {:concord_kv, data}) do
  tokens = Map.get(data, :tokens, %{})
  new_tokens = Map.put(tokens, token, permissions)
  new_data = Map.put(data, :tokens, new_tokens)
  # Also insert into local ETS for fast lookups:
  :ets.insert(:concord_tokens, {token, permissions})
  {{:concord_kv, new_data}, {:ok, token}, []}
end
```

The token value is generated pre-consensus (non-deterministic generation is fine here because the result is embedded in the command). The `apply_command` receives the token as data and stores it deterministically.

---

### Issue 4: RBAC Bypasses Raft Entirely

**Location:** `lib/concord/rbac.ex:98,155,198,220,266,286` — all mutations are direct ETS writes

**How it breaks:** Same as auth tokens. All role definitions, role grants, and ACL rules are node-local. In a cluster, RBAC state is inconsistent across nodes. After restart, all RBAC configuration is lost.

**Classification:** Does not break Raft safety. Breaks application-level consistency.

**Fix:** Same pattern as auth tokens. Route all RBAC mutations through Ra commands:

```elixir
# Commands to add to the state machine:
{:rbac_create_role, role_name, permissions}
{:rbac_delete_role, role_name}
{:rbac_grant_role, token, role_name}
{:rbac_revoke_role, token, role_name}
{:rbac_create_acl, pattern, role, permissions}
{:rbac_delete_acl, pattern, role}
```

Store RBAC state in the machine state map (`data.roles`, `data.role_grants`, `data.acls`) and materialize into ETS in `apply_command` for fast lookups.

---

### Issue 5: Multi-Tenancy Bypasses Raft Entirely

**Location:** `lib/concord/multi_tenancy.ex:153,227,262,372`

**How it breaks:** Same as auth/RBAC. Tenant definitions, quotas, and usage tracking are node-local.

**Classification:** Does not break Raft safety. Breaks application-level consistency.

**Fix:** Route tenant definition/quota mutations through Ra. Usage tracking (ops counters) can remain node-local as an optimization — it's inherently approximate and rate-limiting is a node-local concern.

```elixir
# Through Raft (must be consistent):
{:tenant_create, tenant_id, opts}
{:tenant_delete, tenant_id}
{:tenant_update_quota, tenant_id, quota_key, quota_value}

# Stays node-local (intentionally approximate):
# - ops_last_second counter
# - rate limiter state
```

---

### Issue 6: Snapshot Does Not Capture Complete State

**Location:** `lib/concord/state_machine.ex:675-685`

```elixir
def snapshot({:concord_kv, _data}) do
  data = :ets.tab2list(:concord_store)  # Only captures KV data
  # _data containing %{indexes: %{...}} is DISCARDED
  data
end
```

**How it breaks:**

After a snapshot-based restore (follower catching up, or node restart where Ra uses snapshot + log suffix), the machine state resets to `init/1`'s `{:concord_kv, %{indexes: %{}}}`. All index definitions in `data.indexes` are lost. If auth/RBAC/tenant state is later added to the machine state (per fixes above), those would also be lost.

**Classification:** Breaks application-level consistency. Can break Raft safety if the lost state affects command processing (e.g., indexes affect how put commands are applied — losing index definitions means puts no longer update indexes, diverging from nodes that still have them).

**Fix:** See [Section 3: Snapshot Correctness](#3-snapshot-correctness).

---

### Issue 7: Backup Restore Bypasses Raft

**Location:** `lib/concord/backup.ex:340-344`

```elixir
defp apply_backup(entries) do
  :ets.delete_all_objects(:concord_store)
  Enum.each(entries, fn {key, value} ->
    :ets.insert(:concord_store, {key, value})
  end)
end
```

**How it breaks:**

After `Backup.restore/2`, the local node's ETS state is replaced with the backup data. The Raft log and other nodes are unaware. The local node's state now contradicts what the Raft log says. Any subsequent Raft commands applied on top of this state will produce results inconsistent with other nodes.

**Classification:** Breaks Raft safety. The local state machine no longer corresponds to the Raft log.

**Fix:** Backup restore must go through Raft:

```elixir
def restore(backup_path, opts \\ []) do
  {:ok, entries} = read_and_verify_backup(backup_path)
  # Clear and rebuild through Raft:
  command({:restore_from_backup, entries})
end

# In apply_command — all nodes apply the same restore:
def apply_command(_meta, {:restore_from_backup, entries}, {:concord_kv, data}) do
  :ets.delete_all_objects(:concord_store)
  Enum.each(entries, fn {k, v} -> :ets.insert(:concord_store, {k, v}) end)
  # Also clear and rebuild indexes, etc.
  {{:concord_kv, data}, :ok, []}
end
```

---

### Issue 8: ETS Table Is `:public`

**Location:** `lib/concord/state_machine.ex:42`

```elixir
:ets.new(:concord_store, [:set, :public, :named_table])
```

**How it breaks:**

Any process on the node can call `:ets.insert(:concord_store, ...)` or `:ets.delete(:concord_store, ...)`, bypassing Raft consensus. This includes application code, library code, debugging sessions, and — as shown above — `Backup.restore/2` and `Index.reindex/1`.

**Classification:** Enables Raft safety bypasses. Not a direct violation, but removes the guard rail that would prevent violations.

**Fix:** Use `:protected` access. Only the process that created the table (the Ra server process running the state machine) can write to it. All other processes can read but not write.

```elixir
:ets.new(:concord_store, [:set, :protected, :named_table])
```

Note: Index ETS tables (`lib/concord/state_machine.ex:421`) have the same issue and should also be `:protected`.

---

### Issue 9: `get_many` Routed as a Write Command

**Location:** `lib/concord/state_machine.ex:330-348`

```elixir
def apply_command(meta, {:get_many, keys}, {:concord_kv, data}) when is_list(keys) do
  results = batch_get_keys(keys)
  {{:concord_kv, data}, {:ok, results}, []}
end
```

**How it breaks:**

`get_many` is a pure read but is implemented as an `apply_command`, meaning it goes through Raft consensus. This wastes log space and introduces unnecessary latency. It also means every read is written to the WAL, replicated to all followers, and persisted. For a high-throughput system, this is a significant overhead.

**Classification:** Does not break safety. Wastes resources and adds latency.

**Fix:** Move `get_many` to a query handler:

```elixir
# Remove the apply_command clause for :get_many
# Add a query clause instead:
def query({:get_many, keys}, {:concord_kv, _data}) when is_list(keys) do
  results = batch_get_keys(keys)
  {:ok, Map.new(results)}
end
```

Update `Concord.get_many/2` to use `:ra.leader_query` or `:ra.local_query` instead of `:ra.process_command`.

---

### Summary Table

| # | Issue | Severity | Breaks Raft Safety? | Breaks App Consistency? | Section |
|---|-------|----------|:-------------------:|:-----------------------:|---------|
| 1 | Wall-clock time in `apply_command` | **CRITICAL** | **YES** | YES | `state_machine.ex:31,34` |
| 2 | Anonymous functions in Raft log/state | **CRITICAL** | YES (on upgrade) | YES | `index.ex:112`, `concord.ex:204,260` |
| 3 | Auth tokens bypass Raft | **HIGH** | No | YES | `auth.ex:63,75` |
| 4 | RBAC bypasses Raft | **HIGH** | No | YES | `rbac.ex:98-286` |
| 5 | Multi-tenancy bypasses Raft | **HIGH** | No | YES | `multi_tenancy.ex:153-372` |
| 6 | Incomplete snapshot | **HIGH** | Partial | YES | `state_machine.ex:675` |
| 7 | Backup restore bypasses Raft | **HIGH** | **YES** | YES | `backup.ex:340-344` |
| 8 | ETS table is `:public` | **MEDIUM** | Enables bypasses | Enables bypasses | `state_machine.ex:42` |
| 9 | `get_many` as write command | **LOW** | No | No (perf only) | `state_machine.ex:330` |

---

## 2. The Correct Pattern: Authoritative State + Side Effects

### Core Invariants

These invariants must hold at all times for Concord's state machine to be correct:

> **Invariant 1 (Single Source of Truth):** ALL mutable state is derived from the Raft log + the latest snapshot. There is no state that exists outside this derivation.

> **Invariant 2 (Deterministic Apply):** `apply/3` is a pure function of `(meta, command, state)`. It does not call `System.system_time`, `node()`, `:crypto`, `Enum.random`, or any other non-deterministic function. It does not perform IO (network, disk, external process calls).

> **Invariant 3 (ETS as Materialized View):** ETS tables are materialized views of the authoritative Raft state. They are derived from the state, not the other way around. If all ETS tables are deleted, they can be fully reconstructed from the Raft state alone.

> **Invariant 4 (Read-Only Queries):** `query/2` functions never mutate state. They read from ETS (the materialized view) and return results.

> **Invariant 5 (Side Effect Isolation):** Telemetry, logging, audit, event streaming, and notifications are side effects. They may use non-deterministic values (wall-clock time, node identity) because they don't affect state. They must never influence the state machine's output.

### Architecture: Four Layers

```
┌─────────────────────────────────────────────────────────────────┐
│  LAYER 1: COMMAND VALIDATION (Pre-Consensus)                    │
│                                                                 │
│  Runs on the client node BEFORE submitting to Ra.               │
│  May use non-deterministic values (wall-clock, crypto).         │
│  Produces a DETERMINISTIC command tuple.                        │
│                                                                 │
│  Responsibilities:                                              │
│  - Input validation (key size, batch limits, format)            │
│  - Auth verification (check token exists in local ETS)          │
│  - TTL computation (convert ttl_seconds → absolute expires_at)  │
│  - Token generation (crypto.strong_rand_bytes)                  │
│  - Compression (encode value before replication)                │
│  - Convert anonymous functions to declarative specs             │
│                                                                 │
│  Module: Concord (lib/concord.ex)                               │
├─────────────────────────────────────────────────────────────────┤
│  LAYER 2: APPLY (Post-Commit Deterministic Mutation)            │
│                                                                 │
│  Runs on EVERY node during log replay.                          │
│  MUST be deterministic: same (meta, command, state) → same      │
│  (new_state, result, effects) on every node and every replay.   │
│                                                                 │
│  Responsibilities:                                              │
│  - Mutate authoritative state (the data map in machine state)   │
│  - Update ETS materialized views (KV store, indexes, etc.)      │
│  - Return Ra effects (optional: monitor, send_msg, release_cursor) │
│                                                                 │
│  FORBIDDEN inside apply:                                        │
│  - System.system_time, System.monotonic_time                    │
│  - :crypto.*, Enum.random, make_ref()                           │
│  - node(), self()                                               │
│  - File IO, network calls, Process.send                         │
│  - Application.get_env (config may differ across nodes)         │
│  - Anonymous functions in state                                 │
│                                                                 │
│  For timestamps: use Map.get(meta, :system_time) from Ra.       │
│                                                                 │
│  Module: Concord.StateMachine (lib/concord/state_machine.ex)    │
├─────────────────────────────────────────────────────────────────┤
│  LAYER 3: QUERY (Read-Only, No Mutations)                       │
│                                                                 │
│  Runs on a single node via :ra.consistent_query,                │
│  :ra.leader_query, or :ra.local_query.                          │
│  Reads from ETS (materialized view) for performance.            │
│  May use wall-clock time (for TTL expiry checks in reads).      │
│                                                                 │
│  Responsibilities:                                              │
│  - Point lookups (:ets.lookup)                                  │
│  - Range scans (:ets.select, :ets.match)                        │
│  - Aggregations (stats, counts)                                 │
│  - TTL filtering (expired keys are hidden from reads)           │
│                                                                 │
│  FORBIDDEN inside query:                                        │
│  - :ets.insert, :ets.delete (any mutation)                      │
│  - :ra.process_command (writes)                                 │
│                                                                 │
│  Module: Concord.StateMachine.query/2                           │
├─────────────────────────────────────────────────────────────────┤
│  LAYER 4: SIDE EFFECTS (Async, Best-Effort)                     │
│                                                                 │
│  Runs after apply or as Ra effects.                             │
│  Does NOT affect state machine determinism.                     │
│  May use non-deterministic values freely.                       │
│                                                                 │
│  Responsibilities:                                              │
│  - Telemetry events (:telemetry.execute)                        │
│  - Audit logging                                                │
│  - Event stream notifications (CDC)                             │
│  - Prometheus metrics                                           │
│  - OpenTelemetry traces                                         │
│                                                                 │
│  Implementation: Use Ra's `effects` return to schedule          │
│  side effects that Ra delivers after commit.                    │
│  Or use telemetry handlers attached outside the state machine.  │
│                                                                 │
│  Modules: Concord.Telemetry, Concord.AuditLog,                 │
│           Concord.EventStream, Concord.Prometheus               │
└─────────────────────────────────────────────────────────────────┘
```

### Authoritative State Structure

The machine state should carry ALL replicated state:

```elixir
{:concord_kv, %{
  # KV data lives in ETS (materialized view),
  # but snapshot captures it fully.

  # Index definitions (declarative, no closures)
  indexes: %{
    index_name => {:map_get, :field_name},
    ...
  },

  # Auth tokens
  tokens: %{
    "token_string" => %{permissions: [:read, :write], created_at: unix_ts},
    ...
  },

  # RBAC
  roles: %{
    :admin => [:*],
    :editor => [:read, :write, :delete],
    ...
  },
  role_grants: [{token, role}],
  acls: [{pattern, role, permissions}],

  # Tenants (definition + quotas, NOT usage counters)
  tenants: %{
    :acme => %{name: "ACME", namespace: "acme:*", quotas: %{...}, ...},
    ...
  }
}}
```

Usage counters, rate limiter state, and event stream state remain intentionally node-local — they are operational concerns that don't require consistency.

---

## 3. Snapshot Correctness

### 3.1 Snapshot Schema

```elixir
@snapshot_version 3

def snapshot({:concord_kv, data}) do
  snapshot_data = %{
    version: @snapshot_version,

    # Primary KV data — the bulk of the snapshot
    kv_entries: :ets.tab2list(:concord_store),

    # Index definitions (declarative specs, NOT closures)
    indexes: Map.get(data, :indexes, %{}),

    # Auth tokens
    tokens: Map.get(data, :tokens, %{}),

    # RBAC state
    roles: Map.get(data, :roles, %{}),
    role_grants: Map.get(data, :role_grants, []),
    acls: Map.get(data, :acls, []),

    # Tenant definitions (quotas, not usage counters)
    tenants: Map.get(data, :tenants, %{})
  }

  :telemetry.execute(
    [:concord, :snapshot, :created],
    %{size: length(snapshot_data.kv_entries), byte_size: :erlang.external_size(snapshot_data)},
    %{version: @snapshot_version}
  )

  snapshot_data
end
```

### 3.2 Snapshot Restore Path

```elixir
@impl :ra_machine
def snapshot_installed(snapshot, _metadata, {:concord_kv, _old_data}, _aux) do
  # Handle version migration
  snapshot = migrate_snapshot(snapshot)

  # 1. Restore KV data
  :ets.delete_all_objects(:concord_store)
  Enum.each(snapshot.kv_entries, fn entry ->
    :ets.insert(:concord_store, entry)
  end)

  # 2. Restore auth tokens into local ETS for fast lookups
  ensure_table(:concord_tokens)
  :ets.delete_all_objects(:concord_tokens)
  Enum.each(snapshot.tokens, fn {token, token_data} ->
    :ets.insert(:concord_tokens, {token, token_data})
  end)

  # 3. Restore RBAC into local ETS tables
  ensure_table(:concord_roles)
  ensure_table(:concord_role_grants)
  ensure_table(:concord_acls)
  :ets.delete_all_objects(:concord_roles)
  :ets.delete_all_objects(:concord_role_grants)
  :ets.delete_all_objects(:concord_acls)

  Enum.each(snapshot.roles, fn {role, perms} ->
    :ets.insert(:concord_roles, {role, perms})
  end)
  Enum.each(snapshot.role_grants, fn grant ->
    :ets.insert(:concord_role_grants, grant)
  end)
  Enum.each(snapshot.acls, fn acl ->
    :ets.insert(:concord_acls, acl)
  end)

  # 4. Restore tenant definitions
  ensure_table(:concord_tenants)
  :ets.delete_all_objects(:concord_tenants)
  Enum.each(snapshot.tenants, fn {id, tenant} ->
    :ets.insert(:concord_tenants, {id, tenant})
  end)

  # 5. Rebuild secondary index ETS tables from definitions + KV data
  rebuild_all_indexes(snapshot.indexes, snapshot.kv_entries)

  :telemetry.execute(
    [:concord, :snapshot, :installed],
    %{kv_size: length(snapshot.kv_entries)},
    %{version: snapshot.version}
  )

  # Return empty effects list
  []
end

defp ensure_table(name) do
  case :ets.whereis(name) do
    :undefined -> :ets.new(name, [:set, :protected, :named_table])
    _ref -> :ok
  end
end

defp rebuild_all_indexes(indexes, kv_entries) do
  # Drop any existing index tables
  Enum.each(indexes, fn {name, _spec} ->
    table = Index.index_table_name(name)
    case :ets.whereis(table) do
      :undefined -> :ok
      _ref -> :ets.delete(table)
    end
    :ets.new(table, [:set, :protected, :named_table])
  end)

  # Populate indexes from KV data
  Enum.each(kv_entries, fn {key, stored_data} ->
    {value, _expires_at} = extract_value(stored_data)
    decompressed = Compression.decompress(value)

    Enum.each(indexes, fn {name, extractor_spec} ->
      table = Index.index_table_name(name)
      Index.Extractor.index_value(table, key, decompressed, extractor_spec)
    end)
  end)
end

defp migrate_snapshot(snapshot) when is_list(snapshot) do
  # V1 format: bare list of KV entries
  %{
    version: 1,
    kv_entries: snapshot,
    indexes: %{},
    tokens: %{},
    roles: %{},
    role_grants: [],
    acls: [],
    tenants: %{}
  }
end

defp migrate_snapshot(%{version: v} = snapshot) when v < @snapshot_version do
  # Add missing fields with defaults for forward compatibility
  snapshot
  |> Map.put_new(:tokens, %{})
  |> Map.put_new(:roles, %{})
  |> Map.put_new(:role_grants, [])
  |> Map.put_new(:acls, [])
  |> Map.put_new(:tenants, %{})
  |> Map.put(:version, @snapshot_version)
end

defp migrate_snapshot(snapshot), do: snapshot
```

### 3.3 Bounding Snapshot Cost

Concern: `ets.tab2list/1` copies the entire table into the process heap. For large datasets (millions of keys), this causes memory spikes and GC pressure.

**Mitigation strategies (ordered by complexity):**

1. **Accept it for now.** If the dataset fits comfortably in 2× available memory, the spike is brief and acceptable. Ra snapshots are infrequent (default: every ~4000 applied entries). This is the recommendation for Concord's current scale.

2. **Use `:ets.foldl` with chunked serialization.** Instead of `tab2list`, iterate the table and write directly to a binary accumulator. This avoids the intermediate list allocation. Requires Ra's `snapshot_module` customization.

3. **Use `:ets.tab2file` + Ra external snapshots.** Write the ETS table to disk directly, then reference the file in the snapshot. Ra supports external snapshot references. This is the approach for very large datasets (10M+ keys).

### 3.4 Triggering Snapshots

Ra triggers snapshots automatically based on its internal heuristics. Concord should additionally call `ra:release_cursor/3` after significant state changes to hint that a snapshot is appropriate:

```elixir
# In apply_command, after large batch operations:
def apply_command(meta, {:restore_from_backup, _entries}, {:concord_kv, data}) do
  # ... apply the restore ...
  index = Map.get(meta, :index)
  effects = [{:release_cursor, index, {:concord_kv, data}}]
  {{:concord_kv, data}, :ok, effects}
end
```

---

## 4. Indexing Strategy

### 4.1 Declarative Extractor Model

Replace anonymous function extractors with serializable, version-safe specifications:

```elixir
defmodule Concord.Index.Extractor do
  @moduledoc """
  Declarative index extractor specifications.
  All specs are plain data (tuples/atoms) — no anonymous functions.
  Safe to serialize in Raft log and snapshots across code versions.
  """

  @type spec ::
    {:map_get, atom() | binary()}
    | {:nested, [atom() | binary()]}
    | {:identity}
    | {:element, non_neg_integer()}

  @spec extract(spec(), term()) :: term() | nil
  def extract({:map_get, key}, value) when is_map(value), do: Map.get(value, key)
  def extract({:nested, keys}, value) when is_map(value), do: get_in(value, keys)
  def extract({:identity}, value), do: value
  def extract({:element, n}, value) when is_tuple(value), do: elem(value, n)
  def extract(_, _), do: nil

  @spec index_value(atom(), binary(), term(), spec()) :: :ok
  def index_value(table, key, value, spec) do
    case extract(spec, value) do
      nil -> :ok
      indexed_val ->
        existing = case :ets.lookup(table, indexed_val) do
          [{^indexed_val, keys}] -> keys
          [] -> []
        end
        unless key in existing do
          :ets.insert(table, {indexed_val, [key | existing]})
        end
        :ok
    end
  end

  @spec remove_from_index(atom(), binary(), term(), spec()) :: :ok
  def remove_from_index(table, key, old_value, spec) do
    case extract(spec, old_value) do
      nil -> :ok
      indexed_val ->
        case :ets.lookup(table, indexed_val) do
          [{^indexed_val, keys}] ->
            new_keys = List.delete(keys, key)
            if new_keys == [] do
              :ets.delete(table, indexed_val)
            else
              :ets.insert(table, {indexed_val, new_keys})
            end
          [] -> :ok
        end
        :ok
    end
  end
end
```

### 4.2 ETS Table Specifications

| Table | Type | Access | Key | Value |
|-------|------|--------|-----|-------|
| `:concord_store` | `:set` | `:protected` | `binary()` (key) | `%{value: term(), expires_at: integer() \| nil}` |
| `:concord_index_{name}` | `:set` | `:protected` | `term()` (indexed value) | `[binary()]` (list of keys) |
| `:concord_tokens` | `:set` | `:protected` | `binary()` (token) | `%{permissions: [...], created_at: integer()}` |
| `:concord_roles` | `:set` | `:protected` | `atom()` (role name) | `[atom()]` (permissions) |
| `:concord_role_grants` | `:bag` | `:protected` | `binary()` (token) | `atom()` (role name) |
| `:concord_acls` | `:bag` | `:protected` | `{binary(), atom()}` | `[atom()]` (permissions) |
| `:concord_tenants` | `:set` | `:protected` | `atom()` (tenant id) | `map()` (tenant definition) |

All tables use `:protected` access — only the Ra server process (which owns the tables via `init/1`) can write to them. All other processes get read-only access.

### 4.3 Rebuild Strategy

Indexes are rebuilt in three scenarios:

1. **Snapshot install** — `snapshot_installed/4` rebuilds all indexes from the snapshot's KV data + index definitions. See section 3.2.

2. **Log replay after restart** — When Ra replays log entries, each `:put`, `:delete`, `:put_many`, `:delete_many` command triggers index updates in `apply_command`. The index ETS tables must exist before replay starts. `init/1` should create them.

3. **Explicit reindex** — After creating a new index on existing data, the index table is empty. A `{:reindex, index_name}` command should iterate all KV entries and populate the index. This must go through Raft so all nodes do it:

```elixir
def apply_command(_meta, {:reindex, name}, {:concord_kv, data}) do
  indexes = Map.get(data, :indexes, %{})
  case Map.get(indexes, name) do
    nil -> {{:concord_kv, data}, {:error, :not_found}, []}
    spec ->
      table = Index.index_table_name(name)
      :ets.delete_all_objects(table)
      all_entries = :ets.tab2list(:concord_store)
      Enum.each(all_entries, fn {key, stored_data} ->
        {value, _exp} = extract_value(stored_data)
        decompressed = Compression.decompress(value)
        Index.Extractor.index_value(table, key, decompressed, spec)
      end)
      {{:concord_kv, data}, :ok, []}
  end
end
```

### 4.4 Failure and Recovery Semantics

- **Index table missing at startup:** `init/1` recreates all index tables from `data.indexes` definitions. On snapshot install, they're rebuilt from scratch.
- **Index inconsistency:** If an index becomes inconsistent (bug, partial failure), `{:reindex, name}` through Raft fixes it on all nodes simultaneously.
- **Node crash during index update:** Ra replays the log entry, which re-applies the index update. No inconsistency possible because the same command produces the same index state.

---

## 5. High-Throughput Command & Query APIs

### 5.1 Command Path (Writes)

```elixir
# Single write — goes through Raft consensus
:ra.process_command(server_id, {:put, key, value, expires_at}, timeout)

# Batch write — single Raft log entry, amortized consensus cost
:ra.process_command(server_id, {:put_many, [{k1,v1,exp1}, {k2,v2,exp2}, ...]}, timeout)
```

**Batching strategy:** The biggest throughput lever is batching. A single `put_many` of 100 entries incurs one Raft round-trip, one WAL write, and one quorum ack — vs. 100 individual round-trips. The API layer should encourage batching:

```elixir
# Application-level batching with configurable flush interval:
# Accumulate writes for up to 1ms, then flush as a single put_many.
# This is a client-side optimization, not a state machine change.
```

**Pipeline mode:** Ra supports pipelining — sending the next command before the previous one is committed. For independent writes, use `:ra.pipeline_command/3`:

```elixir
# Fire-and-forget pipelining (correlation managed by caller)
:ra.pipeline_command(server_id, {:put, key, value, expires_at})
# Returns immediately. Caller can batch multiple pipeline calls.
# Use :ra.pipeline_command/4 with a correlation term if you need to track results.
```

### 5.2 Query Path (Reads)

```
┌─────────────────────────────────────────────────────────┐
│                    Read Consistency Levels               │
├──────────────┬──────────────────┬───────────────────────┤
│  :eventual   │  :leader         │  :strong              │
│              │                  │                       │
│  :ra.local_  │  :ra.leader_     │  :ra.consistent_      │
│  query/3     │  query/3         │  query/3              │
│              │                  │                       │
│  Any node    │  Leader node     │  Leader + quorum      │
│  May be      │  May be stale    │  heartbeat            │
│  stale       │  by 1 heartbeat  │  Linearizable         │
│              │                  │                       │
│  ~0.1ms      │  ~1-2ms          │  ~5-10ms              │
│  (ETS only)  │  (network hop)   │  (+ quorum round)     │
└──────────────┴──────────────────┴───────────────────────┘
```

**Hot-path optimization:** For `:eventual` reads, skip Ra entirely and read from local ETS:

```elixir
# FASTEST possible read — direct ETS lookup, no Ra overhead
def get_local(key) do
  case :ets.lookup(:concord_store, key) do
    [{^key, stored_data}] ->
      case extract_value(stored_data) do
        {value, expires_at} ->
          if expired_now?(expires_at) do
            {:error, :not_found}
          else
            {:ok, Compression.decompress(value)}
          end
        _ -> {:error, :invalid_format}
      end
    [] -> {:error, :not_found}
  end
end
```

This bypasses Ra query wrapping entirely. The trade-off is that reads may return stale data (not yet applied log entries). For many use cases (caches, configuration), this is acceptable.

### 5.3 Read Scaling

In a Raft cluster, only the leader handles consistent reads. To scale reads:

1. **`:eventual` on followers:** Distribute `local_query` across all nodes. Each node's ETS table is updated as log entries are applied. Staleness is bounded by replication lag (typically milliseconds).

2. **`:leader` for most reads:** `leader_query` reads from the leader's ETS directly. No quorum overhead. Stale by at most one uncommitted entry.

3. **`:strong` for critical reads only:** Use `consistent_query` sparingly — for operations where reading stale data would cause correctness issues (e.g., compare-and-swap preconditions).

### 5.4 Avoiding Bottlenecks

| Bottleneck | Mitigation |
|-----------|------------|
| Ra leader single-threaded apply | Batch commands (`put_many`). Keep `apply_command` fast — avoid heavy computation. |
| ETS single-table contention | `:set` tables have per-key lock granularity. No contention for different keys. |
| Network round-trips | Pipeline commands. Use `local_query` for reads. |
| Snapshot pause | Ra snapshots are async. No apply stall during snapshot. |
| WAL fsync latency | Ra batches fsync across multiple log entries. |

---

## 6. Hardening Checklist

### Priority 0: CRITICAL (Fix Before Any Production Use)

- [ ] **Remove wall-clock time from `apply_command`**
  - File: `lib/concord/state_machine.ex:31,34`
  - Change `current_timestamp()` to use `Map.get(meta, :system_time)` from Ra metadata
  - Change `expired?/1` inside apply_command to accept a `now` parameter derived from meta
  - Keep wall-clock `expired?/1` in query handlers (reads are not replayed)
  - Affects: `:cleanup_expired` (line 243), `:touch` (line 206), `:touch_many` (line 379)

- [ ] **Fix `runtime.exs` data directory**
  - File: `config/runtime.exs:11`
  - Current: `Path.join(System.tmp_dir!(), "concord_data/#{node_name}")` — writes to `/tmp`
  - Fix: Gate to non-production, or remove the override entirely:
    ```elixir
    if config_env() in [:dev, :test] do
      config :concord, data_dir: Path.join(System.tmp_dir!(), "concord_data/#{node_name}")
    end
    ```

- [ ] **Replace anonymous functions in Raft log/state with declarative specs**
  - File: `lib/concord/index.ex:112` — index extractor functions
  - File: `lib/concord.ex:204,260` — `put_if`/`delete_if` condition functions
  - Create `lib/concord/index/extractor.ex` with declarative spec evaluation
  - Update `create_index/3` API to accept spec tuples instead of functions
  - Remove `condition` option from `put_if`/`delete_if` or convert to pre-consensus evaluation

### Priority 1: HIGH (Fix Before Multi-Node Deployment)

- [ ] **Fix snapshot to capture complete state**
  - File: `lib/concord/state_machine.ex:675-685`
  - Add `@impl :ra_machine` annotation to `snapshot/1`
  - Return `%{version: N, kv_entries: ..., indexes: ..., tokens: ..., roles: ..., ...}`
  - Implement `migrate_snapshot/1` for backward compatibility with existing V1 snapshots

- [ ] **Fix `snapshot_installed/4` to restore complete state**
  - File: `lib/concord/state_machine.ex:658-673`
  - Restore all ETS tables (tokens, roles, grants, ACLs, tenants)
  - Rebuild secondary index ETS tables from index definitions + KV data

- [ ] **Route auth token mutations through Raft**
  - File: `lib/concord/auth.ex` — replace direct ETS writes with Ra commands
  - Add `apply_command` clauses: `{:auth_create_token, token, permissions}`, `{:auth_revoke_token, token}`
  - Generate token pre-consensus, replicate the value
  - Keep `verify_token/1` as a local ETS read (no Raft needed for verification)

- [ ] **Route RBAC mutations through Raft**
  - File: `lib/concord/rbac.ex` — replace all direct ETS writes
  - Add `apply_command` clauses for all role/grant/ACL operations
  - Keep `check_permission/3` as a local ETS read

- [ ] **Route tenant definition mutations through Raft**
  - File: `lib/concord/multi_tenancy.ex` — replace create/delete/update_quota ETS writes
  - Keep usage counters and rate limiting as node-local (intentionally approximate)

- [ ] **Fix backup restore to go through Raft**
  - File: `lib/concord/backup.ex:340-344` — `apply_backup/1`
  - Submit backup entries as a Raft command `{:restore_from_backup, entries}`
  - All nodes apply the same restore atomically

### Priority 2: MEDIUM

- [ ] **Make all ETS tables `:protected`**
  - File: `lib/concord/state_machine.ex:42` — `:concord_store`
  - File: `lib/concord/state_machine.ex:421` — index tables
  - All ETS tables created in `init/1` and `apply_command` should use `:protected`
  - Note: The Ra server process owns these tables. `init/1` runs in the Ra process, so it's the owner.

- [ ] **Move `get_many` from apply_command to query**
  - File: `lib/concord/state_machine.ex:330-348`
  - Remove the `apply_command` clause for `{:get_many, keys}`
  - Add a `query({:get_many, keys}, ...)` clause (already partially exists at line 606)
  - Update `Concord.get_many/2` to use query path instead of command path

- [ ] **Add explicit log compaction via `release_cursor`**
  - File: `lib/concord/state_machine.ex` — in `apply_command` return effects
  - Add `{:release_cursor, index, machine_state}` effect after large operations
  - Consider periodic cursor release (e.g., every 1000 applied entries)

- [ ] **Remove hardcoded startup sleep**
  - File: `lib/concord/application.ex:132` — `Process.sleep(1000)`
  - Replace with a loop that checks Ra system readiness:
    ```elixir
    defp wait_for_ra_system(retries \\ 20) do
      case :ra_system.status(default) do
        :running -> :ok
        _ when retries > 0 ->
          Process.sleep(100)
          wait_for_ra_system(retries - 1)
        _ -> {:error, :ra_system_not_ready}
      end
    end
    ```

### Priority 3: LOW (Polish)

- [ ] **Move telemetry out of apply_command hot path**
  - Consider emitting telemetry as a Ra effect (post-commit) instead of inline
  - Or accept the overhead — `:telemetry.execute` is fast (~1μs)

- [ ] **Add `@impl :ra_machine` to `snapshot/1`**
  - File: `lib/concord/state_machine.ex:675`
  - Verify Ra 2.17.1 expects this callback name and arity

- [ ] **Add compression config consistency check**
  - On cluster join, verify compression settings match across nodes
  - Mismatched settings cause different nodes to store different binary representations

---

## 7. Architecture Diagram

```
                         ┌─────────────┐
                         │  Client App │
                         └──────┬──────┘
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
           ┌───────────────┐       ┌───────────────┐
           │ LAYER 1:      │       │ LAYER 3:      │
           │ Validation    │       │ Query          │
           │ (Pre-Raft)    │       │ (Read-only)    │
           │               │       │               │
           │ • Auth check  │       │ • ETS lookup  │
           │ • Key validate│       │ • Decompress  │
           │ • TTL→expires │       │ • TTL filter  │
           │ • Compress    │       │ • Index scan  │
           │ • Token gen   │       │               │
           └───────┬───────┘       └───────┬───────┘
                   │                       │
                   ▼                       │
         ┌─────────────────┐               │
         │  Ra Consensus   │               │
         │  (Raft)         │               │
         │                 │               │
         │  • WAL append   │               │
         │  • Quorum ack   │               │
         │  • Log replicate│               │
         └────────┬────────┘               │
                  │                        │
                  ▼                        │
         ┌─────────────────┐               │
         │ LAYER 2:        │               │
         │ Apply           │               │
         │ (Deterministic) │               │
         │                 │               │
         │ • Mutate state  │◄──────────────┘
         │ • Update ETS    │   (query reads from
         │ • Update indexes│    same ETS tables)
         │ • Return result │
         └────────┬────────┘
                  │
                  ▼
         ┌─────────────────┐
         │ LAYER 4:        │
         │ Side Effects    │
         │ (Best-effort)   │
         │                 │
         │ • Telemetry     │
         │ • Audit log     │
         │ • Event stream  │
         │ • Prometheus    │
         └─────────────────┘

         ┌─────────────────────────────────────────┐
         │              ETS Tables                  │
         │         (Materialized Views)             │
         │                                          │
         │  :concord_store      ← KV data           │
         │  :concord_index_*    ← Secondary indexes  │
         │  :concord_tokens     ← Auth tokens        │
         │  :concord_roles      ← RBAC roles         │
         │  :concord_role_grants← Role grants        │
         │  :concord_acls       ← ACL rules          │
         │  :concord_tenants    ← Tenant defs        │
         │                                          │
         │  ALL :protected, owned by Ra process      │
         │  ALL rebuildable from Raft log + snapshot  │
         └─────────────────────────────────────────┘

         ┌─────────────────────────────────────────┐
         │              Disk (Ra)                   │
         │                                          │
         │  {data_dir}/                             │
         │    ├── wal/           ← Write-ahead log   │
         │    ├── segments/      ← Compacted log     │
         │    ├── snapshots/     ← State snapshots   │
         │    └── meta           ← term, votedFor    │
         │                                          │
         │  NEVER /tmp in production                │
         └─────────────────────────────────────────┘
```

---

## 8. Deterministic Replay Safety Checklist

These invariants must be verified for every PR that touches the state machine:

### The Five Rules

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│  RULE 1: NO WALL-CLOCK TIME IN APPLY                            │
│                                                                  │
│  apply_command must NEVER call:                                  │
│  • System.system_time/1                                         │
│  • System.monotonic_time/0                                      │
│  • DateTime.utc_now/0                                           │
│  • :os.timestamp/0                                              │
│  • :erlang.system_time/1                                        │
│                                                                  │
│  Use Map.get(meta, :system_time) instead.                       │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  RULE 2: NO RANDOMNESS IN APPLY                                 │
│                                                                  │
│  apply_command must NEVER call:                                  │
│  • :crypto.strong_rand_bytes/1                                  │
│  • :rand.uniform/0                                              │
│  • Enum.random/1                                                │
│  • make_ref/0                                                   │
│  • :erlang.unique_integer/0                                     │
│                                                                  │
│  Generate random values pre-consensus and embed in command.      │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  RULE 3: NO CLOSURES IN RAFT STATE OR LOG                       │
│                                                                  │
│  Commands and state must NEVER contain:                         │
│  • Anonymous functions (fn -> ... end)                           │
│  • Captured function references (&Module.fun/arity)             │
│  • Any term that serializes differently across code versions    │
│                                                                  │
│  Use declarative specs (tuples of atoms/binaries/integers).      │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  RULE 4: NO EXTERNAL IO IN APPLY                                │
│                                                                  │
│  apply_command must NEVER:                                      │
│  • Read from disk (File.read, :file.read_file)                  │
│  • Call external processes (GenServer.call, send)                │
│  • Make network requests                                        │
│  • Call Application.get_env (config may differ across nodes)    │
│                                                                  │
│  Exception: ETS writes are OK (they are the materialized view). │
│  Exception: :telemetry.execute is OK (observation, not state).  │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  RULE 5: SNAPSHOT CAPTURES ALL STATE                            │
│                                                                  │
│  snapshot/1 must return EVERYTHING needed to reconstruct         │
│  the state machine from scratch:                                │
│  • All KV data                                                  │
│  • All index definitions                                        │
│  • All auth tokens                                              │
│  • All RBAC configuration                                       │
│  • All tenant definitions                                       │
│                                                                  │
│  Test: Delete all ETS tables → install snapshot → verify that   │
│  the system behaves identically.                                │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### PR Review Checklist

For any code change that touches `lib/concord/state_machine.ex`:

- [ ] Does the change call any system time function inside `apply_command`?
- [ ] Does the change introduce any randomness inside `apply_command`?
- [ ] Does the change store anonymous functions in the machine state?
- [ ] Does the change read application config inside `apply_command`?
- [ ] Is the new state captured by `snapshot/1`?
- [ ] Is the new state restored by `snapshot_installed/4`?
- [ ] Can two nodes replay the same log entry and arrive at identical state?
- [ ] Are new ETS tables created with `:protected` access?

---

## 9. Step-by-Step Migration Plan

This plan is designed to be executed as a sequence of independent, backwards-compatible PRs. Each PR is testable in isolation.

### Phase 1: Fix Raft Safety Violations (Critical)

**PR 1: Deterministic time in apply_command**

Scope: `lib/concord/state_machine.ex`

1. Add a `defp meta_time(meta)` helper that extracts `Map.get(meta, :system_time)` and converts to seconds
2. Change `apply_command(meta, :cleanup_expired, ...)` to pass `meta_time(meta)` to expiry checks
3. Change `apply_command(meta, {:touch, ...}, ...)` to use `meta_time(meta)` for new expiry
4. Change `apply_command(meta, {:touch_many, ...}, ...)` similarly
5. Leave `query/2` handlers using `System.system_time/1` (queries are not replayed)
6. Add tests that verify: replaying the same cleanup command at different wall-clock times produces the same result

**PR 2: Fix runtime.exs data directory**

Scope: `config/runtime.exs`

1. Gate the `/tmp` override to `config_env() in [:dev, :test]`
2. In production, respect the `data_dir` from `config/prod.exs` or `CONCORD_DATA_DIR` env var

**PR 3: Replace anonymous functions with declarative specs**

Scope: `lib/concord/index.ex`, `lib/concord/index/extractor.ex` (new), `lib/concord/state_machine.ex`, `lib/concord.ex`

1. Create `Concord.Index.Extractor` module with spec-based extraction
2. Change `Index.create/3` to accept spec tuples instead of functions
3. Update `apply_command({:create_index, ...})` to store specs in state
4. Deprecate (but keep for one version) the function-based API with a warning
5. For `put_if`/`delete_if`: remove `condition` option; keep only `expected` (CAS)
6. Add migration path in `snapshot_installed` for legacy function-based index definitions

### Phase 2: Complete Snapshot Coverage

**PR 4: Comprehensive snapshot format**

Scope: `lib/concord/state_machine.ex`

1. Increment `@snapshot_version` to 3
2. Update `snapshot/1` to return `%{version: 3, kv_entries: ..., indexes: ..., ...}`
3. Update `snapshot_installed/4` to restore all ETS tables
4. Add `migrate_snapshot/1` for V1 (bare list) and V2 backward compatibility
5. Add `@impl :ra_machine` annotation to `snapshot/1`
6. Add test: snapshot → clear all ETS → install snapshot → verify all tables restored

### Phase 3: Route All Mutations Through Raft

**PR 5: Auth tokens through Raft**

Scope: `lib/concord/auth.ex`, `lib/concord/state_machine.ex`

1. Add `apply_command` clauses for `{:auth_create_token, ...}`, `{:auth_revoke_token, ...}`
2. Update `Auth.create_token/1` to generate token pre-consensus, then submit command
3. Keep `Auth.verify_token/1` as local ETS read (no change)
4. Update `snapshot/1` and `snapshot_installed/4` to include tokens
5. Add `data.tokens` to machine state

**PR 6: RBAC through Raft**

Scope: `lib/concord/rbac.ex`, `lib/concord/state_machine.ex`

1. Add `apply_command` clauses for all RBAC mutations
2. Update `RBAC.create_role/2`, `grant_role/2`, etc. to submit Ra commands
3. Keep `RBAC.check_permission/3` as local ETS read
4. Add `data.roles`, `data.role_grants`, `data.acls` to machine state
5. Update snapshot format

**PR 7: Tenant definitions through Raft**

Scope: `lib/concord/multi_tenancy.ex`, `lib/concord/state_machine.ex`

1. Add `apply_command` clauses for tenant create/delete/update_quota
2. Keep usage counters and rate limiting as node-local
3. Add `data.tenants` to machine state
4. Update snapshot format

**PR 8: Fix backup restore**

Scope: `lib/concord/backup.ex`, `lib/concord/state_machine.ex`

1. Add `apply_command` clause for `{:restore_from_backup, entries}`
2. Update `Backup.restore/2` to submit through Ra instead of direct ETS writes
3. Add `{:release_cursor, ...}` effect after restore to trigger snapshot

### Phase 4: Hardening

**PR 9: Protected ETS tables**

Scope: `lib/concord/state_machine.ex`

1. Change all `:ets.new` calls to use `:protected` instead of `:public`
2. Verify that all ETS writes happen only in the Ra process (via `apply_command` or `init/1` or `snapshot_installed/4`)
3. Fix any code that writes to ETS from outside the Ra process (this PR may require fixing `Index.reindex/1` to go through Raft)

**PR 10: Log compaction and readiness**

Scope: `lib/concord/state_machine.ex`, `lib/concord/application.ex`

1. Add `{:release_cursor, index, state}` to effects in `apply_command` for large operations
2. Replace `Process.sleep(1000)` with proper Ra system readiness check
3. Move `get_many` from command path to query path

### Compatibility Notes

- **Snapshot backward compatibility:** `migrate_snapshot/1` handles V1 (bare list) format from existing deployments. During rolling upgrade, followers may receive old-format snapshots.

- **Command backward compatibility:** New command tuples (`:auth_create_token`, etc.) are unknown to old nodes. During rolling upgrade, the leader must be upgraded first. Old followers receiving unknown commands fall through to the catch-all `apply_command` clause (line 453) which returns `{state, :ok, []}` — safe but no-op. After all nodes are upgraded, the new commands take effect.

- **Index extractor migration:** Old snapshots contain anonymous functions for index extractors. `migrate_snapshot/1` should drop these (they can't be safely deserialized after upgrade) and log a warning. Users must recreate indexes after upgrade using the new declarative API.

- **State machine version:** Increment `version/0` to `3` in the final PR. Ra uses this to coordinate machine version across the cluster.
