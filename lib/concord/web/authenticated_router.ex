defmodule Concord.Web.AuthenticatedRouter do
  @moduledoc """
  Authenticated router for Concord HTTP API endpoints.

  Handles all CRUD operations, bulk operations,
  TTL management, and cluster status queries.
  """

  use Plug.Router
  require Logger

  alias Concord.Web.APIController
  alias Concord.Web.AuthPlug

  plug(AuthPlug)
  plug(:match)
  plug(:dispatch)

  # Core CRUD operations
  put "/kv/:key" do
    APIController.put(conn, key)
  end

  get "/kv/:key" do
    APIController.get(conn, key)
  end

  delete "/kv/:key" do
    APIController.delete(conn, key)
  end

  # Bulk operations (must come before parameterized routes to match correctly)
  post "/kv/bulk" do
    APIController.put_bulk(conn)
  end

  post "/kv/bulk/get" do
    APIController.get_bulk(conn)
  end

  post "/kv/bulk/delete" do
    APIController.delete_bulk(conn)
  end

  post "/kv/bulk/touch" do
    APIController.touch_bulk(conn)
  end

  # Administrative operations
  get "/kv" do
    APIController.get_all(conn)
  end

  # TTL operations (parameterized routes come after specific routes)
  post "/kv/:key/touch" do
    APIController.touch(conn, key)
  end

  get "/kv/:key/ttl" do
    APIController.ttl(conn, key)
  end

  get "/status" do
    APIController.status(conn)
  end

  # Catch-all for unknown authenticated routes
  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      404,
      Jason.encode!(%{
        "status" => "error",
        "error" => %{
          "code" => "NOT_FOUND",
          "message" => "API endpoint not found"
        }
      })
    )
  end
end
