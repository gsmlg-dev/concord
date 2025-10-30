defmodule Concord.MultiTenancy do
  @moduledoc """
  Multi-tenancy support for Concord with resource quotas and usage tracking.

  Provides tenant isolation, resource limits, and usage metrics to support
  multiple independent tenants on a single Concord cluster.

  ## Features

  - **Tenant Isolation**: Automatic namespace isolation via RBAC ACLs
  - **Resource Quotas**: Configurable limits per tenant (keys, storage, rate limits)
  - **Usage Tracking**: Real-time monitoring of resource consumption
  - **Automatic RBAC Integration**: Auto-creates roles and ACLs for tenants
  - **Quota Enforcement**: Prevents operations that exceed tenant limits

  ## Tenant Structure

  Each tenant has:
  - Unique ID (atom)
  - Display name
  - Key namespace pattern (e.g., "tenant1:*")
  - Resource quotas (max_keys, max_storage_bytes, max_ops_per_sec)
  - Current usage statistics
  - RBAC role and ACL for isolation
  - Metadata (created_at, updated_at)

  ## Usage

      # Create a tenant with quotas
      {:ok, tenant} = Concord.MultiTenancy.create_tenant(
        :acme_corp,
        name: "ACME Corporation",
        max_keys: 10_000,
        max_storage_bytes: 100_000_000,
        max_ops_per_sec: 1000
      )

      # Create a token for the tenant
      {:ok, token} = Concord.Auth.create_token()
      :ok = Concord.RBAC.grant_role(token, :tenant_acme_corp)

      # Operations are automatically quota-checked
      :ok = Concord.put("acme_corp:users:123", %{name: "Alice"}, token: token)

      # Get usage statistics
      {:ok, usage} = Concord.MultiTenancy.get_usage(:acme_corp)

  ## Quota Enforcement

  Quotas are enforced at operation time:
  - `max_keys`: Maximum number of keys the tenant can store
  - `max_storage_bytes`: Maximum total size of values (in bytes)
  - `max_ops_per_sec`: Rate limit for operations (sliding window)

  When a quota is exceeded, operations return `{:error, :quota_exceeded}`.
  """

  alias Concord.RBAC
  require Logger

  @type tenant_id :: atom()
  @type quota :: non_neg_integer() | :unlimited

  @type tenant :: %{
          id: tenant_id(),
          name: String.t(),
          namespace: String.t(),
          quotas: %{
            max_keys: quota(),
            max_storage_bytes: quota(),
            max_ops_per_sec: quota()
          },
          usage: %{
            key_count: non_neg_integer(),
            storage_bytes: non_neg_integer(),
            ops_last_second: non_neg_integer()
          },
          role: atom(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Creates a new tenant with specified quotas and automatic RBAC setup.

  ## Options

  - `:name` - Display name for the tenant (default: stringified ID)
  - `:namespace` - Key namespace pattern (default: "TENANT_ID:*")
  - `:max_keys` - Maximum keys allowed (default: 10,000)
  - `:max_storage_bytes` - Maximum storage in bytes (default: 100MB)
  - `:max_ops_per_sec` - Maximum operations per second (default: 1,000)

  ## Examples

      iex> Concord.MultiTenancy.create_tenant(:acme, name: "ACME Corp", max_keys: 5000)
      {:ok, %{id: :acme, name: "ACME Corp", ...}}

      iex> Concord.MultiTenancy.create_tenant(:acme)
      {:error, :tenant_exists}

  ## Returns

  - `{:ok, tenant}` - Tenant created successfully
  - `{:error, :tenant_exists}` - Tenant with this ID already exists
  - `{:error, :invalid_id}` - Tenant ID must be an atom
  """
  @spec create_tenant(tenant_id(), keyword()) :: {:ok, tenant()} | {:error, term()}
  def create_tenant(tenant_id, opts \\ [])

  def create_tenant(tenant_id, opts) when is_atom(tenant_id) do
    # Check if tenant already exists
    case get_tenant(tenant_id) do
      {:ok, _} ->
        {:error, :tenant_exists}

      {:error, :not_found} ->
        name = Keyword.get(opts, :name, to_string(tenant_id))
        namespace = Keyword.get(opts, :namespace, "#{tenant_id}:*")
        max_keys = Keyword.get(opts, :max_keys, 10_000)
        max_storage = Keyword.get(opts, :max_storage_bytes, 100_000_000)
        max_ops = Keyword.get(opts, :max_ops_per_sec, 1_000)

        now = DateTime.utc_now()

        tenant = %{
          id: tenant_id,
          name: name,
          namespace: namespace,
          quotas: %{
            max_keys: max_keys,
            max_storage_bytes: max_storage,
            max_ops_per_sec: max_ops
          },
          usage: %{
            key_count: 0,
            storage_bytes: 0,
            ops_last_second: 0
          },
          role: tenant_role_name(tenant_id),
          created_at: now,
          updated_at: now
        }

        # Create tenant-specific RBAC role
        role = tenant.role
        :ok = RBAC.create_role(role, [:read, :write, :delete])

        # Create ACL for tenant namespace
        :ok = RBAC.create_acl(namespace, role, [:read, :write, :delete])

        # Store tenant in ETS
        :ets.insert(:concord_tenants, {tenant_id, tenant})

        Logger.info("Created tenant #{tenant_id} with namespace #{namespace}")

        {:ok, tenant}
    end
  end

  def create_tenant(_tenant_id, _opts), do: {:error, :invalid_id}

  @doc """
  Gets tenant information by ID.

  ## Examples

      iex> Concord.MultiTenancy.get_tenant(:acme)
      {:ok, %{id: :acme, ...}}

      iex> Concord.MultiTenancy.get_tenant(:nonexistent)
      {:error, :not_found}
  """
  @spec get_tenant(tenant_id()) :: {:ok, tenant()} | {:error, :not_found}
  def get_tenant(tenant_id) when is_atom(tenant_id) do
    case :ets.lookup(:concord_tenants, tenant_id) do
      [{^tenant_id, tenant}] -> {:ok, tenant}
      [] -> {:error, :not_found}
    end
  end

  def get_tenant(_), do: {:error, :invalid_id}

  @doc """
  Lists all tenants in the system.

  ## Examples

      iex> Concord.MultiTenancy.list_tenants()
      {:ok, [%{id: :acme, ...}, %{id: :widgets_inc, ...}]}
  """
  @spec list_tenants() :: {:ok, [tenant()]}
  def list_tenants do
    tenants =
      :ets.tab2list(:concord_tenants)
      |> Enum.map(fn {_id, tenant} -> tenant end)
      |> Enum.sort_by(& &1.id)

    {:ok, tenants}
  end

  @doc """
  Deletes a tenant and all associated resources.

  This removes the tenant, its RBAC role and ACL, and revokes the role from all tokens.
  Note: This does NOT delete the tenant's keys from storage.

  ## Examples

      iex> Concord.MultiTenancy.delete_tenant(:acme)
      :ok

      iex> Concord.MultiTenancy.delete_tenant(:nonexistent)
      {:error, :not_found}
  """
  @spec delete_tenant(tenant_id()) :: :ok | {:error, term()}
  def delete_tenant(tenant_id) when is_atom(tenant_id) do
    case get_tenant(tenant_id) do
      {:ok, tenant} ->
        # Delete RBAC ACL
        :ok = RBAC.delete_acl(tenant.namespace, tenant.role)

        # Delete RBAC role (also revokes from all tokens)
        :ok = RBAC.delete_role(tenant.role)

        # Delete tenant from ETS
        :ets.delete(:concord_tenants, tenant_id)

        Logger.info("Deleted tenant #{tenant_id}")
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def delete_tenant(_), do: {:error, :invalid_id}

  @doc """
  Updates tenant quotas.

  ## Options

  - `:max_keys` - Maximum keys allowed
  - `:max_storage_bytes` - Maximum storage in bytes
  - `:max_ops_per_sec` - Maximum operations per second

  ## Examples

      iex> Concord.MultiTenancy.update_quota(:acme, :max_keys, 20_000)
      {:ok, %{id: :acme, quotas: %{max_keys: 20_000, ...}}}
  """
  @spec update_quota(tenant_id(), atom(), quota()) :: {:ok, tenant()} | {:error, term()}
  def update_quota(tenant_id, quota_type, value)
      when is_atom(tenant_id) and quota_type in [:max_keys, :max_storage_bytes, :max_ops_per_sec] and
             (is_integer(value) and value >= 0 or value == :unlimited) do
    case get_tenant(tenant_id) do
      {:ok, tenant} ->
        updated_quotas = Map.put(tenant.quotas, quota_type, value)
        updated_tenant = %{tenant | quotas: updated_quotas, updated_at: DateTime.utc_now()}

        :ets.insert(:concord_tenants, {tenant_id, updated_tenant})

        Logger.info("Updated #{quota_type} for tenant #{tenant_id} to #{value}")
        {:ok, updated_tenant}

      error ->
        error
    end
  end

  def update_quota(_tenant_id, _quota_type, _value), do: {:error, :invalid_arguments}

  @doc """
  Gets current usage statistics for a tenant.

  ## Examples

      iex> Concord.MultiTenancy.get_usage(:acme)
      {:ok, %{key_count: 1234, storage_bytes: 567890, ops_last_second: 45}}
  """
  @spec get_usage(tenant_id()) :: {:ok, map()} | {:error, term()}
  def get_usage(tenant_id) when is_atom(tenant_id) do
    case get_tenant(tenant_id) do
      {:ok, tenant} -> {:ok, tenant.usage}
      error -> error
    end
  end

  @doc """
  Checks if an operation is within tenant quotas.

  This should be called before performing operations to ensure quotas aren't exceeded.

  ## Examples

      iex> Concord.MultiTenancy.check_quota(:acme, :write, key_size: 100)
      :ok

      iex> Concord.MultiTenancy.check_quota(:acme, :write, key_size: 999_999_999)
      {:error, :quota_exceeded}
  """
  @spec check_quota(tenant_id(), :read | :write | :delete, keyword()) ::
          :ok | {:error, :quota_exceeded | :not_found}
  def check_quota(tenant_id, operation, opts \\ [])
      when is_atom(tenant_id) and operation in [:read, :write, :delete] do
    case get_tenant(tenant_id) do
      {:ok, tenant} ->
        cond do
          # Check key count quota for writes
          operation == :write and tenant.quotas.max_keys != :unlimited and
              tenant.usage.key_count >= tenant.quotas.max_keys ->
            {:error, :quota_exceeded}

          # Check storage quota for writes
          operation == :write and tenant.quotas.max_storage_bytes != :unlimited ->
            additional_size = Keyword.get(opts, :value_size, 0)

            if tenant.usage.storage_bytes + additional_size > tenant.quotas.max_storage_bytes do
              {:error, :quota_exceeded}
            else
              # Storage is OK, but still need to check rate limit
              if tenant.quotas.max_ops_per_sec != :unlimited and
                   tenant.usage.ops_last_second >= tenant.quotas.max_ops_per_sec do
                {:error, :quota_exceeded}
              else
                :ok
              end
            end

          # Check rate limit (for non-writes or unlimited storage)
          tenant.quotas.max_ops_per_sec != :unlimited and
              tenant.usage.ops_last_second >= tenant.quotas.max_ops_per_sec ->
            {:error, :quota_exceeded}

          true ->
            :ok
        end

      error ->
        error
    end
  end

  @doc """
  Records an operation for usage tracking.

  This updates the tenant's usage statistics and should be called after successful operations.

  ## Examples

      iex> Concord.MultiTenancy.record_operation(:acme, :write, key_delta: 1, storage_delta: 256)
      :ok
  """
  @spec record_operation(tenant_id(), :read | :write | :delete, keyword()) :: :ok | {:error, term()}
  def record_operation(tenant_id, operation, opts \\ [])
      when is_atom(tenant_id) and operation in [:read, :write, :delete] do
    case get_tenant(tenant_id) do
      {:ok, tenant} ->
        key_delta = Keyword.get(opts, :key_delta, 0)
        storage_delta = Keyword.get(opts, :storage_delta, 0)

        updated_usage = %{
          tenant.usage
          | key_count: max(0, tenant.usage.key_count + key_delta),
            storage_bytes: max(0, tenant.usage.storage_bytes + storage_delta),
            ops_last_second: tenant.usage.ops_last_second + 1
        }

        updated_tenant = %{tenant | usage: updated_usage, updated_at: DateTime.utc_now()}
        :ets.insert(:concord_tenants, {tenant_id, updated_tenant})

        :ok

      _ ->
        # If tenant doesn't exist, silently ignore (not all operations are tenant-scoped)
        :ok
    end
  end

  @doc """
  Resets the per-second operation counter for all tenants.

  This should be called periodically (every second) to implement rate limiting.
  """
  @spec reset_rate_counters() :: :ok
  def reset_rate_counters do
    :ets.tab2list(:concord_tenants)
    |> Enum.each(fn {tenant_id, tenant} ->
      updated_usage = %{tenant.usage | ops_last_second: 0}
      updated_tenant = %{tenant | usage: updated_usage}
      :ets.insert(:concord_tenants, {tenant_id, updated_tenant})
    end)

    :ok
  end

  @doc """
  Extracts tenant ID from a key based on namespace pattern.

  ## Examples

      iex> Concord.MultiTenancy.tenant_from_key("acme:users:123")
      {:ok, :acme}

      iex> Concord.MultiTenancy.tenant_from_key("invalid_key")
      {:error, :no_tenant}
  """
  @spec tenant_from_key(String.t()) :: {:ok, tenant_id()} | {:error, :no_tenant}
  def tenant_from_key(key) when is_binary(key) do
    # Try to extract tenant ID from key (assumes pattern "tenant_id:*")
    case String.split(key, ":", parts: 2) do
      [tenant_prefix | _] ->
        tenant_id =
          try do
            String.to_existing_atom(tenant_prefix)
          rescue
            ArgumentError -> nil
          end

        if tenant_id && match?({:ok, _}, get_tenant(tenant_id)) do
          {:ok, tenant_id}
        else
          {:error, :no_tenant}
        end

      _ ->
        {:error, :no_tenant}
    end
  end

  @doc false
  def init_tables do
    :ets.new(:concord_tenants, [:set, :public, :named_table])
    :ok
  end

  # Private Functions

  defp tenant_role_name(tenant_id), do: :"tenant_#{tenant_id}"
end
