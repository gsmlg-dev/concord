defmodule Concord.Web.AuthenticatedRouter do
  @moduledoc """
  Authenticated router for Concord HTTP API endpoints.

  Handles all CRUD operations, bulk operations,
  TTL management, and cluster status queries.
  """

  use Plug.Router
  require Logger

  plug Concord.Web.AuthPlug
  plug :match
  plug :dispatch

  # Core CRUD operations
  put "/kv/:key" do
    Concord.Web.APIController.put(conn, key)
  end

  get "/kv/:key" do
    Concord.Web.APIController.get(conn, key)
  end

  delete "/kv/:key" do
    Concord.Web.APIController.delete(conn, key)
  end

  # TTL operations
  post "/kv/:key/touch" do
    Concord.Web.APIController.touch(conn, key)
  end

  get "/kv/:key/ttl" do
    Concord.Web.APIController.ttl(conn, key)
  end

  # Bulk operations
  post "/kv/bulk" do
    Concord.Web.APIController.put_bulk(conn)
  end

  post "/kv/bulk/get" do
    Concord.Web.APIController.get_bulk(conn)
  end

  post "/kv/bulk/delete" do
    Concord.Web.APIController.delete_bulk(conn)
  end

  post "/kv/bulk/touch" do
    Concord.Web.APIController.touch_bulk(conn)
  end

  # Administrative operations
  get "/kv" do
    Concord.Web.APIController.get_all(conn)
  end

  get "/status" do
    Concord.Web.APIController.status(conn)
  end

  # Catch-all for unknown authenticated routes
  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{
      "status" => "error",
      "error" => %{
        "code" => "NOT_FOUND",
        "message" => "API endpoint not found"
      }
    }))
  end
end