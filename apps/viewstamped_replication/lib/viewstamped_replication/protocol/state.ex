defmodule ViewstampedReplication.Protocol.State do
  @moduledoc """
  Immutable state consumed and returned by the pure VSR protocol.
  """

  alias ViewstampedReplication.{Configuration, Log}

  @type status :: :normal | :view_change | :recovering

  @type t :: %__MODULE__{
          group_id: term(),
          configuration: Configuration.t(),
          replica_id: term(),
          status: status(),
          view_number: non_neg_integer(),
          last_normal_view: non_neg_integer(),
          op_number: non_neg_integer(),
          commit_number: non_neg_integer(),
          applied_number: non_neg_integer(),
          log: Log.t(),
          client_table: map(),
          prepare_acks: map(),
          start_view_change_votes: map(),
          do_view_change_messages: map(),
          pending_clients: map(),
          recovery_nonce: term() | nil,
          recovery_responses: map(),
          recovery_attempt: non_neg_integer(),
          applying_number: pos_integer() | nil,
          snapshot: term() | nil,
          snapshot_op_number: non_neg_integer(),
          do_view_change_sent: MapSet.t(),
          timer_tokens: map(),
          timer_sequence: non_neg_integer(),
          timeouts: %{
            primary: non_neg_integer(),
            heartbeat: non_neg_integer(),
            view_change: non_neg_integer(),
            recovery: non_neg_integer()
          }
        }

  @enforce_keys [:group_id, :configuration, :replica_id]
  defstruct [
    :group_id,
    :configuration,
    :replica_id,
    status: :recovering,
    view_number: 0,
    last_normal_view: 0,
    op_number: 0,
    commit_number: 0,
    applied_number: 0,
    log: nil,
    client_table: %{},
    prepare_acks: %{},
    start_view_change_votes: %{},
    do_view_change_messages: %{},
    pending_clients: %{},
    recovery_nonce: nil,
    recovery_responses: %{},
    recovery_attempt: 0,
    applying_number: nil,
    snapshot: nil,
    snapshot_op_number: 0,
    do_view_change_sent: MapSet.new(),
    timer_tokens: %{},
    timer_sequence: 0,
    timeouts: %{primary: 1_000, heartbeat: 500, view_change: 1_000, recovery: 1_000}
  ]

  @spec new(Configuration.t()) :: t()
  def new(%Configuration{group_id: group_id, replica_id: replica_id} = configuration) do
    %__MODULE__{
      group_id: group_id,
      configuration: configuration,
      replica_id: replica_id,
      log: Log.new()
    }
  end
end
