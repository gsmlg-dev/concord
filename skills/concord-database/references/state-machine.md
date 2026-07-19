# State Machine Internals

`Concord.StateMachine.Core` contains the deterministic service state and
command/query logic. `Concord.Engine.VSR.StateMachine` adapts it to the
standalone VSR runtime.

## State and context

Commands receive a `%Concord.StateMachine.Core.Context{}` containing the
replicated operation number and timestamp:

```elixir
%Concord.StateMachine.Core.Context{
  op_number: non_neg_integer(),
  timestamp_ms: non_neg_integer()
}
```

Never read local wall clock inside command application. Replicas must produce
the same result and next state for the same context, command, and prior state.

## Adding a command

Add a pattern-matched clause in `Concord.StateMachine.Core.apply_command/3` (or
the existing internal command dispatcher):

```elixir
defp apply_command(context, {:my_command, key, value}, state) do
  # validate deterministic data
  # derive result and immutable next state
  {result, next_state}
end
```

Public feature modules submit the command through:

```elixir
Concord.Engine.command(command, timeout: 5_000)
```

Do not address replica processes or storage adapters from feature code.

## Adding a query

Queries return a result without changing logical state:

```elixir
def query({:my_query, key}, state, context) do
  # use state and context.timestamp_ms
  {:ok, result}
end
```

Concord VSR queries are replicated barriers. They are ordered with committed
commands and currently provide linearizable semantics for every accepted
consistency option.

## Snapshots and recovery

`Concord.Engine.VSR.StateMachine.snapshot/1` delegates to
`Concord.StateMachine.Core.snapshot/1`. `restore/1` validates and restores the
versioned snapshot, then rebuilds compatibility ETS materialized views.

The VSR file adapter stores:

- hard state and current view;
- replicated log;
- commit/applied positions;
- client duplicate-suppression table;
- state-machine checkpoint.

Recovery restores the checkpoint and replays committed operations after it.

## Key invariants

1. Same input always produces the same output.
2. No PIDs, ports, references, or unsafe closures in replicated state.
3. Command timestamps come from replicated context.
4. Core state is authoritative; ETS is a materialized view.
5. Snapshots are versioned and restore through `Core.restore/1`.
