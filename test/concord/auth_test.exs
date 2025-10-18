defmodule Concord.AuthTest do
  use ExUnit.Case, async: false

  setup do
    # Enable auth for these tests
    original = Application.get_env(:concord, :auth_enabled)
    Application.put_env(:concord, :auth_enabled, true)

    on_exit(fn ->
      Application.put_env(:concord, :auth_enabled, original)
    end)

    :ok
  end

  describe "token management" do
    test "create and verify token" do
      {:ok, token} = Concord.Auth.create_token()
      assert is_binary(token)
      assert :ok = Concord.Auth.verify_token(token)
    end

    test "reject invalid token" do
      assert {:error, :unauthorized} = Concord.Auth.verify_token("invalid_token")
    end

    test "reject nil token" do
      assert {:error, :unauthorized} = Concord.Auth.verify_token(nil)
    end

    test "revoke token" do
      {:ok, token} = Concord.Auth.create_token()
      assert :ok = Concord.Auth.verify_token(token)

      :ok = Concord.Auth.revoke_token(token)
      assert {:error, :unauthorized} = Concord.Auth.verify_token(token)
    end
  end

  describe "authenticated operations" do
    setup do
      {:ok, token} = Concord.Auth.create_token()
      %{token: token}
    end

    test "put with valid token", %{token: token} do
      assert :ok = Concord.put("auth_key", "value", token: token)
    end

    test "put without token fails" do
      assert {:error, :unauthorized} = Concord.put("auth_key", "value")
    end

    test "get with valid token", %{token: token} do
      :ok = Concord.put("auth_key", "value", token: token)
      assert {:ok, "value"} = Concord.get("auth_key", token: token)
    end

    test "get without token fails" do
      assert {:error, :unauthorized} = Concord.get("auth_key")
    end

    test "delete with valid token", %{token: token} do
      :ok = Concord.put("auth_key", "value", token: token)
      assert :ok = Concord.delete("auth_key", token: token)
    end
  end
end
