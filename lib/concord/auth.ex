defmodule Concord.Auth do
  @moduledoc """
  Authentication and authorization for Concord.
  Implements token-based authentication.
  """

  alias Concord.Auth.TokenStore

  @doc """
  Verifies an authentication token.
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
  """
  def create_token(permissions \\ [:read, :write]) do
    token = generate_token()
    :ok = TokenStore.put(token, permissions)
    {:ok, token}
  end

  @doc """
  Revokes an authentication token.
  """
  def revoke_token(token) do
    TokenStore.delete(token)
  end

  defp generate_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  # Token storage using ETS
  defmodule TokenStore do
    @moduledoc """
    ETS-based token storage for authentication.
    Provides fast in-memory storage and retrieval of authentication tokens.
    """
    use GenServer

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    def init(_) do
      table = :ets.new(:concord_tokens, [:set, :public, :named_table])
      {:ok, %{table: table}}
    end

    def put(token, permissions) do
      :ets.insert(:concord_tokens, {token, permissions})
      :ok
    end

    def get(token) do
      case :ets.lookup(:concord_tokens, token) do
        [{^token, permissions}] -> {:ok, permissions}
        [] -> :error
      end
    end

    def delete(token) do
      :ets.delete(:concord_tokens, token)
      :ok
    end
  end
end
