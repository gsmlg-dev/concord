defmodule Mix.Tasks.Concord.Cluster do
  @moduledoc """
  Mix tasks for managing Concord clusters.
  """

  use Mix.Task
  alias Concord.Auth
  alias Concord.RBAC
  alias Concord.MultiTenancy

  @shortdoc "Manages Concord cluster operations"

  def run(["status" | _]) do
    Mix.Task.run("app.start")

    case Concord.status() do
      {:ok, status} ->
        Mix.shell().info("Cluster Status:")
        Mix.shell().info("Node: #{status.node}")
        Mix.shell().info("\nCluster Overview:")
        Mix.shell().info(inspect(status.cluster, pretty: true))
        Mix.shell().info("\nStorage Stats:")
        Mix.shell().info("  Size: #{status.storage.size} entries")
        Mix.shell().info("  Memory: #{status.storage.memory} words")

      {:error, reason} ->
        Mix.shell().error("Failed to get cluster status: #{inspect(reason)}")
    end
  end

  def run(["members" | _]) do
    Mix.Task.run("app.start")

    case Concord.members() do
      {:ok, members} ->
        Mix.shell().info("Cluster Members:")

        Enum.each(members, fn member ->
          Mix.shell().info("  - #{inspect(member)}")
        end)

      {:error, reason} ->
        Mix.shell().error("Failed to get members: #{inspect(reason)}")
    end
  end

  def run(["token", "create" | _]) do
    Mix.Task.run("app.start")

    {:ok, token} = Auth.create_token([:read, :write])
    Mix.shell().info("Created token: #{token}")
    Mix.shell().info("Save this token securely!")
  end

  def run(["token", "revoke", token | _]) do
    Mix.Task.run("app.start")

    :ok = Auth.revoke_token(token)
    Mix.shell().info("Token revoked successfully")
  end

  # RBAC commands
  def run(["role", "create", role_name, permissions_str | _]) do
    Mix.Task.run("app.start")

    role = String.to_atom(role_name)
    permissions = permissions_str |> String.split(",") |> Enum.map(&String.to_atom/1)

    case RBAC.create_role(role, permissions) do
      :ok ->
        Mix.shell().info("Role '#{role_name}' created with permissions: #{permissions_str}")

      {:error, reason} ->
        Mix.shell().error("Failed to create role: #{inspect(reason)}")
    end
  end

  def run(["role", "list" | _]) do
    Mix.Task.run("app.start")

    {:ok, roles} = RBAC.list_roles()
    Mix.shell().info("Available Roles:")

    Enum.each(roles, fn role ->
      {:ok, permissions} = RBAC.get_role(role)
      Mix.shell().info("  #{role}: #{inspect(permissions)}")
    end)
  end

  def run(["role", "delete", role_name | _]) do
    Mix.Task.run("app.start")

    role = String.to_atom(role_name)

    case RBAC.delete_role(role) do
      :ok ->
        Mix.shell().info("Role '#{role_name}' deleted successfully")

      {:error, reason} ->
        Mix.shell().error("Failed to delete role: #{inspect(reason)}")
    end
  end

  def run(["role", "grant", token, role_name | _]) do
    Mix.Task.run("app.start")

    role = String.to_atom(role_name)

    case RBAC.grant_role(token, role) do
      :ok ->
        Mix.shell().info("Granted role '#{role_name}' to token")

      {:error, reason} ->
        Mix.shell().error("Failed to grant role: #{inspect(reason)}")
    end
  end

  def run(["role", "revoke", token, role_name | _]) do
    Mix.Task.run("app.start")

    role = String.to_atom(role_name)

    case RBAC.revoke_role(token, role) do
      :ok ->
        Mix.shell().info("Revoked role '#{role_name}' from token")

      {:error, reason} ->
        Mix.shell().error("Failed to revoke role: #{inspect(reason)}")
    end
  end

  def run(["acl", "create", pattern, role_name, permissions_str | _]) do
    Mix.Task.run("app.start")

    role = String.to_atom(role_name)
    permissions = permissions_str |> String.split(",") |> Enum.map(&String.to_atom/1)

    case RBAC.create_acl(pattern, role, permissions) do
      :ok ->
        Mix.shell().info("ACL created for pattern '#{pattern}' with role '#{role_name}'")

      {:error, reason} ->
        Mix.shell().error("Failed to create ACL: #{inspect(reason)}")
    end
  end

  def run(["acl", "list" | _]) do
    Mix.Task.run("app.start")

    {:ok, acls} = RBAC.list_acls()
    Mix.shell().info("ACL Rules:")

    if Enum.empty?(acls) do
      Mix.shell().info("  (none)")
    else
      Enum.each(acls, fn {pattern, role, permissions} ->
        Mix.shell().info("  #{pattern} -> #{role}: #{inspect(permissions)}")
      end)
    end
  end

  def run(["acl", "delete", pattern, role_name | _]) do
    Mix.Task.run("app.start")

    role = String.to_atom(role_name)

    case RBAC.delete_acl(pattern, role) do
      :ok ->
        Mix.shell().info("ACL deleted for pattern '#{pattern}' and role '#{role_name}'")

      {:error, reason} ->
        Mix.shell().error("Failed to delete ACL: #{inspect(reason)}")
    end
  end

  # Tenant Management Commands
  def run(["tenant", "create", tenant_id | opts_list]) do
    Mix.Task.run("app.start")

    tenant_atom = String.to_atom(tenant_id)

    # Parse optional arguments
    opts =
      Enum.reduce(opts_list, [], fn opt, acc ->
        case String.split(opt, "=", parts: 2) do
          ["--name", value] -> Keyword.put(acc, :name, value)
          ["--max-keys", value] -> Keyword.put(acc, :max_keys, String.to_integer(value))
          ["--max-storage", value] -> Keyword.put(acc, :max_storage_bytes, String.to_integer(value))
          ["--max-ops", value] -> Keyword.put(acc, :max_ops_per_sec, String.to_integer(value))
          ["--namespace", value] -> Keyword.put(acc, :namespace, value)
          _ -> acc
        end
      end)

    case MultiTenancy.create_tenant(tenant_atom, opts) do
      {:ok, tenant} ->
        Mix.shell().info("✓ Created tenant: #{tenant.id}")
        Mix.shell().info("  Name: #{tenant.name}")
        Mix.shell().info("  Namespace: #{tenant.namespace}")
        Mix.shell().info("  Role: #{tenant.role}")
        Mix.shell().info("")
        Mix.shell().info("  Quotas:")
        Mix.shell().info("    Max Keys: #{format_quota(tenant.quotas.max_keys)}")
        Mix.shell().info("    Max Storage: #{format_bytes(tenant.quotas.max_storage_bytes)}")
        Mix.shell().info("    Max Ops/Sec: #{format_quota(tenant.quotas.max_ops_per_sec)}")
        Mix.shell().info("")
        Mix.shell().info("To grant a token access to this tenant:")
        Mix.shell().info("  mix concord.cluster role grant <token> #{tenant.role}")

      {:error, :tenant_exists} ->
        Mix.shell().error("✗ Tenant #{tenant_id} already exists")

      {:error, reason} ->
        Mix.shell().error("✗ Failed to create tenant: #{inspect(reason)}")
    end
  end

  def run(["tenant", "list" | _]) do
    Mix.Task.run("app.start")

    case MultiTenancy.list_tenants() do
      {:ok, []} ->
        Mix.shell().info("No tenants found")

      {:ok, tenants} ->
        Mix.shell().info("Tenants (#{length(tenants)}):")
        Mix.shell().info("")

        Enum.each(tenants, fn tenant ->
          Mix.shell().info("#{tenant.id} - #{tenant.name}")
          Mix.shell().info("  Namespace: #{tenant.namespace}")
          Mix.shell().info("  Role: #{tenant.role}")
          Mix.shell().info("  Usage: #{tenant.usage.key_count} keys, #{format_bytes(tenant.usage.storage_bytes)}, #{tenant.usage.ops_last_second} ops/sec")
          Mix.shell().info("  Quotas: #{format_quota(tenant.quotas.max_keys)} keys, #{format_bytes(tenant.quotas.max_storage_bytes)}, #{format_quota(tenant.quotas.max_ops_per_sec)} ops/sec")
          Mix.shell().info("")
        end)
    end
  end

  def run(["tenant", "delete", tenant_id | _]) do
    Mix.Task.run("app.start")

    tenant_atom = String.to_atom(tenant_id)

    case MultiTenancy.delete_tenant(tenant_atom) do
      :ok ->
        Mix.shell().info("✓ Deleted tenant: #{tenant_id}")
        Mix.shell().info("  Note: Tenant keys remain in storage")

      {:error, :not_found} ->
        Mix.shell().error("✗ Tenant not found: #{tenant_id}")

      {:error, reason} ->
        Mix.shell().error("✗ Failed to delete tenant: #{inspect(reason)}")
    end
  end

  def run(["tenant", "usage", tenant_id | _]) do
    Mix.Task.run("app.start")

    tenant_atom = String.to_atom(tenant_id)

    case MultiTenancy.get_tenant(tenant_atom) do
      {:ok, tenant} ->
        Mix.shell().info("Tenant: #{tenant.id} - #{tenant.name}")
        Mix.shell().info("")
        Mix.shell().info("Current Usage:")
        Mix.shell().info("  Keys: #{tenant.usage.key_count} / #{format_quota(tenant.quotas.max_keys)}")
        Mix.shell().info("  Storage: #{format_bytes(tenant.usage.storage_bytes)} / #{format_bytes(tenant.quotas.max_storage_bytes)}")
        Mix.shell().info("  Ops/Sec: #{tenant.usage.ops_last_second} / #{format_quota(tenant.quotas.max_ops_per_sec)}")
        Mix.shell().info("")

        # Calculate percentages
        key_pct =
          if tenant.quotas.max_keys == :unlimited,
            do: 0,
            else: Float.round(tenant.usage.key_count / tenant.quotas.max_keys * 100, 2)

        storage_pct =
          if tenant.quotas.max_storage_bytes == :unlimited,
            do: 0,
            else: Float.round(tenant.usage.storage_bytes / tenant.quotas.max_storage_bytes * 100, 2)

        Mix.shell().info("Utilization:")
        Mix.shell().info("  Keys: #{key_pct}%")
        Mix.shell().info("  Storage: #{storage_pct}%")

      {:error, :not_found} ->
        Mix.shell().error("✗ Tenant not found: #{tenant_id}")
    end
  end

  def run(["tenant", "quota", tenant_id, quota_type, value | _]) do
    Mix.Task.run("app.start")

    tenant_atom = String.to_atom(tenant_id)
    quota_atom = String.to_atom(quota_type)

    quota_value =
      case value do
        "unlimited" -> :unlimited
        n -> String.to_integer(n)
      end

    case MultiTenancy.update_quota(tenant_atom, quota_atom, quota_value) do
      {:ok, tenant} ->
        Mix.shell().info("✓ Updated #{quota_type} for tenant #{tenant_id}")
        Mix.shell().info("  New value: #{format_quota(Map.get(tenant.quotas, quota_atom))}")

      {:error, :not_found} ->
        Mix.shell().error("✗ Tenant not found: #{tenant_id}")

      {:error, reason} ->
        Mix.shell().error("✗ Failed to update quota: #{inspect(reason)}")
    end
  end

  def run(_) do
    Mix.shell().info("""
    Usage:
      mix concord.cluster status                - Show cluster status
      mix concord.cluster members               - List cluster members

      Token Management:
      mix concord.cluster token create          - Create authentication token
      mix concord.cluster token revoke TOKEN    - Revoke a token

      Role Management:
      mix concord.cluster role create NAME PERMS  - Create role (e.g., developer read,write)
      mix concord.cluster role list               - List all roles
      mix concord.cluster role delete NAME        - Delete a role
      mix concord.cluster role grant TOKEN ROLE   - Grant role to token
      mix concord.cluster role revoke TOKEN ROLE  - Revoke role from token

      Access Control Lists:
      mix concord.cluster acl create PATTERN ROLE PERMS - Create ACL (e.g., "users:*" viewer read)
      mix concord.cluster acl list                      - List all ACLs
      mix concord.cluster acl delete PATTERN ROLE       - Delete an ACL

      Tenant Management:
      mix concord.cluster tenant create ID [OPTIONS]    - Create tenant
        Options: --name="Name" --max-keys=10000 --max-storage=100000000 --max-ops=1000 --namespace="pattern"
      mix concord.cluster tenant list                   - List all tenants
      mix concord.cluster tenant delete ID              - Delete tenant
      mix concord.cluster tenant usage ID               - Show tenant usage statistics
      mix concord.cluster tenant quota ID TYPE VALUE    - Update quota (max_keys, max_storage_bytes, max_ops_per_sec)
    """)
  end

  # Helper functions for formatting
  defp format_quota(:unlimited), do: "unlimited"
  defp format_quota(value) when is_integer(value), do: to_string(value)

  defp format_bytes(:unlimited), do: "unlimited"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 2)} GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 2)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 2)} KB"
      true -> "#{bytes} bytes"
    end
  end
end
