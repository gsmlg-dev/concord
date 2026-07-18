defmodule ViewstampedReplication.Transport do
  @moduledoc """
  Message delivery boundary for protocol envelopes.

  Destinations are resolved only from the explicit configuration supplied to
  the adapter. Transport reachability is never treated as VSR membership.
  """

  alias ViewstampedReplication.Protocol.Envelope

  @callback send(
              transport_state :: term(),
              destination :: term(),
              Envelope.t()
            ) :: :ok | {:error, term()}
end
