defmodule Mix.Tasks.Concord.Cluster do
  @moduledoc """
  Mix tasks for managing Concord clusters.
  """

  use Mix.Task
  alias Concord.Auth
  alias Concord.RBAC

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
    """)
  end
end
