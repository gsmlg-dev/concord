defmodule Concord.Web.APIControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  # Setup test environment
  setup_all do
    # Start a minimal Concord cluster for testing
    Application.ensure_all_started(:concord)

    # Create a test token
    {:ok, token} = Concord.Auth.create_token([:read, :write])

    %{token: token}
  end

  setup %{token: token} do
    # Clean up ETS between tests - check if table exists first
    if :ets.whereis(:concord_store) != :undefined do
      :ets.delete_all_objects(:concord_store)
    end

    %{token: token}
  end

  describe "health endpoint" do
    test "GET /api/v1/health returns health status" do
      conn = conn(:get, "/api/v1/health")
      |> Concord.Web.Router.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "healthy"
      assert response["service"] == "concord-api"
      assert Map.has_key?(response, "timestamp")
    end
  end

  describe "PUT /api/v1/kv/:key" do
    test "stores a key-value pair successfully", %{token: token} do
      conn = conn(:put, "/api/v1/kv/test-key", %{"value" => "test-value"})
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
    end

    test "stores a key-value pair with TTL", %{token: token} do
      conn = conn(:put, "/api/v1/kv/ttl-key", %{"value" => "ttl-value", "ttl" => 3600})
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
    end

    test "requires authentication" do
      conn = conn(:put, "/api/v1/kv/test-key", %{"value" => "test-value"})
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 401

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "error"
      assert response["error"]["code"] == "UNAUTHORIZED"
    end

    test "rejects invalid key", %{token: token} do
      conn = conn(:put, "/api/v1/kv/", %{"value" => "test-value"})
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 400

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "INVALID_KEY"
    end

    test "rejects missing value", %{token: token} do
      conn = conn(:put, "/api/v1/kv/test-key", %{})
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 400

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "INVALID_REQUEST"
    end

    test "rejects invalid TTL", %{token: token} do
      conn = conn(:put, "/api/v1/kv/test-key", %{"value" => "test-value", "ttl" => -1})
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 400

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "INVALID_REQUEST"
    end

    test "accepts API key authentication", %{token: token} do
      # Create API key from token
      api_key = "api_" <> token

      conn = conn(:put, "/api/v1/kv/api-key-test", %{"value" => "api-value"})
      |> put_req_header("x-api-key", api_key)
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
    end
  end

  describe "GET /api/v1/kv/:key" do
    test "retrieves a stored value", %{token: token} do
      # First store a value
      :ets.insert(:concord_store, {"test-get", "test-value"})

      conn = conn(:get, "/api/v1/kv/test-get")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
      assert response["data"]["value"] == "test-value"
    end

    test "retrieves value with TTL information", %{token: token} do
      # Store a value with expiration
      expiration = System.system_time(:second) + 3600
      :ets.insert(:concord_store, {"ttl-get", {"ttl-value", expiration}})

      conn = conn(:get, "/api/v1/kv/ttl-get?with_ttl=true")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
      assert response["data"]["value"] == "ttl-value"
      assert is_integer(response["data"]["ttl"])
      assert response["data"]["ttl"] > 0
    end

    test "returns 404 for non-existent key", %{token: token} do
      conn = conn(:get, "/api/v1/kv/non-existent")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 404

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "NOT_FOUND"
    end
  end

  describe "DELETE /api/v1/kv/:key" do
    test "deletes a stored key", %{token: token} do
      # First store a value
      :ets.insert(:concord_store, {"delete-test", "delete-value"})

      conn = conn(:delete, "/api/v1/kv/delete-test")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"

      # Verify the key is deleted
      assert :ets.lookup(:concord_store, "delete-test") == []
    end

    test "returns 404 for non-existent key", %{token: token} do
      conn = conn(:delete, "/api/v1/kv/non-existent")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 404

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "NOT_FOUND"
    end
  end

  describe "GET /api/v1/kv/:key/ttl" do
    test "gets TTL for a key with expiration", %{token: token} do
      expiration = System.system_time(:second) + 3600
      :ets.insert(:concord_store, {"ttl-key", {"value", expiration}})

      conn = conn(:get, "/api/v1/kv/ttl-key/ttl")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
      assert is_integer(response["data"]["ttl"])
      assert response["data"]["ttl"] > 0
    end

    test "returns error for key without TTL", %{token: token} do
      :ets.insert(:concord_store, {"no-ttl-key", "value"})

      conn = conn(:get, "/api/v1/kv/no-ttl-key/ttl")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 400
    end
  end

  describe "POST /api/v1/kv/:key/touch" do
    test "extends TTL for existing key", %{token: token} do
      expiration = System.system_time(:second) + 100
      :ets.insert(:concord_store, {"touch-key", {"value", expiration}})

      conn = conn(:post, "/api/v1/kv/touch-key/touch", %{"ttl" => 7200})
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
    end

    test "rejects invalid TTL", %{token: token} do
      conn = conn(:post, "/api/v1/kv/touch-key/touch", %{"ttl" => -1})
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 400

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "INVALID_REQUEST"
    end
  end

  describe "POST /api/v1/kv/bulk" do
    test "stores multiple key-value pairs", %{token: token} do
      operations = [
        %{"key" => "bulk1", "value" => "value1"},
        %{"key" => "bulk2", "value" => "value2", "ttl" => 3600},
        %{"key" => "bulk3", "value" => 123}
      ]

      conn = conn(:post, "/api/v1/kv/bulk", %{"operations" => operations})
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
      assert length(response["data"]) == 3

      # Check that all operations succeeded
      for result <- response["data"] do
        assert result["status"] == "ok"
      end
    end

    test "rejects batch size too large", %{token: token} do
      # Create 501 operations (limit is 500)
      operations = for i <- 1..501, do: %{"key" => "key#{i}", "value" => "value#{i}"}

      conn = conn(:post, "/api/v1/kv/bulk", %{"operations" => operations})
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 413

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "BATCH_TOO_LARGE"
    end

    test "rejects empty operations", %{token: token} do
      conn = conn(:post, "/api/v1/kv/bulk", %{"operations" => []})
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 400

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "INVALID_REQUEST"
    end
  end

  describe "POST /api/v1/kv/bulk/get" do
    test "retrieves multiple keys", %{token: token} do
      # Pre-populate some data
      :ets.insert(:concord_store, {"get1", "value1"})
      :ets.insert(:concord_store, {"get2", "value2"})
      :ets.insert(:concord_store, {"get3", "value3"})

      keys = ["get1", "get2", "get3", "nonexistent"]

      conn = conn(:post, "/api/v1/kv/bulk/get", %{"keys" => keys})
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"

      results = response["data"]
      assert results["get1"]["status"] == "ok"
      assert results["get1"]["value"] == "value1"
      assert results["get2"]["status"] == "ok"
      assert results["get2"]["value"] == "value2"
      assert results["get3"]["status"] == "ok"
      assert results["get3"]["value"] == "value3"
      assert results["nonexistent"]["status"] == "error"
    end

    test "retrieves multiple keys with TTL", %{token: token} do
      # Pre-populate data with TTL
      expiration = System.system_time(:second) + 3600
      :ets.insert(:concord_store, {"ttl-get1", {"value1", expiration}})

      keys = ["ttl-get1"]

      conn = conn(:post, "/api/v1/kv/bulk/get", %{"keys" => keys, "with_ttl" => true})
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      results = response["data"]
      assert results["ttl-get1"]["status"] == "ok"
      assert results["ttl-get1"]["value"] == "value1"
      assert Map.has_key?(results["ttl-get1"], "ttl")
    end
  end

  describe "POST /api/v1/kv/bulk/delete" do
    test "deletes multiple keys", %{token: token} do
      # Pre-populate some data
      :ets.insert(:concord_store, {"del1", "value1"})
      :ets.insert(:concord_store, {"del2", "value2"})

      keys = ["del1", "del2", "nonexistent"]

      conn = conn(:post, "/api/v1/kv/bulk/delete", %{"keys" => keys})
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"

      results = response["data"]
      assert length(results) == 3

      # Check results
      del1_result = Enum.find(results, fn r -> r["key"] == "del1" end)
      del2_result = Enum.find(results, fn r -> r["key"] == "del2" end)
      nonexistent_result = Enum.find(results, fn r -> r["key"] == "nonexistent" end)

      assert del1_result["status"] == "ok"
      assert del2_result["status"] == "ok"
      assert nonexistent_result["status"] == "error"
    end
  end

  describe "POST /api/v1/kv/bulk/touch" do
    test "touches multiple keys", %{token: token} do
      # Pre-populate data with TTL
      expiration = System.system_time(:second) + 100
      :ets.insert(:concord_store, {"touch1", {"value1", expiration}})
      :ets.insert(:concord_store, {"touch2", {"value2", expiration}})

      operations = [
        %{"key" => "touch1", "ttl" => 7200},
        %{"key" => "touch2", "ttl" => 3600}
      ]

      conn = conn(:post, "/api/v1/kv/bulk/touch", %{"operations" => operations})
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"

      results = response["data"]
      assert length(results) == 2

      for result <- results do
        assert result["status"] == "ok"
      end
    end
  end

  describe "GET /api/v1/kv" do
    test "lists all keys", %{token: token} do
      # Pre-populate some data
      :ets.insert(:concord_store, {"list1", "value1"})
      :ets.insert(:concord_store, {"list2", "value2"})
      :ets.insert(:concord_store, {"list3", "value3"})

      conn = conn(:get, "/api/v1/kv")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"

      keys = response["data"]
      assert "list1" in keys
      assert "list2" in keys
      assert "list3" in keys
    end

    test "lists all keys with TTL", %{token: token} do
      # Pre-populate data with and without TTL
      expiration = System.system_time(:second) + 3600
      :ets.insert(:concord_store, {"with_ttl", {"value", expiration}})
      :ets.insert(:concord_store, {"without_ttl", "value"})

      conn = conn(:get, "/api/v1/kv?with_ttl=true")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"

      data = response["data"]
      # Should contain both keys, with different TTL information
      keys_with_ttl = Enum.map(data, fn item ->
        if is_map(item) do
          item.key
        else
          item
        end
      end)

      assert "with_ttl" in keys_with_ttl
      assert "without_ttl" in keys_with_ttl
    end

    test "respects limit parameter", %{token: token} do
      # Pre-populate many keys
      for i <- 1..10 do
        :ets.insert(:concord_store, {"key#{i}", "value#{i}"})
      end

      conn = conn(:get, "/api/v1/kv?limit=5")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"

      keys = response["data"]
      assert length(keys) <= 5
    end
  end

  describe "GET /api/v1/status" do
    test "returns cluster status", %{token: token} do
      conn = conn(:get, "/api/v1/status")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
      assert Map.has_key?(response, "data")
    end
  end

  describe "OpenAPI endpoints" do
    test "GET /api/v1/openapi.json returns OpenAPI spec" do
      conn = conn(:get, "/api/v1/openapi.json")
      |> Concord.Web.Router.call(%{})

      assert conn.state == :sent
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      response = Jason.decode!(conn.resp_body)
      assert response["openapi"] == "3.0.3"
      assert response["info"]["title"] == "Concord HTTP API"
    end

    test "GET /api/docs returns Swagger UI" do
      conn = conn(:get, "/api/docs")
      |> Concord.Web.Router.call(%{})

      assert conn.state == :sent
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]

      body = conn.resp_body
      assert body =~ "Concord API Documentation"
      assert body =~ "swagger-ui"
    end
  end

  describe "error handling" do
    test "returns 404 for unknown endpoints", %{token: token} do
      conn = conn(:get, "/api/v1/unknown")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 404

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "NOT_FOUND"
    end

    test "handles malformed JSON gracefully", %{token: token} do
      conn = conn(:post, "/api/v1/kv/bulk", "invalid json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 400

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "INVALID_REQUEST"
    end

    test "rejects missing authorization header" do
      conn = conn(:get, "/api/v1/kv/test")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 401

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "UNAUTHORIZED"
    end

    test "rejects invalid authorization header" do
      conn = conn(:get, "/api/v1/kv/test")
      |> put_req_header("authorization", "Invalid token")
      |> Concord.Web.AuthenticatedRouter.call(%{})

      assert conn.state == :sent
      assert conn.status == 401

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "UNAUTHORIZED"
    end
  end
end