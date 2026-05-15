# Transaction API

**Status**: Proposal
**Depends on**: Revisioned KV, Range/Prefix
**Required by**: Any atomic multi-key operation

## 1. Goals

A single primitive that supports:

- Atomic multi-key reads, writes, and deletes
- Optimistic concurrency via revision-based and value-based preconditions
- Conditional branching (success/failure) in one round-trip
- Deterministic, replayable evaluation inside the Raft state machine
- Safe retry under client timeout via idempotency keys

## 2. Non-goals

Each is a deliberate restraint:

- **Interactive transactions** (`BEGIN ... COMMIT`). Requires per-client state in the state machine; unbounded-duration locks. Out.
- **Nested transactions**. One txn = one Raft entry. Composition via sequential txns from the client.
- **Range-scoped compare predicates** ("all keys with prefix P have status=X"). Breaks determinism cost predictability. Out.
- **Server-side functions / callbacks / Lua**. The Raft log carries plain data only. No anonymous functions, no closures, no PIDs anywhere in a txn spec.
- **OR semantics in compare lists**. AND only.
- **Atomic increment / decrement primitives**. Read-then-CAS is sufficient.

## 3. Transaction spec

The canonical form is a plain map:

```elixir
%{
  idempotency_key: binary() | nil,
  compare: [compare()],
  success: [operation()],
  failure: [operation()],
  options: %{return_events: boolean()}
}
```

Submitted via:

```elixir
Concord.Txn.commit(spec)
# => {:ok, %Concord.Txn.Result{}} | {:error, reason}
```

**Semantics**: all compares are evaluated atomically against pre-transaction state. If all hold (AND), `success` ops execute in order; otherwise `failure` ops execute in order. The chosen branch's operations are atomic — either all happen or none.

## 4. Compare predicates

Each compare targets exactly one key. The full set:

```elixir
{:exists,          key, op, boolean()}
{:value,           key, op, term()}
{:field,           key, path, op, term()}
{:version,         key, op, integer()}
{:create_revision, key, op, integer()}
{:mod_revision,    key, op, integer()}
{:lease,           key, op, lease_id_or_nil}
{:ttl,             key, op, integer_or_nil}
```

Operators (apply to all comparable fields):

```elixir
:==  :!=  :>  :>=  :<  :<=
```

For `:value` and `:lease`, only `:==` and `:!=` are defined.

### Compare against absent keys

| Predicate | Behavior on absent key |
|---|---|
| `:exists` | evaluates against `false` |
| `:value` | evaluates against `nil` |
| `:field` | evaluates against `nil` (path returns nothing) |
| `:version` | evaluates against `0` |
| `:create_revision` | evaluates against `0` |
| `:mod_revision` | evaluates against `0` |
| `:lease` | evaluates against `nil` |
| `:ttl` | evaluates against `nil` |

### Field path compares

`{:field, key, path, op, value}` is the workhorse for structured values:

```elixir
# Value at key is %{status: :queued, priority: 50, body: "..."}
{:field, key, [:status], :==, :queued}
{:field, key, [:priority], :>=, 50}
{:field, key, [:metadata, :owner], :==, "node-1"}
```

The `path` extractor reuses the **existing index extractor module's declarative specs**:

```elixir
{:map_get, key}    # extract one map key
{:nested, keys}    # extract a path of map keys
{:identity}        # whole value
```

This is intentional reuse: the same extractor that powers Concord's indexes powers transaction field compares. It's already deterministic, data-only, and tested. No new abstraction needed.

For non-map values (or when the path doesn't resolve), the extracted value is `nil`. Compares against `nil` follow standard ordering rules (`nil < any value`).

## 5. Operations

Operations target a **selector** rather than a raw key for read/delete:

```elixir
@type selector ::
        {:key,    binary()}
        | {:prefix, binary()}
        | {:range,  start :: binary(), end_exclusive :: binary()}

@type operation ::
        {:get,    selector, opts}
        | {:put,    binary(), term(), opts}    # put is always single-key
        | {:delete, selector, opts}
        | {:touch,  binary(), ttl :: integer(), opts}
```

The selector tag unifies single-key, prefix, and range under one shape. `{:prefix, p}` is sugar for `{:range, p, p <> <<0xFF, 0xFF, ...>>}`.

### `:get`

```elixir
{:get, {:key, "/config/api"}, %{}}

{:get, {:prefix, "/notes/"}, %{
  limit:       100,
  keys_only:   false,
  count_only:  false
}}

{:get, {:range, "a", "z"}, %{limit: 50}}
```

opts (all optional):
- `limit: pos_integer` — max results (mandatory for `:prefix` / `:range`)
- `keys_only: bool` — omit values
- `count_only: bool` — return count only
- `revision: pos_integer` — read at a specific revision (within the txn's snapshot)

### `:put` (single-key only)

```elixir
{:put, "/config/api", new_value, %{
  prev_kv:      true,
  content_type: "application/json",
  metadata:     %{author: "ci"},
  ttl:          30,
  lease:        lease_id,
  ignore_value: false,
  ignore_lease: false
}}
```

opts:
- `prev_kv: bool` — include previous Record in response
- `content_type: binary | nil` — store content_type hint
- `metadata: map` — application metadata to attach
- `ttl: integer` — anonymous TTL (creates anonymous lease)
- `lease: lease_id` — attach to existing lease
- `ignore_value: true` — keep existing value, only update lease/ttl
- `ignore_lease: true` — keep existing lease attachment

### `:delete`

```elixir
{:delete, {:key, "/k"},          %{prev_kv: true}}
{:delete, {:prefix, "/tmp/"},    %{}}
{:delete, {:range, "x1", "x9"},  %{prev_kv: false}}
```

opts:
- `prev_kv: bool` — return deleted records in response

### `:touch`

Refresh TTL without changing value:

```elixir
{:touch, "/locks/build", 30, %{}}
```

The `:touch` op is semantically distinct from `put with ignore_value: true`: touch always extends the TTL of an existing key; if the key doesn't exist, the op no-ops (returns `{:not_found}` in the response).

## 6. Operation ordering within a branch

Defined behavior, stated explicitly:

```text
1. Evaluate all compare predicates against pre-transaction committed state.
2. Select success or failure branch.
3. If selected branch contains mutating ops, allocate one new commit revision.
4. Execute selected operations in declaration order.
5. Reads inside the selected branch observe earlier writes in the same branch.
6. Commit all mutations atomically at the allocated revision.
7. Publish change events after commit.
```

Step 5 is the **read-your-writes** rule. Example:

```elixir
%{
  compare: [],
  success: [
    {:put, "/a", 1, %{}},
    {:get, {:key, "/a"}, %{}}      # sees value 1
  ],
  failure: []
}
```

This allows server-side composition: write then conditionally read derived state, all within one atomic txn.

All writes within one txn share the **same** `mod_revision`. If a txn writes 3 keys, all 3 have identical `mod_revision`. Sync consumers can group by revision to reconstruct atomic boundaries.

## 7. Result format

```elixir
%Concord.Txn.Result{
  succeeded: boolean(),
  revision:  non_neg_integer(),
  responses: [response()]
}

@type response ::
        {:get,    selector, %{kvs: [Record.t()], count: non_neg_integer}}
        | {:put,    binary(), %{prev_kv: Record.t() | nil}}
        | {:delete, selector, %{deleted: non_neg_integer, prev_kvs: [Record.t()]}}
        | {:touch,  binary(), %{ttl: integer | :not_found}}
```

Example:

```elixir
{:ok,
 %Concord.Txn.Result{
   succeeded: true,
   revision: 1843,
   responses: [
     {:put, "/k", %{prev_kv: nil}},
     {:put, "/k/notes/001", %{prev_kv: nil}}
   ]
 }}
```

**Critical**: `succeeded` reflects which branch ran. A txn that took the `failure` branch is a successful txn; it returns `{:ok, %Result{succeeded: false, ...}}`. Surface errors (`:no_leader`, `:timeout`, `:invalid_txn`) are returned as `{:error, reason}`.

For a `failure` branch, the responses typically contain `:get` ops that read back the compared keys, so the client learns *why* in the same round-trip:

```elixir
{:ok,
 %Concord.Txn.Result{
   succeeded: false,
   revision: 1842,                # unchanged; no mutation happened
   responses: [
     {:get, {:key, "/k"},
      %{kvs: [%Record{value: ..., mod_revision: 1820, ...}], count: 1}}
   ]
 }}
```

## 8. CRUD as transaction sugar

Once transactions exist, CRUD wrappers compile to txn:

```elixir
# Create only if absent
Concord.KV.create(key, value)
# →
%{
  compare: [{:exists, key, :==, false}],
  success: [{:put, key, value, %{}}],
  failure: [{:get, {:key, key}, %{}}]
}

# Replace only if present
Concord.KV.replace(key, value)
# →
%{
  compare: [{:exists, key, :==, true}],
  success: [{:put, key, value, %{prev_kv: true}}],
  failure: []
}

# Update if mod_revision matches
Concord.KV.update_if(key, value, mod_revision: 1842)
# →
%{
  compare: [{:mod_revision, key, :==, 1842}],
  success: [{:put, key, value, %{prev_kv: true}}],
  failure: [{:get, {:key, key}, %{}}]
}

# Delete if mod_revision matches
Concord.KV.delete_if(key, mod_revision: 1842)
# →
%{
  compare: [{:mod_revision, key, :==, 1842}],
  success: [{:delete, {:key, key}, %{prev_kv: true}}],
  failure: [{:get, {:key, key}, %{}}]
}
```

Existing `Concord.put_if/3` migrates to a thin wrapper around `update_if`.

## 9. Idempotency keys

Distributed clients will sometimes time out after a transaction actually committed. They need safe retry.

### API

```elixir
Concord.Txn.commit(spec, idempotency_key: "client-1:req-42")
```

### State machine cache

The state machine maintains a bounded cache:

```elixir
requests: %{
  "client-1:req-42" => %{
    request_hash: binary(),   # hash of the txn spec
    revision:     pos_integer(),
    result:       %Concord.Txn.Result{},
    cached_at:    pos_integer()  # meta_time at cache insert
  }
}
```

### Rules

```text
same idempotency_key + same request_hash
  → return cached result

same idempotency_key + different request_hash
  → {:error, :idempotency_conflict}

unknown idempotency_key
  → execute normally; cache result
```

### Retention

Two retention policies, configurable:

- **TTL-bound**: drop entries older than `idempotency_cache_ttl` (default 5 minutes)
- **Revision-bound**: drop entries with `revision < current_revision - N` (default N = 10,000)

Recommend revision-bound by default — couples retention to write activity rather than wall time. Idle clusters don't grow the cache.

### Cache eviction

Cache is bounded; default max entries 100,000. When full, LRU eviction. Entries are serialized in snapshots.

## 10. TTL inside transactions

TTL is relative in the spec, absolute after apply.

```elixir
{:put, "/locks/build", value, %{ttl: 30}}
```

In `apply/3`:

```elixir
expires_at = meta_time(meta) + 30
```

Concord's existing `meta_time/1` helper is the canonical time source. Wall-clock reads inside the state machine are forbidden.

Lease-attached puts inherit the lease's TTL; specifying both `ttl` and `lease` is an `:invalid_txn` error.

## 11. Validation

All validation happens at the API boundary, before the spec becomes a Raft command. Limits live in config:

```elixir
config :concord, :txn,
  max_compare_ops: 64,
  max_success_ops: 128,
  max_failure_ops: 128,
  max_txn_bytes:   1_000_000,
  max_range_limit: 1_000
```

Rejection reasons (returned as `{:error, {:invalid_txn, reason}}`):

```text
:too_many_compares          | :too_many_success_ops    | :too_many_failure_ops
:spec_too_large             | :empty_key               | :key_too_large
:value_too_large            | :unsupported_op          | :unsupported_compare_field
:unsupported_compare_op     | :invalid_ttl             | :missing_range_limit
:ttl_and_lease_conflict     | :function_in_spec        | :pid_in_spec
:ref_in_spec                | :duplicate_compare       | :unknown_lease
```

**Critical**: walking the spec for functions/PIDs/refs is mandatory. Even nested inside `metadata` or `value`, these break Raft determinism and must be rejected before submission.

## 12. State machine command

One new internal command:

```elixir
{:txn, txn_spec}
```

Pseudo-implementation:

```text
def apply_command(meta, {:txn, spec}, {:concord_kv, data}):
    with :ok = validate(spec):
        case check_idempotency(spec, data):
            {:hit, cached_result}:
                return (data, {:ok, cached_result}, [])

            :miss:
                compare_ok? = eval_compares(spec.compare, data, meta_time(meta))
                branch      = if compare_ok? then spec.success else spec.failure

                mutating?       = any_mutating_op?(branch)
                commit_revision =
                    if mutating? then data.revision + 1 else data.revision

                (responses, events, new_kv_state) =
                    execute_ops(branch, %{
                        meta: meta,
                        revision: commit_revision,
                        kv_state: data
                    })

                new_data =
                    new_kv_state
                    |> maybe_set_revision(mutating?, commit_revision)
                    |> maybe_cache_idempotency(spec, responses, commit_revision, meta)

                result = %Result{
                    succeeded: compare_ok?,
                    revision:  commit_revision,
                    responses: responses
                }

                effects =
                    if events == [] then []
                    else [{:send_msg, Concord.Sync.Dispatcher, {:changes, events}}]

                return ({:concord_kv, new_data}, {:ok, result}, effects)
```

Important properties:

- Validation before mutation
- Compares evaluated against pre-txn state
- One revision per mutating txn
- Events dispatched after commit (via Ra effects, not synchronously)
- No anonymous functions, no wall clock

## 13. Examples

### Atomic append-and-update

```elixir
note_key = "/notes/e-001"

Concord.Txn.commit(%{
  compare: [
    {:exists, note_key, :==, false},
    {:mod_revision, "/state", :==, known_revision}
  ],
  success: [
    {:put, note_key, note_entry, %{content_type: "text/markdown"}},
    {:put, "/state", updated_state, %{prev_kv: true}}
  ],
  failure: [
    {:get, {:key, "/state"}, %{}}
  ]
})
```

Either both writes happen, or neither.

### Conditional ownership transfer

```elixir
Concord.Txn.commit(%{
  compare: [
    {:field, "/resource", [:owner], :==, current_owner}
  ],
  success: [
    {:put, "/resource", updated, %{prev_kv: true}}
  ],
  failure: [
    {:get, {:key, "/resource"}, %{}}
  ]
})
```

### Bounded delete by prefix

```elixir
Concord.Txn.commit(%{
  compare: [],
  success: [
    {:delete, {:prefix, "/tmp/session/expired/"}, %{}}
  ],
  failure: []
})
```

Note the explicit `:prefix` selector — no ambiguity about whether the key is a single key or a range.

### Idempotent task acceptance (retry-safe)

```elixir
Concord.Txn.commit(
  %{
    compare: [{:exists, "/items/#{id}", :==, false}],
    success: [{:put, "/items/#{id}", item, %{}}],
    failure: [{:get, {:key, "/items/#{id}"}, %{}}]
  },
  idempotency_key: "client-#{node()}:#{request_id}"
)
```

A retry after timeout returns the original result, not a duplicate write.

## 14. Telemetry

- `[:concord, :txn, :submitted]` — measurements: `%{compare_count, success_op_count, failure_op_count}`
- `[:concord, :txn, :committed]` — measurements: `%{duration, branch: :success | :failure, revision, mutating: bool}`
- `[:concord, :txn, :rejected]` — measurements: `%{reason: atom}`
- `[:concord, :txn, :idempotency_hit]` — measurements: `%{age_revisions: n}`
- `[:concord, :txn, :idempotency_conflict]` — measurements: `%{key: binary}`

## 15. Open questions

1. **Idempotency retention**: revision-bound or TTL-bound by default? Recommend revision-bound for the reasons in §9.
2. **Should reads inside `failure` branch also observe earlier writes in failure branch?** Probably yes for consistency with success branch; failure branches usually contain only reads, so this rarely matters.
3. **Should `:put` support multi-key form `{:put, [{k1, v1}, {k2, v2}], opts}`?** No — single-key keeps the response shape uniform. Multi-key writes are expressed as multiple ops.
4. **Range-scoped `:put`?** No. Bulk writes with computed values per key require server-side computation; that's out of scope.
