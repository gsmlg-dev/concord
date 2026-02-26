defmodule Concord.MultiTenancy do
  @moduledoc """
  Multi-tenancy support for Concord with resource quotas and usage tracking.

  Tenant definitions (id, name, namespace, quotas, RBAC role) are replicated
  through Raft consensus so they survive restarts and are consistent across nodes.

  Usage counters (key_count, storage_bytes, ops_last_second) are **node-local**
  and not replicated — they track per-node metrics for rate limiting.
  """

  alias Concord.RBAC
  require Logger

  @cluster_name :concord_cluster
  @timeout 5_000

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
  Creates a new tenant with quotas and automatic RBAC setup via Raft consensus.
  """
  @spec create_tenant(tenant_id(), keyword()) :: {:ok, tenant()} | {:error, term()}
  def create_tenant(tenant_id, opts \\ [])

  def create_tenant(tenant_id, opts) when is_atom(tenant_id) do
    # Check if tenant already exists locally
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
        role = tenant_role_name(tenant_id)

        tenant_def = %{
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
          role: role,
          created_at: now,
          updated_at: now
        }

        # Create RBAC role and ACL (these now go through Raft too)
        :ok = RBAC.create_role(role, [:read, :write, :delete])
        :ok = RBAC.create_acl(namespace, role, [:read, :write, :delete])

        # Store tenant definition through Raft
        case ra_command({:tenant_create, tenant_id, tenant_def}) do
          {:ok, {:ok, _tenant}, _} ->
            Logger.info("Created tenant #{tenant_id} with namespace #{namespace}")
            {:ok, tenant_def}

          {:ok, {:error, reason}, _} ->
            {:error, reason}

          {:error, :noproc} ->
            # Fallback for pre-cluster scenarios
            :ets.insert(:concord_tenants, {tenant_id, tenant_def})
            Logger.info("Created tenant #{tenant_id} (local fallback)")
            {:ok, tenant_def}

          {:timeout, _} ->
            {:error, :timeout}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def create_tenant(_tenant_id, _opts), do: {:error, :invalid_id}

  @doc """
  Gets tenant information by ID (reads from ETS).
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
  Lists all tenants (reads from ETS).
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
  Deletes a tenant and associated RBAC resources via Raft consensus.
  Does NOT delete the tenant's keys from storage.
  """
  @spec delete_tenant(tenant_id()) :: :ok | {:error, term()}
  def delete_tenant(tenant_id) when is_atom(tenant_id) do
    case get_tenant(tenant_id) do
      {:ok, tenant} ->
        # Delete RBAC resources (goes through Raft)
        :ok = RBAC.delete_acl(tenant.namespace, tenant.role)
        :ok = RBAC.delete_role(tenant.role)

        # Delete tenant through Raft
        case ra_command({:tenant_delete, tenant_id}) do
          {:ok, :ok, _} ->
            Logger.info("Deleted tenant #{tenant_id}")
            :ok

          {:error, :noproc} ->
            :ets.delete(:concord_tenants, tenant_id)
            :ok

          {:timeout, _} ->
            {:error, :timeout}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def delete_tenant(_), do: {:error, :invalid_id}

  @doc """
  Updates tenant quotas via Raft consensus.
  """
  @spec update_quota(tenant_id(), atom(), quota()) :: {:ok, tenant()} | {:error, term()}
  def update_quota(tenant_id, quota_type, value)
      when is_atom(tenant_id) and quota_type in [:max_keys, :max_storage_bytes, :max_ops_per_sec] and
             ((is_integer(value) and value >= 0) or value == :unlimited) do
    case ra_command({:tenant_update_quota, tenant_id, quota_type, value}) do
      {:ok, {:ok, updated_tenant}, _} ->
        {:ok, updated_tenant}

      {:ok, {:error, reason}, _} ->
        {:error, reason}

      {:error, :noproc} ->
        fallback_update_quota(tenant_id, quota_type, value)

      {:timeout, _} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def update_quota(_tenant_id, _quota_type, _value), do: {:error, :invalid_arguments}

  # ──────────────────────────────────────────────
  # Usage tracking (node-local, NOT replicated)
  # ──────────────────────────────────────────────

  @doc """
  Gets current usage statistics for a tenant.
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
  """
  @spec check_quota(tenant_id(), :read | :write | :delete, keyword()) ::
          :ok | {:error, :quota_exceeded | :not_found}
  def check_quota(tenant_id, operation, opts \\ [])
      when is_atom(tenant_id) and operation in [:read, :write, :delete] do
    case get_tenant(tenant_id) do
      {:ok, tenant} ->
        cond do
          operation == :write and tenant.quotas.max_keys != :unlimited and
              tenant.usage.key_count >= tenant.quotas.max_keys ->
            {:error, :quota_exceeded}

          operation == :write and tenant.quotas.max_storage_bytes != :unlimited ->
            additional_size = Keyword.get(opts, :value_size, 0)

            if tenant.usage.storage_bytes + additional_size > tenant.quotas.max_storage_bytes do
              {:error, :quota_exceeded}
            else
              if tenant.quotas.max_ops_per_sec != :unlimited and
                   tenant.usage.ops_last_second >= tenant.quotas.max_ops_per_sec do
                {:error, :quota_exceeded}
              else
                :ok
              end
            end

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
  Records an operation for usage tracking (node-local, direct ETS update).
  """
  @spec record_operation(tenant_id(), :read | :write | :delete, keyword()) ::
          :ok | {:error, term()}
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
        :ok
    end
  end

  @doc """
  Resets the per-second operation counter for all tenants (node-local).
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
  """
  @spec tenant_from_key(String.t()) :: {:ok, tenant_id()} | {:error, :no_tenant}
  def tenant_from_key(key) when is_binary(key) do
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
    if :ets.whereis(:concord_tenants) == :undefined do
      :ets.new(:concord_tenants, [:set, :public, :named_table])
    end

    :ok
  end

  # Private

  defp tenant_role_name(tenant_id), do: :"tenant_#{tenant_id}"

  defp ra_command(cmd) do
    :ra.process_command({@cluster_name, node()}, cmd, @timeout)
  end

  defp fallback_update_quota(tenant_id, quota_type, value) do
    case get_tenant(tenant_id) do
      {:ok, tenant} ->
        updated_quotas = Map.put(tenant.quotas, quota_type, value)
        updated_tenant = %{tenant | quotas: updated_quotas, updated_at: DateTime.utc_now()}
        :ets.insert(:concord_tenants, {tenant_id, updated_tenant})
        {:ok, updated_tenant}

      error ->
        error
    end
  end
end
