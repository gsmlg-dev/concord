defmodule Concord.Txn.Result do
  @moduledoc """
  Result of a committed transaction.

  - `succeeded` — `true` if the success branch ran, `false` if the failure branch ran.
    A `succeeded: false` result is **not an error** — it means the compares didn't hold.
  - `revision` — cluster revision after the transaction (unchanged if no mutation occurred).
  - `responses` — ordered list of operation responses from the executed branch.
  """

  @type response ::
          {:get, term(), %{kvs: [Concord.KV.Record.t()], count: non_neg_integer()}}
          | {:put, binary(), %{prev_kv: Concord.KV.Record.t() | nil}}
          | {:delete, term(), %{deleted: non_neg_integer(), prev_kvs: [Concord.KV.Record.t()]}}
          | {:touch, binary(), %{ttl: integer() | :not_found}}

  @type t :: %__MODULE__{
          succeeded: boolean(),
          revision: non_neg_integer(),
          responses: [response()]
        }

  defstruct [
    :succeeded,
    :revision,
    responses: []
  ]
end
