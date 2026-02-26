defmodule Concord.Auth do
  @moduledoc """
  Authentication and authorization for Concord.

  Token mutations (create, revoke) are routed through the Raft consensus layer
  to ensure tokens are replicated across all cluster nodes. Token lookups read
  directly from ETS for fast access.
  """

  alias Concord.Auth.TokenStore

  @cluster_name :concord_cluster
  @timeout 5_000

  @doc """
  Verifies an authentication token.
  Reads from the local ETS table (fast path, no Raft round-trip).
  """
  def verify_token(nil), do: {:error, :unauthorized}

  def verify_token(token) when is_binary(token) do
    case TokenStore.get(token) do
      {:ok, _permissions} -> :ok
      :error -> {:error, :unauthorized}
    end
  end

  def verify_token(_), do: {:error, :unauthorized}

  @doc """
  Creates a new authentication token.

  The token is generated pre-consensus (random bytes), then replicated via
  a Raft command so all nodes have the same token. Falls back to local ETS
  insert if the cluster is not yet ready (e.g., during test setup).
  """
  def create_token(permissions \\ [:read, :write]) do
    token = generate_token()

    case :ra.process_command(server_id(), {:auth_create_token, token, permissions}, @timeout) do
      {:ok, {:ok, ^token}, _} ->
        {:ok, token}

      {:ok, {:ok, returned_token}, _} ->
        {:ok, returned_token}

      {:error, :noproc} ->
        # Fallback: cluster not ready yet (test setup / startup)
        :ok = TokenStore.put(token, permissions)
        {:ok, token}

      {:timeout, _} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Revokes an authentication token via Raft consensus.
  """
  def revoke_token(token) do
    case :ra.process_command(server_id(), {:auth_revoke_token, token}, @timeout) do
      {:ok, :ok, _} ->
        :ok

      {:error, :noproc} ->
        # Fallback: cluster not ready
        TokenStore.delete(token)

      {:timeout, _} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp server_id, do: {@cluster_name, node()}

  # Token storage using ETS — read-only fast path
  defmodule TokenStore do
    @moduledoc """
    ETS-based token storage for authentication.
    Provides fast in-memory lookups. Writes come from the Raft state machine.
    """
    use GenServer

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    def init(_) do
      table =
        case :ets.whereis(:concord_tokens) do
          :undefined -> :ets.new(:concord_tokens, [:set, :public, :named_table])
          existing -> existing
        end

      {:ok, %{table: table}}
    end

    @doc """
    Inserts a token directly into ETS.
    Used by the state machine's apply_command and as a fallback when cluster is not ready.
    """
    def put(token, permissions) do
      :ets.insert(:concord_tokens, {token, permissions})
      :ok
    end

    @doc """
    Looks up a token from ETS (fast read path).
    """
    def get(token) do
      case :ets.lookup(:concord_tokens, token) do
        [{^token, permissions}] -> {:ok, permissions}
        [] -> :error
      end
    end

    @doc """
    Deletes a token directly from ETS.
    Used as a fallback when cluster is not ready.
    """
    def delete(token) do
      :ets.delete(:concord_tokens, token)
      :ok
    end
  end
end
