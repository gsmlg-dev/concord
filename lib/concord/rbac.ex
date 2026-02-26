defmodule Concord.RBAC do
  @moduledoc """
  Role-Based Access Control (RBAC) for Concord.

  All RBAC mutations (create/delete roles, grant/revoke, ACLs) are routed through
  the Raft consensus layer so that RBAC state is consistent across cluster nodes
  and survives restarts.

  Read operations (get_role, check_permission, etc.) read directly from ETS
  for fast access.

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
  """

  alias Concord.Auth.TokenStore

  @cluster_name :concord_cluster
  @timeout 5_000

  @type role :: atom()
  @type permission :: :read | :write | :delete | :admin | :*
  @type key_pattern :: String.t()
  @type token :: String.t()

  # Predefined roles (hardcoded, not in Raft state)
  @predefined_roles %{
    admin: [:*],
    editor: [:read, :write, :delete],
    viewer: [:read],
    none: []
  }

  # ──────────────────────────────────────────────
  # Role Management (mutations go through Raft)
  # ──────────────────────────────────────────────

  @doc """
  Creates a new role with specified permissions via Raft consensus.
  """
  @spec create_role(role(), [permission()]) :: :ok | {:error, term()}
  def create_role(role, permissions) when is_atom(role) and is_list(permissions) do
    valid_permissions = [:read, :write, :delete, :admin, :*]

    if Enum.all?(permissions, &(&1 in valid_permissions)) do
      # Check predefined roles first
      if Map.has_key?(@predefined_roles, role) do
        {:error, :role_exists}
      else
        case ra_command({:rbac_create_role, role, permissions}) do
          {:ok, :ok, _} -> :ok
          {:ok, {:error, reason}, _} -> {:error, reason}
          {:error, :noproc} -> fallback_create_role(role, permissions)
          {:timeout, _} -> {:error, :timeout}
          {:error, reason} -> {:error, reason}
        end
      end
    else
      {:error, :invalid_permissions}
    end
  end

  def create_role(_role, _permissions), do: {:error, :invalid_arguments}

  @doc """
  Gets the permissions for a role.
  Reads from predefined roles or ETS (fast read path).
  """
  @spec get_role(role()) :: {:ok, [permission()]} | {:error, :not_found}
  def get_role(role) when is_atom(role) do
    case Map.get(@predefined_roles, role) do
      nil ->
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
  Deletes a role via Raft consensus. Predefined roles cannot be deleted.
  """
  @spec delete_role(role()) :: :ok | {:error, term()}
  def delete_role(role) when is_atom(role) do
    if Map.has_key?(@predefined_roles, role) do
      {:error, :protected_role}
    else
      case ra_command({:rbac_delete_role, role}) do
        {:ok, :ok, _} -> :ok
        {:ok, {:error, reason}, _} -> {:error, reason}
        {:error, :noproc} -> fallback_delete_role(role)
        {:timeout, _} -> {:error, :timeout}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def delete_role(_), do: {:error, :invalid_role}

  @doc """
  Lists all available roles (predefined and custom).
  """
  @spec list_roles() :: {:ok, [role()]}
  def list_roles do
    predefined = Map.keys(@predefined_roles)
    custom = :ets.select(:concord_roles, [{{:"$1", :_}, [], [:"$1"]}])
    {:ok, predefined ++ custom}
  end

  # ──────────────────────────────────────────────
  # Role Grants (mutations go through Raft)
  # ──────────────────────────────────────────────

  @doc """
  Grants a role to a token via Raft consensus.
  """
  @spec grant_role(token(), role()) :: :ok | {:error, term()}
  def grant_role(token, role) when is_binary(token) and is_atom(role) do
    case get_role(role) do
      {:ok, _permissions} ->
        case ra_command({:rbac_grant_role, token, role}) do
          {:ok, :ok, _} -> :ok
          {:error, :noproc} -> fallback_grant_role(token, role)
          {:timeout, _} -> {:error, :timeout}
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :role_not_found}
    end
  end

  def grant_role(_token, _role), do: {:error, :invalid_arguments}

  @doc """
  Revokes a role from a token via Raft consensus.
  """
  @spec revoke_role(token(), role()) :: :ok
  def revoke_role(token, role) when is_binary(token) and is_atom(role) do
    case ra_command({:rbac_revoke_role, token, role}) do
      {:ok, :ok, _} -> :ok
      {:error, :noproc} -> fallback_revoke_role(token, role)
      {:timeout, _} -> {:error, :timeout}
      {:error, _reason} -> :ok
    end
  end

  def revoke_role(_token, _role), do: {:error, :invalid_arguments}

  @doc """
  Gets all roles granted to a token (reads from ETS).
  """
  @spec get_token_roles(token()) :: [role()]
  def get_token_roles(token) when is_binary(token) do
    :ets.select(:concord_role_grants, [{{token, :"$1"}, [], [:"$1"]}])
  end

  def get_token_roles(_), do: []

  # ──────────────────────────────────────────────
  # ACL Management (mutations go through Raft)
  # ──────────────────────────────────────────────

  @doc """
  Creates an ACL rule for a key pattern via Raft consensus.
  """
  @spec create_acl(key_pattern(), role(), [permission()]) :: :ok | {:error, term()}
  def create_acl(pattern, role, permissions)
      when is_binary(pattern) and is_atom(role) and is_list(permissions) do
    case get_role(role) do
      {:ok, _} ->
        case ra_command({:rbac_create_acl, pattern, role, permissions}) do
          {:ok, :ok, _} -> :ok
          {:error, :noproc} -> fallback_create_acl(pattern, role, permissions)
          {:timeout, _} -> {:error, :timeout}
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :role_not_found}
    end
  end

  def create_acl(_pattern, _role, _permissions), do: {:error, :invalid_arguments}

  @doc """
  Deletes an ACL rule via Raft consensus.
  """
  @spec delete_acl(key_pattern(), role()) :: :ok
  def delete_acl(pattern, role) when is_binary(pattern) and is_atom(role) do
    case ra_command({:rbac_delete_acl, pattern, role}) do
      {:ok, :ok, _} -> :ok
      {:error, :noproc} -> fallback_delete_acl(pattern, role)
      {:timeout, _} -> {:error, :timeout}
      {:error, _reason} -> :ok
    end
  end

  def delete_acl(_pattern, _role), do: {:error, :invalid_arguments}

  @doc """
  Lists all ACL rules (reads from ETS).
  """
  @spec list_acls() :: {:ok, [{key_pattern(), role(), [permission()]}]}
  def list_acls do
    acls = :ets.tab2list(:concord_acls)
    {:ok, acls}
  end

  # ──────────────────────────────────────────────
  # Permission Checking (read-only, no Raft)
  # ──────────────────────────────────────────────

  @doc """
  Checks if a token has permission for an operation on a key.
  """
  @spec check_permission(token(), permission(), String.t()) :: :ok | {:error, :forbidden}
  def check_permission(token, permission, key)
      when is_binary(token) and is_atom(permission) and is_binary(key) do
    case TokenStore.get(token) do
      {:ok, simple_permissions} ->
        case check_acl_permission(token, permission, key) do
          :ok -> :ok
          {:error, :no_acl} -> check_role_permission(token, permission, simple_permissions)
          error -> error
        end

      :error ->
        {:error, :unauthorized}
    end
  end

  def check_permission(_token, _permission, _key), do: {:error, :invalid_arguments}

  # ──────────────────────────────────────────────
  # ETS Table Initialization
  # ──────────────────────────────────────────────

  @doc false
  def init_tables do
    if :ets.whereis(:concord_roles) == :undefined do
      :ets.new(:concord_roles, [:set, :public, :named_table])
    end

    if :ets.whereis(:concord_role_grants) == :undefined do
      :ets.new(:concord_role_grants, [:bag, :public, :named_table])
    end

    if :ets.whereis(:concord_acls) == :undefined do
      :ets.new(:concord_acls, [:bag, :public, :named_table])
    end

    :ok
  end

  # ──────────────────────────────────────────────
  # Private: Ra command helper
  # ──────────────────────────────────────────────

  defp ra_command(cmd) do
    :ra.process_command({@cluster_name, node()}, cmd, @timeout)
  end

  # ──────────────────────────────────────────────
  # Private: Fallback direct ETS writes
  # Used when cluster is not ready (tests, startup)
  # ──────────────────────────────────────────────

  defp fallback_create_role(role, permissions) do
    case get_role(role) do
      {:ok, _} -> {:error, :role_exists}
      {:error, :not_found} ->
        :ets.insert(:concord_roles, {role, permissions})
        :ok
    end
  end

  defp fallback_delete_role(role) do
    :ets.delete(:concord_roles, role)
    :ets.match_delete(:concord_role_grants, {:_, role})
    :ok
  end

  defp fallback_grant_role(token, role) do
    existing_roles = get_token_roles(token)

    unless role in existing_roles do
      :ets.insert(:concord_role_grants, {token, role})
    end

    :ok
  end

  defp fallback_revoke_role(token, role) do
    :ets.match_delete(:concord_role_grants, {token, role})
    :ok
  end

  defp fallback_create_acl(pattern, role, permissions) do
    :ets.insert(:concord_acls, {pattern, role, permissions})
    :ok
  end

  defp fallback_delete_acl(pattern, role) do
    :ets.match_delete(:concord_acls, {pattern, role, :_})
    :ok
  end

  # ──────────────────────────────────────────────
  # Private: Permission checking internals
  # ──────────────────────────────────────────────

  defp check_acl_permission(token, permission, key) do
    token_roles = get_token_roles(token)

    if Enum.empty?(token_roles) do
      {:error, :no_acl}
    else
      all_acls = :ets.tab2list(:concord_acls)

      token_role_acls =
        Enum.filter(all_acls, fn {_pattern, acl_role, _perms} -> acl_role in token_roles end)

      if Enum.empty?(token_role_acls) do
        {:error, :no_acl}
      else
        matching_acls =
          Enum.filter(token_role_acls, fn {pattern, _role, _perms} ->
            matches_pattern?(key, pattern)
          end)

        has_permission =
          Enum.any?(matching_acls, fn {_pattern, _acl_role, acl_permissions} ->
            permission in acl_permissions or :* in acl_permissions
          end)

        if has_permission, do: :ok, else: {:error, :forbidden}
      end
    end
  end

  defp check_role_permission(token, permission, simple_permissions) do
    roles = get_token_roles(token)

    if Enum.empty?(roles) do
      if permission in simple_permissions or :* in simple_permissions do
        :ok
      else
        {:error, :forbidden}
      end
    else
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
    if key == pattern do
      true
    else
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
end
