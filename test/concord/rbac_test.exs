defmodule Concord.RBACTest do
  use ExUnit.Case, async: false

  alias Concord.Auth
  alias Concord.RBAC

  setup do
    # Start the application to initialize ETS tables
    :ok = Concord.TestHelper.start_test_cluster()

    # Initialize tables if they don't exist
    if :ets.whereis(:concord_roles) == :undefined do
      RBAC.init_tables()
    end

    if :ets.whereis(:concord_tokens) == :undefined do
      :ets.new(:concord_tokens, [:set, :public, :named_table])
    end

    # Wait a bit for the application to fully start
    Process.sleep(50)

    # Clean up any existing roles, grants, and ACLs
    :ets.delete_all_objects(:concord_roles)
    :ets.delete_all_objects(:concord_role_grants)
    :ets.delete_all_objects(:concord_acls)
    :ets.delete_all_objects(:concord_tokens)

    :ok
  end

  describe "create_role/2" do
    test "creates a new role with permissions" do
      assert :ok = RBAC.create_role(:developer, [:read, :write])
      assert {:ok, [:read, :write]} = RBAC.get_role(:developer)
    end

    test "returns error if role already exists" do
      :ok = RBAC.create_role(:developer, [:read, :write])
      assert {:error, :role_exists} = RBAC.create_role(:developer, [:read])
    end

    test "validates permissions" do
      assert {:error, :invalid_permissions} = RBAC.create_role(:bad_role, [:invalid])
      assert {:error, :invalid_permissions} = RBAC.create_role(:bad_role, [:read, :fake])
    end

    test "accepts valid permissions" do
      assert :ok = RBAC.create_role(:test_role, [:read])
      assert :ok = RBAC.create_role(:test_role2, [:write])
      assert :ok = RBAC.create_role(:test_role3, [:delete])
      assert :ok = RBAC.create_role(:test_role4, [:admin])
      assert :ok = RBAC.create_role(:test_role5, [:*])
    end
  end

  describe "get_role/1" do
    test "returns predefined role permissions" do
      assert {:ok, [:*]} = RBAC.get_role(:admin)
      assert {:ok, [:read, :write, :delete]} = RBAC.get_role(:editor)
      assert {:ok, [:read]} = RBAC.get_role(:viewer)
      assert {:ok, []} = RBAC.get_role(:none)
    end

    test "returns custom role permissions" do
      :ok = RBAC.create_role(:custom, [:read, :write])
      assert {:ok, [:read, :write]} = RBAC.get_role(:custom)
    end

    test "returns error for non-existent role" do
      assert {:error, :not_found} = RBAC.get_role(:nonexistent)
    end
  end

  describe "delete_role/1" do
    test "deletes a custom role" do
      :ok = RBAC.create_role(:temp_role, [:read])
      assert {:ok, [:read]} = RBAC.get_role(:temp_role)

      assert :ok = RBAC.delete_role(:temp_role)
      assert {:error, :not_found} = RBAC.get_role(:temp_role)
    end

    test "cannot delete predefined roles" do
      assert {:error, :protected_role} = RBAC.delete_role(:admin)
      assert {:error, :protected_role} = RBAC.delete_role(:editor)
      assert {:error, :protected_role} = RBAC.delete_role(:viewer)
    end

    test "removes role grants when deleting role" do
      {:ok, token} = Auth.create_token()
      :ok = RBAC.create_role(:temp_role, [:read])
      :ok = RBAC.grant_role(token, :temp_role)

      assert :temp_role in RBAC.get_token_roles(token)

      :ok = RBAC.delete_role(:temp_role)

      assert :temp_role not in RBAC.get_token_roles(token)
    end
  end

  describe "list_roles/0" do
    test "lists all roles including predefined and custom" do
      {:ok, roles} = RBAC.list_roles()

      # Check predefined roles exist
      assert :admin in roles
      assert :editor in roles
      assert :viewer in roles
      assert :none in roles

      # Add custom role and check
      :ok = RBAC.create_role(:custom, [:read])
      {:ok, updated_roles} = RBAC.list_roles()
      assert :custom in updated_roles
    end
  end

  describe "grant_role/2 and revoke_role/2" do
    test "grants a role to a token" do
      {:ok, token} = Auth.create_token()
      assert :ok = RBAC.grant_role(token, :viewer)

      roles = RBAC.get_token_roles(token)
      assert :viewer in roles
    end

    test "allows multiple roles for a token" do
      {:ok, token} = Auth.create_token()
      :ok = RBAC.grant_role(token, :viewer)
      :ok = RBAC.grant_role(token, :editor)

      roles = RBAC.get_token_roles(token)
      assert :viewer in roles
      assert :editor in roles
    end

    test "revokes a role from a token" do
      {:ok, token} = Auth.create_token()
      :ok = RBAC.grant_role(token, :viewer)
      :ok = RBAC.grant_role(token, :editor)

      :ok = RBAC.revoke_role(token, :viewer)

      roles = RBAC.get_token_roles(token)
      refute :viewer in roles
      assert :editor in roles
    end

    test "returns error when granting non-existent role" do
      {:ok, token} = Auth.create_token()
      assert {:error, :role_not_found} = RBAC.grant_role(token, :nonexistent)
    end

    test "idempotent grant - granting same role twice is safe" do
      {:ok, token} = Auth.create_token()
      :ok = RBAC.grant_role(token, :viewer)
      :ok = RBAC.grant_role(token, :viewer)

      roles = RBAC.get_token_roles(token)
      assert length(Enum.filter(roles, &(&1 == :viewer))) == 1
    end
  end

  describe "create_acl/3 and delete_acl/2" do
    test "creates an ACL rule" do
      :ok = RBAC.create_acl("users:*", :viewer, [:read])

      {:ok, acls} = RBAC.list_acls()
      assert {"users:*", :viewer, [:read]} in acls
    end

    test "deletes an ACL rule" do
      :ok = RBAC.create_acl("users:*", :viewer, [:read])
      :ok = RBAC.delete_acl("users:*", :viewer)

      {:ok, acls} = RBAC.list_acls()
      refute {"users:*", :viewer, [:read]} in acls
    end

    test "returns error when creating ACL with non-existent role" do
      assert {:error, :role_not_found} = RBAC.create_acl("test:*", :nonexistent, [:read])
    end
  end

  describe "list_acls/0" do
    test "lists all ACL rules" do
      :ok = RBAC.create_acl("users:*", :viewer, [:read])
      :ok = RBAC.create_acl("config:*", :editor, [:read, :write])

      {:ok, acls} = RBAC.list_acls()
      assert length(acls) == 2
      assert {"users:*", :viewer, [:read]} in acls
      assert {"config:*", :editor, [:read, :write]} in acls
    end

    test "returns empty list when no ACLs exist" do
      {:ok, acls} = RBAC.list_acls()
      assert acls == []
    end
  end

  describe "check_permission/3" do
    test "allows admin role access to everything" do
      {:ok, token} = Auth.create_token()
      :ok = RBAC.grant_role(token, :admin)

      assert :ok = RBAC.check_permission(token, :read, "any:key")
      assert :ok = RBAC.check_permission(token, :write, "any:key")
      assert :ok = RBAC.check_permission(token, :delete, "any:key")
      assert :ok = RBAC.check_permission(token, :admin, "any:key")
    end

    test "allows viewer role to read" do
      {:ok, token} = Auth.create_token()
      :ok = RBAC.grant_role(token, :viewer)

      assert :ok = RBAC.check_permission(token, :read, "users:123")
      assert {:error, :forbidden} = RBAC.check_permission(token, :write, "users:123")
      assert {:error, :forbidden} = RBAC.check_permission(token, :delete, "users:123")
    end

    test "allows editor role to read, write, and delete" do
      {:ok, token} = Auth.create_token()
      :ok = RBAC.grant_role(token, :editor)

      assert :ok = RBAC.check_permission(token, :read, "users:123")
      assert :ok = RBAC.check_permission(token, :write, "users:123")
      assert :ok = RBAC.check_permission(token, :delete, "users:123")
      assert {:error, :forbidden} = RBAC.check_permission(token, :admin, "users:123")
    end

    test "denies access with none role" do
      {:ok, token} = Auth.create_token()
      :ok = RBAC.grant_role(token, :none)

      assert {:error, :forbidden} = RBAC.check_permission(token, :read, "users:123")
      assert {:error, :forbidden} = RBAC.check_permission(token, :write, "users:123")
    end

    test "combines permissions from multiple roles" do
      {:ok, token} = Auth.create_token()
      :ok = RBAC.create_role(:read_only, [:read])
      :ok = RBAC.create_role(:write_only, [:write])

      :ok = RBAC.grant_role(token, :read_only)
      :ok = RBAC.grant_role(token, :write_only)

      assert :ok = RBAC.check_permission(token, :read, "test:key")
      assert :ok = RBAC.check_permission(token, :write, "test:key")
      assert {:error, :forbidden} = RBAC.check_permission(token, :delete, "test:key")
    end

    test "ACL rules override role permissions - allows access" do
      {:ok, token} = Auth.create_token()
      :ok = RBAC.grant_role(token, :viewer)

      # ACL grants write access to users:* for viewer role
      :ok = RBAC.create_acl("users:*", :viewer, [:read, :write])

      # Viewer can now write to users:* keys
      assert :ok = RBAC.check_permission(token, :write, "users:123")

      # But not to other keys
      assert {:error, :forbidden} = RBAC.check_permission(token, :write, "config:123")
    end

    test "ACL rules restrict access by pattern" do
      {:ok, token} = Auth.create_token()
      :ok = RBAC.grant_role(token, :editor)

      # Create ACL that restricts editor to only "allowed:*" keys
      :ok = RBAC.create_acl("allowed:*", :editor, [:read, :write, :delete])

      # Editor can access allowed keys
      assert :ok = RBAC.check_permission(token, :write, "allowed:data")

      # But not other keys (ACL restrictions apply)
      assert {:error, :forbidden} = RBAC.check_permission(token, :write, "users:123")
    end

    test "backward compatibility with simple permissions" do
      # Token without roles falls back to simple permissions
      {:ok, token} = Auth.create_token([:read, :write])

      assert :ok = RBAC.check_permission(token, :read, "any:key")
      assert :ok = RBAC.check_permission(token, :write, "any:key")
      assert {:error, :forbidden} = RBAC.check_permission(token, :delete, "any:key")
    end

    test "returns unauthorized for invalid token" do
      assert {:error, :unauthorized} = RBAC.check_permission("invalid_token", :read, "key")
    end

    test "wildcard pattern matching in ACLs" do
      {:ok, token} = Auth.create_token()
      :ok = RBAC.grant_role(token, :viewer)

      # Allow read for all user keys
      :ok = RBAC.create_acl("users:*", :viewer, [:read])

      assert :ok = RBAC.check_permission(token, :read, "users:123")
      assert :ok = RBAC.check_permission(token, :read, "users:456")
      assert :ok = RBAC.check_permission(token, :read, "users:admin")

      # But not keys outside the pattern
      assert {:error, :forbidden} = RBAC.check_permission(token, :read, "config:123")
    end

    test "complex pattern matching in ACLs" do
      {:ok, token} = Auth.create_token()
      :ok = RBAC.grant_role(token, :viewer)

      # Allow read for config settings keys
      :ok = RBAC.create_acl("config:*:settings", :viewer, [:read])

      assert :ok = RBAC.check_permission(token, :read, "config:app:settings")
      assert :ok = RBAC.check_permission(token, :read, "config:db:settings")

      # But not other config keys
      assert {:error, :forbidden} = RBAC.check_permission(token, :read, "config:app:secrets")
    end
  end

  describe "integration scenarios" do
    test "typical application setup with roles and ACLs" do
      # Create application-specific roles
      :ok = RBAC.create_role(:api_user, [:read])
      :ok = RBAC.create_role(:api_admin, [:read, :write, :delete, :admin])

      # Create ACLs for different namespaces
      :ok = RBAC.create_acl("public:*", :api_user, [:read])
      :ok = RBAC.create_acl("private:*", :api_admin, [:read, :write, :delete])

      # Create tokens and grant roles
      {:ok, user_token} = Auth.create_token()
      {:ok, admin_token} = Auth.create_token()

      :ok = RBAC.grant_role(user_token, :api_user)
      :ok = RBAC.grant_role(admin_token, :api_admin)

      # User can read public data
      assert :ok = RBAC.check_permission(user_token, :read, "public:announcements")
      # But not write
      assert {:error, :forbidden} = RBAC.check_permission(user_token, :write, "public:announcements")
      # And not access private data
      assert {:error, :forbidden} = RBAC.check_permission(user_token, :read, "private:settings")

      # Admin can do everything on private data
      assert :ok = RBAC.check_permission(admin_token, :read, "private:settings")
      assert :ok = RBAC.check_permission(admin_token, :write, "private:settings")
      assert :ok = RBAC.check_permission(admin_token, :delete, "private:settings")
    end

    test "multi-tenant scenario with namespace isolation" do
      {:ok, tenant1_token} = Auth.create_token()
      {:ok, tenant2_token} = Auth.create_token()

      # Each tenant gets their own role for proper isolation
      :ok = RBAC.create_role(:tenant1, [:read, :write, :delete])
      :ok = RBAC.create_role(:tenant2, [:read, :write, :delete])
      :ok = RBAC.grant_role(tenant1_token, :tenant1)
      :ok = RBAC.grant_role(tenant2_token, :tenant2)

      # Create ACLs for tenant-specific namespaces with their unique roles
      :ok = RBAC.create_acl("tenant1:*", :tenant1, [:read, :write, :delete])
      :ok = RBAC.create_acl("tenant2:*", :tenant2, [:read, :write, :delete])

      # Tenant 1 can access their own data
      assert :ok = RBAC.check_permission(tenant1_token, :write, "tenant1:users")
      # But not tenant 2's data (no matching ACL for tenant1 role)
      assert {:error, :forbidden} = RBAC.check_permission(tenant1_token, :write, "tenant2:users")

      # Tenant 2 can access their own data
      assert :ok = RBAC.check_permission(tenant2_token, :write, "tenant2:products")
      # But not tenant 1's data
      assert {:error, :forbidden} = RBAC.check_permission(tenant2_token, :write, "tenant1:products")
    end
  end
end
