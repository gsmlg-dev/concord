defmodule ViewstampedReplication.Transport.Distribution do
  @moduledoc """
  Explicit distributed-Erlang endpoint delivery.

  Endpoint maps are configuration, not discovery. This adapter never calls
  `Node.list/0` and does not infer membership from node connectivity.
  """

  @behaviour ViewstampedReplication.Transport

  alias ViewstampedReplication.Protocol.Envelope

  @enforce_keys [:endpoints]
  defstruct [:endpoints]

  @type endpoint ::
          pid()
          | {atom(), node()}
          | node()
          | %{required(:node) => node(), optional(:replica_id) => term()}
  @type t :: %__MODULE__{endpoints: map()}

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{endpoints: Map.new(Keyword.fetch!(opts, :endpoints))}
  end

  @impl true
  def send(%__MODULE__{} = state, destination, %Envelope{} = envelope) do
    case Map.fetch(state.endpoints, destination) do
      {:ok, pid} when is_pid(pid) ->
        deliver(pid, envelope)

      {:ok, {name, node}} when is_atom(name) and is_atom(node) ->
        deliver({name, node}, envelope)

      {:ok, node} when is_atom(node) ->
        remote_deliver(node, envelope.group_id, destination, envelope)

      {:ok, %{node: node} = endpoint} when is_atom(node) ->
        remote_deliver(
          node,
          envelope.group_id,
          Map.get(endpoint, :replica_id, destination),
          envelope
        )

      :error ->
        {:error, {:unknown_destination, destination}}

      {:ok, endpoint} ->
        {:error, {:invalid_endpoint, endpoint}}
    end
  end

  defp deliver(target, envelope) do
    Kernel.send(target, {:vsr_peer, envelope.from, envelope})
    :ok
  end

  defp remote_deliver(node, group_id, replica_id, envelope) do
    :erpc.cast(
      node,
      ViewstampedReplication.Replica,
      :deliver,
      [group_id, replica_id, envelope]
    )
  end
end
