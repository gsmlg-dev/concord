defmodule Concord.KV.Record do
  @moduledoc """
  Per-key revisioned record in Concord's MVCC store.

  Every key in Concord is backed by a `Record` that tracks its full revision
  history metadata. Records are the internal representation stored in ETS;
  the public API can return either bare values (for backward compatibility)
  or full records (with `metadata: true`).

  ## Fields

  - `value` — The stored value (any Erlang term)
  - `create_revision` — Cluster revision when the key was first created
    (resets on delete-and-recreate)
  - `mod_revision` — Cluster revision of the latest mutation
  - `version` — Count of writes since creation; `0` means tombstone (deleted)
  - `expires_at` — Absolute timestamp (seconds) of TTL expiry, or `nil`
  - `lease_id` — Lease this key is attached to, or `nil`
  - `content_type` — Optional MIME-ish hint (e.g., `"text/markdown"`)
  - `metadata` — Optional application-level metadata map
  """

  @type t :: %__MODULE__{
          value: term(),
          create_revision: non_neg_integer(),
          mod_revision: non_neg_integer(),
          version: non_neg_integer(),
          expires_at: non_neg_integer() | nil,
          lease_id: non_neg_integer() | nil,
          content_type: binary() | nil,
          metadata: map()
        }

  defstruct [
    :value,
    :create_revision,
    :mod_revision,
    :expires_at,
    :lease_id,
    :content_type,
    version: 0,
    metadata: %{}
  ]

  @doc """
  Returns `true` if this record is a tombstone (deleted key).
  """
  @spec tombstone?(t()) :: boolean()
  def tombstone?(%__MODULE__{version: 0}), do: true
  def tombstone?(%__MODULE__{}), do: false

  @doc """
  Returns `true` if this record has expired based on the given current time.
  """
  @spec expired?(t(), non_neg_integer()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false
  def expired?(%__MODULE__{expires_at: expires_at}, now), do: now > expires_at

  @doc """
  Creates a tombstone record for a deleted key.
  """
  @spec tombstone(binary(), non_neg_integer(), t() | nil) :: t()
  def tombstone(_key, revision, prev_record) do
    %__MODULE__{
      value: nil,
      create_revision: if(prev_record, do: prev_record.create_revision, else: revision),
      mod_revision: revision,
      version: 0,
      expires_at: nil,
      lease_id: nil,
      content_type: nil,
      metadata: %{}
    }
  end
end
