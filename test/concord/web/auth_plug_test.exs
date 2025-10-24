defmodule Concord.Web.AuthPlugTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  setup_all do
    Application.ensure_all_started(:concord)

    # Enable auth for these tests
    original_auth = Application.get_env(:concord, :auth_enabled)
    Application.put_env(:concord, :auth_enabled, true)

    {:ok, token} = Concord.Auth.create_token([:read, :write])

    on_exit(fn ->
      # Restore original auth setting
      Application.put_env(:concord, :auth_enabled, original_auth)
    end)

    %{token: token}
  end

  describe "authentication" do
    test "accepts valid Bearer token", %{token: token} do
      conn = conn(:get, "/test")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Concord.Web.AuthPlug.call(%{})

      assert conn.assigns[:auth_token] == token
      refute conn.halted
    end

    test "accepts valid API key", %{token: token} do
      conn = conn(:get, "/test")
      |> put_req_header("x-api-key", token)
      |> Concord.Web.AuthPlug.call(%{})

      assert conn.assigns[:auth_token] == token
      refute conn.halted
    end

    test "rejects missing authentication" do
      conn = conn(:get, "/test")
      |> Concord.Web.AuthPlug.call(%{})

      assert conn.halted
      assert conn.status == 401

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "UNAUTHORIZED"
    end

    test "rejects invalid Bearer token" do
      conn = conn(:get, "/test")
      |> put_req_header("authorization", "Bearer invalid-token")
      |> Concord.Web.AuthPlug.call(%{})

      assert conn.halted
      assert conn.status == 401

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "UNAUTHORIZED"
    end

    test "rejects invalid API key" do
      conn = conn(:get, "/test")
      |> put_req_header("x-api-key", "invalid-api-key")
      |> Concord.Web.AuthPlug.call(%{})

      assert conn.halted
      assert conn.status == 401

      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == "UNAUTHORIZED"
    end

    test "rejects malformed authorization header" do
      conn = conn(:get, "/test")
      |> put_req_header("authorization", "InvalidFormat token")
      |> Concord.Web.AuthPlug.call(%{})

      assert conn.halted
      assert conn.status == 401
    end

    test "rejects empty authorization header" do
      conn = conn(:get, "/test")
      |> put_req_header("authorization", "")
      |> Concord.Web.AuthPlug.call(%{})

      assert conn.halted
      assert conn.status == 401
    end

    test "rejects empty API key" do
      conn = conn(:get, "/test")
      |> put_req_header("x-api-key", "")
      |> Concord.Web.AuthPlug.call(%{})

      assert conn.halted
      assert conn.status == 401
    end
  end
end