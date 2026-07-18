defmodule ViewstampedReplication.StateMachine do
  @moduledoc """
  Contract for a deterministic service replicated by VSR.

  The runtime invokes `apply/3` only after an operation is committed and in
  operation-number order. Implementations must return the same result and state
  for the same metadata, operation, and prior state. They must not rely on
  clocks, randomness, process identity, or external side effects.

  Snapshots are state-machine-owned terms. Implementations should keep their
  encoding stable or version snapshots explicitly.
  """

  alias ViewstampedReplication.ApplyMetadata

  @type state :: term()
  @type operation :: term()
  @type result :: term()
  @type snapshot :: term()

  @callback init(keyword()) :: state()

  @callback apply(ApplyMetadata.t(), operation(), state()) ::
              {result(), state()}

  @callback snapshot(state()) :: {:ok, snapshot()}

  @callback restore(snapshot()) :: {:ok, state()} | {:error, term()}
end
