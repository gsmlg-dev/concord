defmodule ViewstampedReplication.LogEntry do
  @moduledoc """
  A client operation at a stable position in the replicated log.
  """

  @enforce_keys [:view_number, :op_number, :client_id, :request_number, :operation]
  defstruct [
    :view_number,
    :op_number,
    :client_id,
    :request_number,
    :operation,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          view_number: non_neg_integer(),
          op_number: pos_integer(),
          client_id: term(),
          request_number: non_neg_integer(),
          operation: term(),
          metadata: map()
        }
end
