defmodule Concord.RBAC do
  @moduledoc """
  Role-Based Access Control (RBAC) for Concord.

  Provides fine-grained permission management through roles and access control lists.

  ## Features

  - **Predefined Roles**: Built-in roles for common use cases
  - **Custom Roles**: Create application-specific roles
  - **Per-Key ACLs**: Control access to specific key patterns
  - **Wildcard Support**: Use patterns like "users:*" for namespace control
  - **Token-Role Mapping**: Tokens can have multiple roles
  - **Backward Compatible**: Works with existing simple permission system

  ## Predefined Roles

  - `:admin` - Full access to all operations
  - `:editor` - Read and write access
  - `:viewer` - Read-only access
  - `:none` - No access (explicitly deny)

  ## Permissions

  - `:read` - Read operations (get, get_many, get_all, query)
  - `:write` - Write operations (put, put_many, touch)
  - `:delete` - Delete operations (delete, delete_many)
  - `:admin` - Administrative operations (manage roles, tokens, backups)
  - `:*` - All permissions (wildcard)

  ## Usage

      # Create a role
      :ok = Concord.RBAC.create_role(:developer, [:read, :write])

      # Grant role to token
      {:ok, token} = Concord.Auth.create_token()
      :ok = Concord.RBAC.grant_role(token, :developer)

      # Create ACL for specific key pattern
      :ok = Concord.RBAC.create_acl("users:*", :viewer, [:read])

      # Check permission
      :ok = Concord.RBAC.check_permission(token, :read, "users:123")

  ## Key Patterns

  Patterns support wildcards:
  - `"users:*"` - All keys starting with "users:"
  - `"*:read"` - All keys ending with ":read"
  - `"config:*:settings"` - All keys matching the pattern
  - Exact match takes precedence over wildcards
  """

  alias Concord.Auth.TokenStore

  @type role :: atom()
  @type permission :: :read | :write | :delete | :admin | :*
  @type key_pattern :: String.t()
  @type token :: String.t()

  # Predefined roles
  @predefined_roles %{
    admin: [:*],
    editor: [:read, :write, :delete],
    viewer: [:read],
    none: []
  }

  @doc """
  Creates a new role with specified permissions.

  ## Examples

      iex> Concord.RBAC.create_role(:developer, [:read, :write])
      :ok

      iex> Concord.RBAC.create_role(:analyst, [:read])
      :ok

  ## Returns

  - `:ok` - Role created successfully
  - `{:error, :role_exists}` - Role already exists
  - `{:error, :invalid_permissions}` - Invalid permission list
  """
  @spec create_role(role(), [permission()]) :: :ok | {:error, term()}
  def create_role(role, permissions) when is_atom(role) and is_list(permissions) do
    # Validate permissions
    valid_permissions = [:read, :write, :delete, :admin, :*]

    if Enum.all?(permissions, &(&1 in valid_permissions)) do
      case get_role(role) do
        {:ok, _} ->
          {:error, :role_exists}

        {:error, :not_found} ->
          :ets.insert(:concord_roles, {role, permissions})
          :ok
      end
    else
      {:error, :invalid_permissions}
    end
  end

  def create_role(_role, _permissions), do: {:error, :invalid_arguments}

  @doc """
  Gets the permissions for a role.

  ## Examples

      iex> Concord.RBAC.get_role(:admin)
      {:ok, [:*]}

      iex> Concord.RBAC.get_role(:nonexistent)
      {:error, :not_found}
  """
  @spec get_role(role()) :: {:ok, [permission()]} | {:error, :not_found}
  def get_role(role) when is_atom(role) do
    # Check predefined roles first
    case Map.get(@predefined_roles, role) do
      nil ->
        # Check custom roles in ETS
        case :ets.lookup(:concord_roles, role) do
          [{^role, permissions}] -> {:ok, permissions}
          [] -> {:error, :not_found}
        end

      permissions ->
        {:ok, permissions}
    end
  end

  def get_role(_), do: {:error, :invalid_role}

  @doc """
  Deletes a role.

  Predefined roles cannot be deleted.

  ## Examples

      iex> Concord.RBAC.delete_role(:custom_role)
      :ok

      iex> Concord.RBAC.delete_role(:admin)
      {:error, :protected_role}
  """
  @spec delete_role(role()) :: :ok | {:error, term()}
  def delete_role(role) when is_atom(role) do
    if Map.has_key?(@predefined_roles, role) do
      {:error, :protected_role}
    else
      :ets.delete(:concord_roles, role)
      # Also remove role grants for this role
      :ets.match_delete(:concord_role_grants, {:_, role})
      :ok
    end
  end

  def delete_role(_), do: {:error, :invalid_role}

  @doc """
  Lists all available roles (predefined and custom).

  ## Examples

      iex> Concord.RBAC.list_roles()
      {:ok, [:admin, :editor, :viewer, :none, :developer]}
  """
  @spec list_roles() :: {:ok, [role()]}
  def list_roles do
    predefined = Map.keys(@predefined_roles)
    custom = :ets.select(:concord_roles, [{{:"$1", :_}, [], [:"$1"]}])
    {:ok, predefined ++ custom}
  end

  @doc """
  Grants a role to a token.

  A token can have multiple roles. Permissions are additive.

  ## Examples

      iex> Concord.RBAC.grant_role(token, :editor)
      :ok
  """
  @spec grant_role(token(), role()) :: :ok | {:error, term()}
  def grant_role(token, role) when is_binary(token) and is_atom(role) do
    # Verify role exists
    case get_role(role) do
      {:ok, _permissions} ->
        # Get existing roles for token
        existing_roles = get_token_roles(token)

        unless role in existing_roles do
          :ets.insert(:concord_role_grants, {token, role})
        end

        :ok

      {:error, :not_found} ->
        {:error, :role_not_found}
    end
  end

  def grant_role(_token, _role), do: {:error, :invalid_arguments}

  @doc """
  Revokes a role from a token.

  ## Examples

      iex> Concord.RBAC.revoke_role(token, :editor)
      :ok
  """
  @spec revoke_role(token(), role()) :: :ok
  def revoke_role(token, role) when is_binary(token) and is_atom(role) do
    :ets.match_delete(:concord_role_grants, {token, role})
    :ok
  end

  def revoke_role(_token, _role), do: {:error, :invalid_arguments}

  @doc """
  Gets all roles granted to a token.

  ## Examples

      iex> Concord.RBAC.get_token_roles(token)
      [:editor, :viewer]
  """
  @spec get_token_roles(token()) :: [role()]
  def get_token_roles(token) when is_binary(token) do
    :ets.select(:concord_role_grants, [{{token, :"$1"}, [], [:"$1"]}])
  end

  def get_token_roles(_), do: []

  @doc """
  Creates an ACL rule for a key pattern.

  ACL rules provide fine-grained access control for specific key patterns.

  ## Examples

      # Allow viewers to read all user keys
      iex> Concord.RBAC.create_acl("users:*", :viewer, [:read])
      :ok

      # Allow editors to write to config keys
      iex> Concord.RBAC.create_acl("config:*", :editor, [:read, :write])
      :ok

      # Deny all access to sensitive keys
      iex> Concord.RBAC.create_acl("secrets:*", :none, [])
      :ok
  """
  @spec create_acl(key_pattern(), role(), [permission()]) :: :ok | {:error, term()}
  def create_acl(pattern, role, permissions)
      when is_binary(pattern) and is_atom(role) and is_list(permissions) do
    # Validate role exists
    case get_role(role) do
      {:ok, _} ->
        :ets.insert(:concord_acls, {pattern, role, permissions})
        :ok

      {:error, :not_found} ->
        {:error, :role_not_found}
    end
  end

  def create_acl(_pattern, _role, _permissions), do: {:error, :invalid_arguments}

  @doc """
  Deletes an ACL rule.

  ## Examples

      iex> Concord.RBAC.delete_acl("users:*", :viewer)
      :ok
  """
  @spec delete_acl(key_pattern(), role()) :: :ok
  def delete_acl(pattern, role) when is_binary(pattern) and is_atom(role) do
    :ets.match_delete(:concord_acls, {pattern, role, :_})
    :ok
  end

  def delete_acl(_pattern, _role), do: {:error, :invalid_arguments}

  @doc """
  Lists all ACL rules.

  ## Examples

      iex> Concord.RBAC.list_acls()
      {:ok, [{"users:*", :viewer, [:read]}, {"config:*", :editor, [:read, :write]}]}
  """
  @spec list_acls() :: {:ok, [{key_pattern(), role(), [permission()]}]}
  def list_acls do
    acls = :ets.tab2list(:concord_acls)
    {:ok, acls}
  end

  @doc """
  Checks if a token has permission for an operation on a key.

  This is the main authorization function that should be called before
  performing any operation.

  ## Permission Checking Logic

  1. If ACL rules exist for the key pattern, check those first
  2. Otherwise, check the token's roles
  3. Admin role or wildcard permission grants all access
  4. Token must have at least one role with the required permission

  ## Examples

      iex> Concord.RBAC.check_permission(token, :read, "users:123")
      :ok

      iex> Concord.RBAC.check_permission(token, :delete, "readonly:data")
      {:error, :forbidden}
  """
  @spec check_permission(token(), permission(), String.t()) :: :ok | {:error, :forbidden}
  def check_permission(token, permission, key)
      when is_binary(token) and is_atom(permission) and is_binary(key) do
    # First check if token exists (backward compatibility with simple auth)
    case TokenStore.get(token) do
      {:ok, simple_permissions} ->
        # Check ACL rules first
        case check_acl_permission(token, permission, key) do
          :ok ->
            :ok

          {:error, :no_acl} ->
            # No ACL rules, check role-based permissions
            check_role_permission(token, permission, simple_permissions)

          error ->
            error
        end

      :error ->
        {:error, :unauthorized}
    end
  end

  def check_permission(_token, _permission, _key), do: {:error, :invalid_arguments}

  # Private Functions

  defp check_acl_permission(token, permission, key) do
    # Get token roles
    token_roles = get_token_roles(token)

    # If token has no roles, no ACL check needed
    if Enum.empty?(token_roles) do
      {:error, :no_acl}
    else
      # Get all ACL rules for the token's roles
      all_acls = :ets.tab2list(:concord_acls)

      # Find ACLs that belong to any of the token's roles
      token_role_acls =
        Enum.filter(all_acls, fn {_pattern, acl_role, _perms} -> acl_role in token_roles end)

      # If no ACLs exist for the token's roles, fall back to role permissions
      if Enum.empty?(token_role_acls) do
        {:error, :no_acl}
      else
        # ACLs exist for the token's roles - check if any match the key pattern
        matching_acls =
          Enum.filter(token_role_acls, fn {pattern, _role, _perms} -> matches_pattern?(key, pattern) end)

        # Check if any matching ACL grants the permission
        has_permission =
          Enum.any?(matching_acls, fn {_pattern, _acl_role, acl_permissions} ->
            permission in acl_permissions or :* in acl_permissions
          end)

        if has_permission, do: :ok, else: {:error, :forbidden}
      end
    end
  end

  defp check_role_permission(token, permission, simple_permissions) do
    # Get token roles
    roles = get_token_roles(token)

    # If no roles, fall back to simple permissions (backward compatibility)
    if Enum.empty?(roles) do
      if permission in simple_permissions or :* in simple_permissions do
        :ok
      else
        {:error, :forbidden}
      end
    else
      # Check if any role has the required permission
      has_permission =
        Enum.any?(roles, fn role ->
          case get_role(role) do
            {:ok, perms} -> permission in perms or :* in perms
            _ -> false
          end
        end)

      if has_permission, do: :ok, else: {:error, :forbidden}
    end
  end

  defp matches_pattern?(key, pattern) do
    # Exact match
    if key == pattern do
      true
    else
      # Wildcard matching
      regex_pattern =
        pattern
        |> String.replace("*", ".*")
        |> then(&("^" <> &1 <> "$"))

      case Regex.compile(regex_pattern) do
        {:ok, regex} -> Regex.match?(regex, key)
        _ -> false
      end
    end
  end

  @doc false
  def init_tables do
    # Create ETS tables for RBAC
    :ets.new(:concord_roles, [:set, :public, :named_table])
    :ets.new(:concord_role_grants, [:bag, :public, :named_table])
    :ets.new(:concord_acls, [:bag, :public, :named_table])
    :ok
  end
end
