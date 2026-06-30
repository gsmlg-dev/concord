defmodule Concord.Local.Lease do
  @moduledoc "Node-local `Concord.Lease` API."

  alias Concord.{APIOptions, Lease}

  def grant(ttl_seconds, opts \\ []), do: Lease.grant(ttl_seconds, APIOptions.local(opts))

  def keep_alive(lease_id, opts \\ []),
    do: Lease.keep_alive(lease_id, APIOptions.local(opts))

  def revoke(lease_id, opts \\ []), do: Lease.revoke(lease_id, APIOptions.local(opts))
  def info(lease_id, opts \\ []), do: Lease.info(lease_id, APIOptions.local(opts))
  def list(opts \\ []), do: Lease.list(APIOptions.local(opts))
end
