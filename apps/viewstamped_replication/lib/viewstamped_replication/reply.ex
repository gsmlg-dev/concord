defmodule ViewstampedReplication.Reply do
  @moduledoc """
  The cached result of an applied client request.
  """

  @enforce_keys [:view_number, :client_id, :request_number, :result]
  defstruct [:view_number, :client_id, :request_number, :result, status: :ok]

  @type t :: %__MODULE__{
          view_number: non_neg_integer(),
          client_id: term(),
          request_number: non_neg_integer(),
          result: term(),
          status: :ok | :error
        }
end
