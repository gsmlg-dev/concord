defmodule ViewstampedReplication.Member do
  @moduledoc """
  A replica in an ordered VSR configuration.
  """

  @enforce_keys [:id, :endpoint]
  defstruct [:id, :endpoint]

  @type id :: term()
  @type endpoint :: term()
  @type t :: %__MODULE__{id: id(), endpoint: endpoint()}
end
