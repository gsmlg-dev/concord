defmodule ViewstampedReplication.Transport.Local do
  @moduledoc """
  Deterministic same-VM delivery through the VSR registry.

  Tests may provide a `:deliver` function to queue, drop, duplicate, or delay
  messages without changing the protocol runtime.
  """

  @behaviour ViewstampedReplication.Transport

  alias ViewstampedReplication.Protocol.Envelope

  @enforce_keys [:registry]
  defstruct [:registry, :deliver, endpoints: %{}]

  @type t :: %__MODULE__{
          registry: atom(),
          endpoints: map(),
          deliver: (pid(), term() -> :ok | {:error, term()}) | nil
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      registry: Keyword.get(opts, :registry, ViewstampedReplication.Registry),
      endpoints: Map.new(Keyword.get(opts, :endpoints, %{})),
      deliver: Keyword.get(opts, :deliver)
    }
  end

  @impl true
  def send(%__MODULE__{} = state, destination, %Envelope{} = envelope) do
    with {:ok, pid} <- resolve(state, destination, envelope.group_id) do
      deliver(state, pid, {:vsr_peer, envelope.from, envelope})
    end
  end

  defp resolve(_state, pid, _group_id) when is_pid(pid), do: {:ok, pid}

  defp resolve(state, destination, group_id) do
    key =
      case Map.fetch(state.endpoints, destination) do
        {:ok, endpoint} -> {:endpoint, group_id, endpoint}
        :error -> registry_key(destination, group_id)
      end

    case Registry.lookup(state.registry, key) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, {:destination_unavailable, destination}}
    end
  end

  defp registry_key({group_id, replica_id}, expected_group_id) when group_id == expected_group_id,
    do: {:replica, group_id, replica_id}

  defp registry_key({:replica, _destination_group_id, _replica_id} = key, _group_id), do: key
  defp registry_key(destination, group_id), do: {:endpoint, group_id, destination}

  defp deliver(%__MODULE__{deliver: nil}, pid, message) do
    Kernel.send(pid, message)
    :ok
  end

  defp deliver(%__MODULE__{deliver: deliver}, pid, message), do: deliver.(pid, message)
end
