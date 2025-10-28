defmodule Concord.MultiTenancyTest do
  use ExUnit.Case, async: false
  alias Concord.MultiTenancy
  alias Concord.RBAC
  alias Concord.Auth

  setup do
    :ok = Concord.TestHelper.start_test_cluster()

    # Initialize tables if they don't exist
    if :ets.whereis(:concord_tenants) == :undefined do
      MultiTenancy.init_tables()
    end

    if :ets.whereis(:concord_roles) == :undefined do
      RBAC.init_tables()
    end

    if :ets.whereis(:concord_tokens) == :undefined do
      :ets.new(:concord_tokens, [:set, :public, :named_table])
    end

    # Wait a bit for the application to fully start
    Process.sleep(50)

    # Clean up tables
    :ets.delete_all_objects(:concord_tenants)
    :ets.delete_all_objects(:concord_roles)
    :ets.delete_all_objects(:concord_role_grants)
    :ets.delete_all_objects(:concord_acls)
    :ets.delete_all_objects(:concord_tokens)

    :ok
  end

  describe "tenant creation" do
    test "creates tenant with default quotas" do
      assert {:ok, tenant} = MultiTenancy.create_tenant(:acme)

      assert tenant.id == :acme
      assert tenant.name == "acme"
      assert tenant.namespace == "acme:*"
      assert tenant.role == :tenant_acme
      assert tenant.quotas.max_keys == 10_000
      assert tenant.quotas.max_storage_bytes == 100_000_000
      assert tenant.quotas.max_ops_per_sec == 1_000
      assert tenant.usage.key_count == 0
      assert tenant.usage.storage_bytes == 0
      assert tenant.usage.ops_last_second == 0
    end

    test "creates tenant with custom options" do
      assert {:ok, tenant} =
               MultiTenancy.create_tenant(:widgets,
                 name: "Widgets Inc",
                 namespace: "widgets:*",
                 max_keys: 5_000,
                 max_storage_bytes: 50_000_000,
                 max_ops_per_sec: 500
               )

      assert tenant.id == :widgets
      assert tenant.name == "Widgets Inc"
      assert tenant.namespace == "widgets:*"
      assert tenant.quotas.max_keys == 5_000
      assert tenant.quotas.max_storage_bytes == 50_000_000
      assert tenant.quotas.max_ops_per_sec == 500
    end

    test "creates RBAC role and ACL automatically" do
      assert {:ok, tenant} = MultiTenancy.create_tenant(:acme)

      # Check role exists
      assert {:ok, permissions} = RBAC.get_role(:tenant_acme)
      assert permissions == [:read, :write, :delete]

      # Check ACL exists
      {:ok, acls} = RBAC.list_acls()
      assert {"acme:*", :tenant_acme, [:read, :write, :delete]} in acls
    end

    test "returns error if tenant already exists" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert {:error, :tenant_exists} = MultiTenancy.create_tenant(:acme)
    end

    test "returns error for invalid tenant ID" do
      assert {:error, :invalid_id} = MultiTenancy.create_tenant("not_an_atom")
    end
  end

  describe "tenant retrieval" do
    test "gets tenant by ID" do
      assert {:ok, created} = MultiTenancy.create_tenant(:acme, name: "ACME Corp")
      assert {:ok, retrieved} = MultiTenancy.get_tenant(:acme)

      assert retrieved.id == created.id
      assert retrieved.name == created.name
    end

    test "returns error for non-existent tenant" do
      assert {:error, :not_found} = MultiTenancy.get_tenant(:nonexistent)
    end

    test "lists all tenants" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert {:ok, _} = MultiTenancy.create_tenant(:widgets)

      assert {:ok, tenants} = MultiTenancy.list_tenants()
      assert length(tenants) == 2
      assert Enum.any?(tenants, &(&1.id == :acme))
      assert Enum.any?(tenants, &(&1.id == :widgets))
    end

    test "lists empty when no tenants exist" do
      assert {:ok, []} = MultiTenancy.list_tenants()
    end
  end

  describe "tenant deletion" do
    test "deletes tenant and associated RBAC resources" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert :ok = MultiTenancy.delete_tenant(:acme)

      # Tenant should be gone
      assert {:error, :not_found} = MultiTenancy.get_tenant(:acme)

      # RBAC role should be gone
      assert {:error, :not_found} = RBAC.get_role(:tenant_acme)

      # ACL should be gone
      {:ok, acls} = RBAC.list_acls()
      refute Enum.any?(acls, fn {pattern, _role, _perms} -> pattern == "acme:*" end)
    end

    test "returns error for non-existent tenant" do
      assert {:error, :not_found} = MultiTenancy.delete_tenant(:nonexistent)
    end

    test "revokes role from all tokens when deleting tenant" do
      {:ok, token} = Auth.create_token()
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert :ok = RBAC.grant_role(token, :tenant_acme)

      # Delete tenant
      assert :ok = MultiTenancy.delete_tenant(:acme)

      # Role should be revoked from token
      assert [] = RBAC.get_token_roles(token)
    end
  end

  describe "quota management" do
    test "updates max_keys quota" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert {:ok, tenant} = MultiTenancy.update_quota(:acme, :max_keys, 20_000)

      assert tenant.quotas.max_keys == 20_000
    end

    test "updates max_storage_bytes quota" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert {:ok, tenant} = MultiTenancy.update_quota(:acme, :max_storage_bytes, 200_000_000)

      assert tenant.quotas.max_storage_bytes == 200_000_000
    end

    test "updates max_ops_per_sec quota" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert {:ok, tenant} = MultiTenancy.update_quota(:acme, :max_ops_per_sec, 2_000)

      assert tenant.quotas.max_ops_per_sec == 2_000
    end

    test "sets quota to unlimited" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert {:ok, tenant} = MultiTenancy.update_quota(:acme, :max_keys, :unlimited)

      assert tenant.quotas.max_keys == :unlimited
    end

    test "returns error for non-existent tenant" do
      assert {:error, :not_found} = MultiTenancy.update_quota(:nonexistent, :max_keys, 5_000)
    end

    test "returns error for invalid arguments" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert {:error, :invalid_arguments} = MultiTenancy.update_quota(:acme, :invalid_quota, 100)
      assert {:error, :invalid_arguments} = MultiTenancy.update_quota(:acme, :max_keys, -100)
    end
  end

  describe "usage tracking" do
    test "gets current usage statistics" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert {:ok, usage} = MultiTenancy.get_usage(:acme)

      assert usage.key_count == 0
      assert usage.storage_bytes == 0
      assert usage.ops_last_second == 0
    end

    test "records write operation" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert :ok = MultiTenancy.record_operation(:acme, :write, key_delta: 1, storage_delta: 256)

      assert {:ok, usage} = MultiTenancy.get_usage(:acme)
      assert usage.key_count == 1
      assert usage.storage_bytes == 256
      assert usage.ops_last_second == 1
    end

    test "records delete operation" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert :ok = MultiTenancy.record_operation(:acme, :write, key_delta: 1, storage_delta: 256)
      assert :ok = MultiTenancy.record_operation(:acme, :delete, key_delta: -1, storage_delta: -256)

      assert {:ok, usage} = MultiTenancy.get_usage(:acme)
      assert usage.key_count == 0
      assert usage.storage_bytes == 0
      assert usage.ops_last_second == 2
    end

    test "accumulates multiple operations" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)

      assert :ok = MultiTenancy.record_operation(:acme, :write, key_delta: 1, storage_delta: 100)
      assert :ok = MultiTenancy.record_operation(:acme, :write, key_delta: 1, storage_delta: 200)
      assert :ok = MultiTenancy.record_operation(:acme, :write, key_delta: 1, storage_delta: 300)

      assert {:ok, usage} = MultiTenancy.get_usage(:acme)
      assert usage.key_count == 3
      assert usage.storage_bytes == 600
      assert usage.ops_last_second == 3
    end

    test "handles negative values gracefully" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert :ok = MultiTenancy.record_operation(:acme, :delete, key_delta: -10, storage_delta: -1000)

      assert {:ok, usage} = MultiTenancy.get_usage(:acme)
      assert usage.key_count == 0
      assert usage.storage_bytes == 0
    end
  end

  describe "quota checking" do
    test "allows operation within key count quota" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme, max_keys: 10)
      assert :ok = MultiTenancy.record_operation(:acme, :write, key_delta: 5)

      assert :ok = MultiTenancy.check_quota(:acme, :write)
    end

    test "blocks operation exceeding key count quota" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme, max_keys: 10)
      assert :ok = MultiTenancy.record_operation(:acme, :write, key_delta: 10)

      assert {:error, :quota_exceeded} = MultiTenancy.check_quota(:acme, :write)
    end

    test "allows operation within storage quota" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme, max_storage_bytes: 1000)
      assert :ok = MultiTenancy.record_operation(:acme, :write, storage_delta: 500)

      assert :ok = MultiTenancy.check_quota(:acme, :write, value_size: 400)
    end

    test "blocks operation exceeding storage quota" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme, max_storage_bytes: 1000)
      assert :ok = MultiTenancy.record_operation(:acme, :write, storage_delta: 500)

      assert {:error, :quota_exceeded} = MultiTenancy.check_quota(:acme, :write, value_size: 600)
    end

    test "allows operation within rate limit" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme, max_ops_per_sec: 100)
      assert :ok = MultiTenancy.record_operation(:acme, :write)
      assert :ok = MultiTenancy.record_operation(:acme, :read)

      assert :ok = MultiTenancy.check_quota(:acme, :read)
    end

    test "blocks operation exceeding rate limit" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme, max_ops_per_sec: 2)
      assert :ok = MultiTenancy.record_operation(:acme, :write)
      assert :ok = MultiTenancy.record_operation(:acme, :read)

      assert {:error, :quota_exceeded} = MultiTenancy.check_quota(:acme, :write)
    end

    test "allows unlimited quotas" do
      assert {:ok, _} =
               MultiTenancy.create_tenant(:acme,
                 max_keys: :unlimited,
                 max_storage_bytes: :unlimited,
                 max_ops_per_sec: :unlimited
               )

      assert :ok = MultiTenancy.record_operation(:acme, :write, key_delta: 1_000_000, storage_delta: 999_999_999)

      assert :ok = MultiTenancy.check_quota(:acme, :write, value_size: 999_999_999)
    end

    test "returns error for non-existent tenant" do
      assert {:error, :not_found} = MultiTenancy.check_quota(:nonexistent, :write)
    end
  end

  describe "rate limiting" do
    test "resets rate counters" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert :ok = MultiTenancy.record_operation(:acme, :write)
      assert :ok = MultiTenancy.record_operation(:acme, :read)

      assert {:ok, usage_before} = MultiTenancy.get_usage(:acme)
      assert usage_before.ops_last_second == 2

      # Reset counters
      assert :ok = MultiTenancy.reset_rate_counters()

      assert {:ok, usage_after} = MultiTenancy.get_usage(:acme)
      assert usage_after.ops_last_second == 0
      assert usage_after.key_count == usage_before.key_count
      assert usage_after.storage_bytes == usage_before.storage_bytes
    end

    test "resets counters for all tenants" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert {:ok, _} = MultiTenancy.create_tenant(:widgets)

      assert :ok = MultiTenancy.record_operation(:acme, :write)
      assert :ok = MultiTenancy.record_operation(:widgets, :read)

      assert :ok = MultiTenancy.reset_rate_counters()

      assert {:ok, acme_usage} = MultiTenancy.get_usage(:acme)
      assert {:ok, widgets_usage} = MultiTenancy.get_usage(:widgets)

      assert acme_usage.ops_last_second == 0
      assert widgets_usage.ops_last_second == 0
    end
  end

  describe "tenant extraction from key" do
    test "extracts tenant ID from key with matching pattern" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert {:ok, :acme} = MultiTenancy.tenant_from_key("acme:users:123")
    end

    test "returns error for key without tenant prefix" do
      assert {:error, :no_tenant} = MultiTenancy.tenant_from_key("users:123")
    end

    test "returns error for non-existent tenant" do
      assert {:error, :no_tenant} = MultiTenancy.tenant_from_key("nonexistent:users:123")
    end

    test "handles keys with colons in value" do
      assert {:ok, _} = MultiTenancy.create_tenant(:acme)
      assert {:ok, :acme} = MultiTenancy.tenant_from_key("acme:config:db:connection:string")
    end
  end

  describe "integration with RBAC" do
    test "tenant role grants access to tenant namespace via ACL" do
      {:ok, token} = Auth.create_token()
      assert {:ok, tenant} = MultiTenancy.create_tenant(:acme)

      # Grant tenant role to token
      assert :ok = RBAC.grant_role(token, tenant.role)

      # Token should have access to tenant namespace
      assert :ok = RBAC.check_permission(token, :read, "acme:users:123")
      assert :ok = RBAC.check_permission(token, :write, "acme:products:456")
      assert :ok = RBAC.check_permission(token, :delete, "acme:orders:789")
    end

    test "tenant role denies access to other tenant namespaces" do
      {:ok, token} = Auth.create_token()
      assert {:ok, acme_tenant} = MultiTenancy.create_tenant(:acme)
      assert {:ok, _} = MultiTenancy.create_tenant(:widgets)

      # Grant only ACME tenant role
      assert :ok = RBAC.grant_role(token, acme_tenant.role)

      # Token should NOT have access to widgets namespace
      assert {:error, :forbidden} = RBAC.check_permission(token, :read, "widgets:users:123")
    end

    test "multiple tenant roles grant access to multiple namespaces" do
      {:ok, token} = Auth.create_token()
      assert {:ok, acme_tenant} = MultiTenancy.create_tenant(:acme)
      assert {:ok, widgets_tenant} = MultiTenancy.create_tenant(:widgets)

      # Grant both tenant roles
      assert :ok = RBAC.grant_role(token, acme_tenant.role)
      assert :ok = RBAC.grant_role(token, widgets_tenant.role)

      # Token should have access to both namespaces
      assert :ok = RBAC.check_permission(token, :read, "acme:users:123")
      assert :ok = RBAC.check_permission(token, :read, "widgets:products:456")
    end
  end

  describe "complete workflow" do
    test "tenant lifecycle with quotas and usage" do
      # Create tenant
      {:ok, tenant} =
        MultiTenancy.create_tenant(:acme,
          name: "ACME Corporation",
          max_keys: 100,
          max_storage_bytes: 10_000,
          max_ops_per_sec: 50
        )

      # Create token and grant access
      {:ok, token} = Auth.create_token()
      :ok = RBAC.grant_role(token, tenant.role)

      # Verify access
      assert :ok = RBAC.check_permission(token, :write, "acme:data")

      # Simulate operations
      :ok = MultiTenancy.record_operation(:acme, :write, key_delta: 10, storage_delta: 1000)

      # Check usage
      {:ok, usage} = MultiTenancy.get_usage(:acme)
      assert usage.key_count == 10
      assert usage.storage_bytes == 1000

      # Quota should allow more writes
      assert :ok = MultiTenancy.check_quota(:acme, :write, value_size: 500)

      # Update quota
      {:ok, _} = MultiTenancy.update_quota(:acme, :max_keys, 200)

      # Delete tenant
      :ok = MultiTenancy.delete_tenant(:acme)

      # Verify cleanup
      assert {:error, :not_found} = MultiTenancy.get_tenant(:acme)
      assert {:error, :not_found} = RBAC.get_role(:tenant_acme)
    end
  end
end
