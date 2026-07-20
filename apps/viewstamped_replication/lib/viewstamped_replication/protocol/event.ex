defmodule ViewstampedReplication.Protocol.Event do
  @moduledoc "Events accepted by the pure protocol transition function."

  alias ViewstampedReplication.Request
  alias ViewstampedReplication.Protocol.Envelope

  @type client_route :: term()
  @type replica_id :: term()
  @type timer_kind :: atom()
  @type timer_token :: term()
  @type op_number :: non_neg_integer()
  @type result :: term()
  @type recovered_state :: term()

  @type t ::
          {:client_request, client_route(), Request.t()}
          | {:read_request, client_route(), operation :: term()}
          | {:peer_message, replica_id(), Envelope.t()}
          | {:timeout, timer_kind(), timer_token()}
          | {:state_machine_applied, op_number(), result()}
          | {:snapshot_completed, op_number(), snapshot :: term()}
          | {:storage_recovered, recovered_state()}
          | {:storage_failed, term()}
end
