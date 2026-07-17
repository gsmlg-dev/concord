defmodule Concord.Sync.Event do
  @moduledoc """
  A single mutation event in the Concord change stream.

  Events are produced by the state machine on every mutating command
  and dispatched to watchers via the Sync Dispatcher.

  ## Fields

  - `type` — `:put` or `:delete`
  - `key` — the affected key
  - `revision` — cluster revision of this event
  - `record` — the new `%Record{}` for `:put`, or tombstone for `:delete`
  - `prev_record` — the previous `%Record{}` (if available), or `nil`
  """

  alias Concord.KV.Record

  @type event_type :: :put | :delete

  @type t :: %__MODULE__{
          type: event_type(),
          key: binary(),
          revision: non_neg_integer(),
          record: Record.t() | nil,
          prev_record: Record.t() | nil
        }

  defstruct [
    :type,
    :key,
    :revision,
    :record,
    :prev_record
  ]
end
