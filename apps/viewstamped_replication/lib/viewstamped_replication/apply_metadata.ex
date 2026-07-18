defmodule ViewstampedReplication.ApplyMetadata do
  @moduledoc """
  Protocol metadata supplied to the deterministic state machine.
  """

  @enforce_keys [:group_id, :view_number, :op_number, :client_id, :request_number]
  defstruct [
    :group_id,
    :view_number,
    :op_number,
    :client_id,
    :request_number,
    entry_metadata: %{}
  ]

  @type t :: %__MODULE__{
          group_id: term(),
          view_number: non_neg_integer(),
          op_number: pos_integer(),
          client_id: term(),
          request_number: non_neg_integer(),
          entry_metadata: map()
        }
end
