defmodule ViewstampedReplication.Request do
  @moduledoc """
  A client operation with a stable client identity and monotonic request number.
  """

  @enforce_keys [:client_id, :request_number, :operation]
  defstruct [:client_id, :request_number, :operation, metadata: %{}]

  @type t :: %__MODULE__{
          client_id: term(),
          request_number: non_neg_integer(),
          operation: term(),
          metadata: map()
        }
end
