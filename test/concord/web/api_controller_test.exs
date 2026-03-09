defmodule Concord.Web.APIControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  # Setup test environment
  setup_all do
    # Start the application to get the web server running
    Application.ensure_all_started(:concord)
    :ok
  end

  setup do
    # Start test cluster for each test
    :ok = Concord.TestHelper.start_test_cluster()

    # Clean up on test exit
    on_exit(fn ->
      # Clean up any test data
      if :ets.whereis(:concord_store) != :undefined do
        :ets.delete_all_objects(:concord_store)
      end
    end)

    :ok
  end

  describe "health endpoint" do
    test "GET /api/v1/health returns health status" do
      conn =
        conn(:get, "/api/v1/health")
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
    test "stores a key-value pair successfully" do
      params = %{"value" => "test-value"}

      conn =
        conn(:put, "/kv/test-key")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:body_params, params)
        |> Map.put(:params, params)
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      if conn.status != 200 do
        IO.puts("DEBUG: Status=#{conn.status}, Body=#{conn.resp_body}")
      end

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
    end

    test "stores a key-value pair with TTL" do
      conn =
        conn(:put, "/kv/ttl-key")
        |> Map.put(:body_params, %{"value" => "ttl-value", "ttl" => 3600})
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
    end

    test "rejects missing value" do
      conn =
        conn(:put, "/kv/test-key")
        |> Map.put(:body_params, %{})
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 400

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "INVALID_REQUEST"
    end

    test "rejects invalid TTL" do
      conn =
        conn(:put, "/kv/test-key")
        |> Map.put(:body_params, %{"value" => "test-value", "ttl" => -1})
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 400

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "INVALID_REQUEST"
    end
  end

  describe "GET /api/v1/kv/:key" do
    test "retrieves a stored value" do
      # First store a value
      :ets.insert(:concord_store, {"test-get", %{value: "test-value", expires_at: nil}})

      conn =
        conn(:get, "/kv/test-get")
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
      assert response["data"]["value"] == "test-value"
    end

    test "retrieves value with TTL information" do
      # Store a value with expiration
      expiration = System.system_time(:second) + 3600
      :ets.insert(:concord_store, {"ttl-get", %{value: "ttl-value", expires_at: expiration}})

      conn =
        conn(:get, "/kv/ttl-get?with_ttl=true")
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
      assert response["data"]["value"] == "ttl-value"
      assert is_integer(response["data"]["ttl"])
      assert response["data"]["ttl"] > 0
    end

    test "returns 404 for non-existent key" do
      conn =
        conn(:get, "/kv/non-existent")
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 404

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "NOT_FOUND"
    end
  end

  describe "DELETE /api/v1/kv/:key" do
    test "deletes a stored key" do
      # First store a value
      :ets.insert(:concord_store, {"delete-test", %{value: "delete-value", expires_at: nil}})

      conn =
        conn(:delete, "/kv/delete-test")
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"

      # Verify the key is deleted
      assert :ets.lookup(:concord_store, "delete-test") == []
    end

    test "returns 200 for non-existent key (idempotent)" do
      conn =
        conn(:delete, "/kv/non-existent")
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
    end
  end

  describe "GET /api/v1/kv/:key/ttl" do
    test "gets TTL for a key with expiration" do
      expiration = System.system_time(:second) + 3600
      :ets.insert(:concord_store, {"ttl-key", %{value: "value", expires_at: expiration}})

      conn =
        conn(:get, "/kv/ttl-key/ttl")
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
      assert is_integer(response["data"]["ttl"])
      assert response["data"]["ttl"] > 0
    end

    test "returns null for key without TTL" do
      :ets.insert(:concord_store, {"no-ttl-key", %{value: "value", expires_at: nil}})

      conn =
        conn(:get, "/kv/no-ttl-key/ttl")
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
      assert response["data"]["ttl"] == nil
    end
  end

  describe "POST /api/v1/kv/:key/touch" do
    test "extends TTL for existing key" do
      expiration = System.system_time(:second) + 100
      :ets.insert(:concord_store, {"touch-key", %{value: "value", expires_at: expiration}})

      conn =
        conn(:post, "/kv/touch-key/touch")
        |> Map.put(:body_params, %{"ttl" => 7200})
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
    end

    test "rejects invalid TTL" do
      conn =
        conn(:post, "/kv/touch-key/touch")
        |> Map.put(:body_params, %{"ttl" => -1})
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 400

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "INVALID_REQUEST"
    end
  end

  describe "POST /api/v1/kv/bulk" do
    test "stores multiple key-value pairs" do
      operations = [
        %{"key" => "bulk1", "value" => "value1"},
        %{"key" => "bulk2", "value" => "value2", "ttl" => 3600},
        %{"key" => "bulk3", "value" => 123}
      ]

      conn =
        conn(:post, "/kv/bulk")
        |> Map.put(:body_params, %{"operations" => operations})
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"

      results = response["data"]
      assert is_map(results)
      assert map_size(results) == 3

      assert results["bulk1"] == "ok"
      assert results["bulk2"] == "ok"
      assert results["bulk3"] == "ok"
    end

    test "rejects batch size too large" do
      operations = for i <- 1..501, do: %{"key" => "key#{i}", "value" => "value#{i}"}

      conn =
        conn(:post, "/kv/bulk")
        |> Map.put(:body_params, %{"operations" => operations})
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 413

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "BATCH_TOO_LARGE"
    end

    test "rejects empty operations" do
      conn =
        conn(:post, "/kv/bulk")
        |> Map.put(:body_params, %{"operations" => []})
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 400

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "INVALID_REQUEST"
    end
  end

  describe "POST /api/v1/kv/bulk/get" do
    test "retrieves multiple keys" do
      :ets.insert(:concord_store, {"get1", %{value: "value1", expires_at: nil}})
      :ets.insert(:concord_store, {"get2", %{value: "value2", expires_at: nil}})
      :ets.insert(:concord_store, {"get3", %{value: "value3", expires_at: nil}})

      keys = ["get1", "get2", "get3", "nonexistent"]

      conn =
        conn(:post, "/kv/bulk/get")
        |> Map.put(:body_params, %{"keys" => keys})
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

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

    test "retrieves multiple keys with TTL" do
      expiration = System.system_time(:second) + 3600
      :ets.insert(:concord_store, {"ttl-get1", %{value: "value1", expires_at: expiration}})

      keys = ["ttl-get1"]

      conn =
        conn(:post, "/kv/bulk/get")
        |> Map.put(:body_params, %{"keys" => keys, "with_ttl" => true})
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

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
    test "deletes multiple keys" do
      :ets.insert(:concord_store, {"del1", %{value: "value1", expires_at: nil}})
      :ets.insert(:concord_store, {"del2", %{value: "value2", expires_at: nil}})

      keys = ["del1", "del2", "nonexistent"]

      conn =
        conn(:post, "/kv/bulk/delete")
        |> Map.put(:body_params, %{"keys" => keys})
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"

      results = response["data"]
      assert length(results) == 3

      del1_result = Enum.find(results, fn r -> r["key"] == "del1" end)
      del2_result = Enum.find(results, fn r -> r["key"] == "del2" end)
      nonexistent_result = Enum.find(results, fn r -> r["key"] == "nonexistent" end)

      assert del1_result["status"] == "ok"
      assert del2_result["status"] == "ok"
      assert nonexistent_result["status"] == "ok"
    end
  end

  describe "POST /api/v1/kv/bulk/touch" do
    test "touches multiple keys" do
      expiration = System.system_time(:second) + 100
      :ets.insert(:concord_store, {"touch1", %{value: "value1", expires_at: expiration}})
      :ets.insert(:concord_store, {"touch2", %{value: "value2", expires_at: expiration}})

      operations = [
        %{"key" => "touch1", "ttl" => 7200},
        %{"key" => "touch2", "ttl" => 3600}
      ]

      conn =
        conn(:post, "/kv/bulk/touch")
        |> Map.put(:body_params, %{"operations" => operations})
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"

      results = response["data"]
      assert is_map(results)
      assert map_size(results) == 2
      assert results["touch1"] == "ok"
      assert results["touch2"] == "ok"
    end
  end

  describe "GET /api/v1/kv" do
    test "lists all keys" do
      :ets.insert(:concord_store, {"list1", %{value: "value1", expires_at: nil}})
      :ets.insert(:concord_store, {"list2", %{value: "value2", expires_at: nil}})
      :ets.insert(:concord_store, {"list3", %{value: "value3", expires_at: nil}})

      conn =
        conn(:get, "/kv")
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"

      data = response["data"]
      assert Map.has_key?(data, "list1")
      assert Map.has_key?(data, "list2")
      assert Map.has_key?(data, "list3")
      assert data["list1"] == "value1"
      assert data["list2"] == "value2"
      assert data["list3"] == "value3"
    end

    test "lists all keys with TTL" do
      expiration = System.system_time(:second) + 3600
      :ets.insert(:concord_store, {"with_ttl", %{value: "value", expires_at: expiration}})
      :ets.insert(:concord_store, {"without_ttl", %{value: "value", expires_at: nil}})

      conn =
        conn(:get, "/kv?with_ttl=true")
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"

      data = response["data"]
      assert is_map(data)
      assert map_size(data) == 2

      assert Map.has_key?(data, "with_ttl")
      assert Map.has_key?(data, "without_ttl")

      with_ttl_info = data["with_ttl"]
      assert is_integer(with_ttl_info["ttl"])
      assert with_ttl_info["ttl"] > 0
      assert with_ttl_info["value"] == "value"

      without_ttl_info = data["without_ttl"]
      assert without_ttl_info["ttl"] == nil
      assert without_ttl_info["value"] == "value"
    end

    test "respects limit parameter" do
      for i <- 1..10 do
        :ets.insert(:concord_store, {"key#{i}", %{value: "value#{i}", expires_at: nil}})
      end

      conn =
        conn(:get, "/kv?limit=5")
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"

      data = response["data"]
      assert is_map(data)
      assert map_size(data) <= 5
    end
  end

  describe "GET /api/v1/status" do
    test "returns cluster status" do
      conn =
        conn(:get, "/status")
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 200

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "ok"
      assert Map.has_key?(response, "data")
    end
  end

  describe "OpenAPI endpoints" do
    test "GET /api/v1/openapi.json returns OpenAPI spec" do
      conn =
        conn(:get, "/api/v1/openapi.json")
        |> Concord.Web.Router.call(%{})

      assert conn.state == :sent
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      response = Jason.decode!(conn.resp_body)
      assert response["openapi"] == "3.0.3"
      assert response["info"]["title"] == "Concord HTTP API"
    end

    test "GET /api/docs returns Swagger UI" do
      conn =
        conn(:get, "/api/docs")
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
    test "returns 404 for unknown endpoints" do
      conn =
        conn(:get, "/unknown")
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 404

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "NOT_FOUND"
    end

    test "handles malformed JSON gracefully" do
      conn =
        conn(:post, "/kv/bulk", "invalid json")
        |> put_req_header("content-type", "application/json")
        |> Concord.Web.AuthenticatedRouter.call(Concord.Web.AuthenticatedRouter.init([]))

      assert conn.state == :sent
      assert conn.status == 400

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "INVALID_REQUEST"
    end
  end
end
