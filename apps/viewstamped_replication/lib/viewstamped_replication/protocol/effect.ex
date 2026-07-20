defmodule ViewstampedReplication.Protocol.Effect do
  @moduledoc "Ordered effects emitted by the pure protocol core."

  alias ViewstampedReplication.{LogEntry, Reply}
  alias ViewstampedReplication.Protocol.Envelope

  @type t ::
          {:send, replica_id :: term(), Envelope.t()}
          | {:broadcast, Envelope.t()}
          | {:reply, client_route :: term(), Reply.t()}
          | {:read, client_route :: term(), operation :: term()}
          | {:read_reply, client_route :: term(), result :: term()}
          | {:persist, storage_operation :: term()}
          | {:apply, LogEntry.t()}
          | {:schedule_timer, timer_kind :: atom(), timeout(), timer_token :: term()}
          | {:cancel_timer, timer_kind :: atom()}
          | {:request_state_transfer, replica_id :: term(), Range.t()}
          | {:emit_telemetry, event_name :: [atom()], measurements :: map(), metadata :: map()}
end
