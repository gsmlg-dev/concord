defmodule Concord.Cluster.Lease do
  @moduledoc "Explicit Raft-cluster `Concord.Lease` API."

  alias Concord.{APIOptions, Lease}

  def grant(ttl_seconds, opts \\ []),
    do: Lease.grant(ttl_seconds, APIOptions.cluster(opts))

  def keep_alive(lease_id, opts \\ []),
    do: Lease.keep_alive(lease_id, APIOptions.cluster(opts))

  def revoke(lease_id, opts \\ []), do: Lease.revoke(lease_id, APIOptions.cluster(opts))
  def info(lease_id, opts \\ []), do: Lease.info(lease_id, APIOptions.cluster(opts))
  def list(opts \\ []), do: Lease.list(APIOptions.cluster(opts))
end
