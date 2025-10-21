defmodule Concord.Web.AuthPlug do
  @moduledoc """
  Authentication plug for Concord HTTP API.

  Supports two authentication methods:
  1. Bearer Token: Authorization: Bearer <token>
  2. API Key: X-API-Key: <token>

  Uses the existing Concord.Auth system for token validation.
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    case extract_token(conn) do
      {:ok, token} ->
        case verify_token(token) do
          :ok ->
            conn
            |> assign(:authenticated, true)
            |> assign(:auth_token, token)

          {:error, reason} ->
            handle_auth_error(conn, reason)
        end

      {:error, reason} ->
        handle_auth_error(conn, reason)
    end
  end

  # Extract token from Authorization header or X-API-Key header
  defp extract_token(conn) do
    # Try Authorization: Bearer <token> first
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        {:ok, String.trim(token)}

      ["bearer " <> token] ->
        {:ok, String.trim(token)}

      _ ->
        # Try X-API-Key header
        case get_req_header(conn, "x-api-key") do
          [token] when token != "" ->
            {:ok, String.trim(token)}

          _ ->
            {:error, :no_token}
        end
    end
  end

  # Verify token using Concord.Auth
  defp verify_token(token) do
    # Check if auth is enabled globally
    if Application.get_env(:concord, :auth_enabled, false) do
      case Concord.Auth.verify_token(token) do
        :ok -> :ok
        {:error, _reason} = error -> error
      end
    else
      # Auth disabled, allow all requests
      :ok
    end
  end

  # Handle authentication errors
  defp handle_auth_error(conn, :no_token) do
    Logger.debug("API request missing authentication token")

    conn
    |> put_status(:unauthorized)
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{
      "status" => "error",
      "error" => %{
        "code" => "UNAUTHORIZED",
        "message" => "Authentication token required"
      }
    }))
    |> halt()
  end

  
  defp handle_auth_error(conn, reason) do
    Logger.debug("API authentication failed: #{inspect(reason)}")

    conn
    |> put_status(:unauthorized)
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{
      "status" => "error",
      "error" => %{
        "code" => "UNAUTHORIZED",
        "message" => "Authentication failed"
      }
    }))
    |> halt()
  end
end