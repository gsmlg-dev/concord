defmodule ViewstampedReplication.Protocol.Envelope do
  @moduledoc "Versioned, group-scoped protocol message envelope."

  @enforce_keys [:group_id, :from, :payload]
  defstruct protocol_version: 1,
            group_id: nil,
            configuration_hash: nil,
            from: nil,
            payload: nil

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          group_id: term(),
          configuration_hash: binary() | nil,
          from: term(),
          payload: term()
        }
end

defmodule ViewstampedReplication.Protocol.Prepare do
  @moduledoc false
  @enforce_keys [:view_number, :op_number, :commit_number, :entry]
  defstruct [:view_number, :op_number, :commit_number, :entry]
end

defmodule ViewstampedReplication.Protocol.PrepareOk do
  @moduledoc false
  @enforce_keys [:view_number, :op_number]
  defstruct [:view_number, :op_number]
end

defmodule ViewstampedReplication.Protocol.Commit do
  @moduledoc false
  @enforce_keys [:view_number, :commit_number]
  defstruct [:view_number, :commit_number]
end

defmodule ViewstampedReplication.Protocol.StartViewChange do
  @moduledoc false
  @enforce_keys [:view_number]
  defstruct [:view_number]
end

defmodule ViewstampedReplication.Protocol.DoViewChange do
  @moduledoc false
  @enforce_keys [:view_number, :last_normal_view, :op_number, :commit_number, :log]
  defstruct [
    :view_number,
    :last_normal_view,
    :op_number,
    :commit_number,
    :log,
    :snapshot,
    client_table: %{},
    snapshot_op_number: 0,
    log_suffix: []
  ]
end

defmodule ViewstampedReplication.Protocol.StartView do
  @moduledoc false
  @enforce_keys [:view_number, :op_number, :commit_number, :log]
  defstruct [
    :view_number,
    :op_number,
    :commit_number,
    :log,
    :snapshot,
    client_table: %{},
    snapshot_op_number: 0,
    log_suffix: []
  ]
end

defmodule ViewstampedReplication.Protocol.Recovery do
  @moduledoc false
  @enforce_keys [:nonce]
  defstruct [:nonce]
end

defmodule ViewstampedReplication.Protocol.RecoveryResponse do
  @moduledoc false
  @enforce_keys [:nonce, :view_number]
  defstruct [
    :nonce,
    :view_number,
    :op_number,
    :commit_number,
    :log,
    :client_table,
    :snapshot,
    snapshot_op_number: 0,
    log_suffix: [],
    status: :normal
  ]
end

defmodule ViewstampedReplication.Protocol.GetState do
  @moduledoc false
  @enforce_keys [:view_number, :from_op_number]
  defstruct [:view_number, :from_op_number]
end

defmodule ViewstampedReplication.Protocol.NewState do
  @moduledoc false
  @enforce_keys [:view_number, :op_number, :commit_number, :log]
  defstruct [
    :view_number,
    :op_number,
    :commit_number,
    :log,
    :client_table,
    :last_normal_view,
    :snapshot,
    snapshot_op_number: 0,
    log_suffix: []
  ]
end
