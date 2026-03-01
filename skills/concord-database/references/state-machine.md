# State Machine Internals

`Concord.StateMachine` implements `:ra_machine`. Most critical file in the project.

## State Shape

```elixir
{:concord_kv, %{
  indexes: %{name => extractor_spec},
  tokens: %{token => permissions},
  roles: %{role => permissions},
  role_grants: %{token => [roles]},
  acls: [{pattern, role, permissions}],
  tenants: %{tenant_id => definition},
  command_count: non_neg_integer()
}}
```

## Command Pattern

Every command is processed through `apply/3` which delegates to `apply_command/3`:

```elixir
def apply(meta, command, {:concord_kv, state}) do
  {new_state, result, effects} = apply_command(meta, command, state)
  new_state_with_count = %{new_state | command_count: state.command_count + 1}

  # Emit snapshot every 1000 commands
  effects = maybe_release_cursor(meta, new_state_with_count, effects)

  {{:concord_kv, new_state_with_count}, result, effects}
end
```

### Adding a New Command

```elixir
# In apply_command/3:
defp apply_command(_meta, {:my_command, arg1, arg2}, state) do
  # 1. Validate and compute new state
  new_state = %{state | my_field: compute(arg1, arg2)}

  # 2. Update ETS (materialized view)
  :ets.insert(:concord_data, {arg1, arg2})

  # 3. Emit telemetry
  effects = [{:mod_call, :telemetry, :execute,
    [[:concord, :operation, :apply],
     %{duration: 0},
     %{operation: :my_command}]}]

  {new_state, :ok, effects}
end
```

### Time in Commands

NEVER use `System.system_time()` — breaks deterministic replay.

```elixir
# CORRECT — use meta.system_time (leader-assigned, in milliseconds)
defp apply_command(meta, {:put, key, value, expires_at}, state) do
  now = meta_time(meta)  # converts ms -> seconds
  # ...
end

defp meta_time(%{system_time: ms}), do: div(ms, 1000)
```

## Query Pattern

Queries are read-only, bypass Raft log:

```elixir
def query({:concord_kv, _state}, {:get, key}) do
  case :ets.lookup(:concord_data, key) do
    [{^key, value, expires_at}] ->
      now = System.system_time(:second)  # OK in queries (not replayed)
      if expires_at && expires_at < now, do: {:ok, nil}, else: {:ok, decompress(value)}
    [] ->
      {:ok, nil}
  end
end
```

### Adding a New Query

```elixir
def query({:concord_kv, state}, {:my_query, arg}) do
  result = Map.get(state.my_field, arg)
  {:ok, result}
end
```

## Snapshot Mechanics

Ra snapshots via `release_cursor` effect (no `snapshot/1` callback):

```elixir
defp maybe_release_cursor(meta, state, effects) do
  if rem(state.command_count, 1000) == 0 do
    cursor_state = build_release_cursor_state(state)
    [{:release_cursor, meta.index, {:concord_kv, cursor_state}} | effects]
  else
    effects
  end
end
```

`build_release_cursor_state/1` captures ETS data into the state for snapshot serialization.

On `snapshot_installed/4`, ETS tables are rebuilt from the snapshot state.

## ETS Tables

- `:concord_data` — Main KV storage `{key, value, expires_at}`
- `:concord_index_*` — Per-index lookup tables
- `:concord_auth_tokens` — Token verification cache
- All tables are materialized views of Raft state

## Telemetry in Commands

Emit via `effects` (not direct calls — would break determinism):

```elixir
effects = [{:mod_call, :telemetry, :execute,
  [[:concord, :operation, :apply],
   %{duration: 0},
   %{operation: :put, key: key, index: meta.index}]}]
```

## Key Invariants Recap

1. `apply_command/3` is pure — same input always produces same output
2. No closures in state or log — use declarative tuple specs
3. Time from `meta.system_time` only (in apply), `System.system_time` OK in queries
4. ETS writes in apply are materialized views — rebuilt on snapshot install
5. Snapshots via `{:release_cursor, index, state}` effects every 1000 commands
