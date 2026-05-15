defmodule Concord.Lease do
  @moduledoc """
  Public API for Concord's grouped TTL / lease system.

  A lease is a named TTL contract: keys attached to a lease are atomically
  deleted when the lease expires or is revoked. Leases unify TTL management
  and provide group-level expiration.

  ## Usage

      # Grant a 30-second lease
      {:ok, %{lease_id: id}} = Concord.Lease.grant(30)

      # Attach keys to the lease
      Concord.KV.put("key1", "val1", lease: id)
      Concord.KV.put("key2", "val2", lease: id)

      # Keep alive (reset TTL)
      :ok = Concord.Lease.keep_alive(id)

      # Revoke (deletes all attached keys atomically)
      :ok = Concord.Lease.revoke(id)

  ## Lease Object

      %{
        id:           integer(),
        ttl:          integer(),     # granted TTL in seconds
        remaining:    integer(),     # remaining TTL in seconds
        granted_at:   integer(),     # revision when granted
        keys:         [binary()]     # currently attached keys
      }
  """

  alias Concord.StateMachine

  @timeout 5_000
  @cluster_name :concord_cluster

  @doc """
  Grants a new lease with the given TTL in seconds.

  ## Options

  - `:timeout` — operation timeout in ms (default: 5000)

  ## Returns

  `{:ok, %{lease_id: integer(), ttl: integer()}}` on success.
  """
  @spec grant(pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def grant(ttl_seconds, opts \\ []) when is_integer(ttl_seconds) and ttl_seconds > 0 do
    timeout = Keyword.get(opts, :timeout, @timeout)
    cmd = {:grant_lease, ttl_seconds, %{}}

    case :ra.process_command(server_id(), cmd, timeout) do
      {:ok, {:ok, result}, _} -> {:ok, result}
      {:ok, {:error, reason}, _} -> {:error, reason}
      {:timeout, _} -> {:error, :timeout}
      {:error, :noproc} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Refreshes a lease, resetting its TTL to the original granted value.

  ## Returns

  `:ok` on success, `{:error, :lease_not_found}` if the lease doesn't exist.
  """
  @spec keep_alive(integer(), keyword()) :: :ok | {:error, term()}
  def keep_alive(lease_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    cmd = {:keep_alive_lease, lease_id, %{}}

    case :ra.process_command(server_id(), cmd, timeout) do
      {:ok, :ok, _} -> :ok
      {:ok, {:error, reason}, _} -> {:error, reason}
      {:timeout, _} -> {:error, :timeout}
      {:error, :noproc} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Revokes a lease and atomically deletes all attached keys.

  ## Returns

  `{:ok, %{deleted_keys: integer()}}` on success.
  """
  @spec revoke(integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def revoke(lease_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    cmd = {:revoke_lease, lease_id, %{}}

    case :ra.process_command(server_id(), cmd, timeout) do
      {:ok, {:ok, result}, _} -> {:ok, result}
      {:ok, {:error, reason}, _} -> {:error, reason}
      {:timeout, _} -> {:error, :timeout}
      {:error, :noproc} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns information about a lease.
  """
  @spec info(integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def info(lease_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    mfa = {StateMachine, :query, [{:lease_info, lease_id}]}

    case :ra.leader_query(server_id(), mfa, timeout) do
      {:ok, {{_, _}, result}, _} -> result
      {:timeout, _} -> {:error, :timeout}
      {:error, :noproc} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists all active leases.
  """
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    mfa = {StateMachine, :query, [:list_leases]}

    case :ra.leader_query(server_id(), mfa, timeout) do
      {:ok, {{_, _}, result}, _} -> result
      {:timeout, _} -> {:error, :timeout}
      {:error, :noproc} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  defp server_id, do: {@cluster_name, node()}
end
