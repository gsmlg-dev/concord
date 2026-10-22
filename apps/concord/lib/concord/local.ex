defmodule Concord.Local do
  @moduledoc """
  Node-local Concord API.

  This module uses the local KV engine explicitly. Data written through this
  API stays on the current BEAM node and is not submitted to the VSR cluster.

  `put/3`, `put_if/3`, `put_many/2`, their TTL variants, and
  `Concord.Local.KV.put/3` support PIDs inside values for transient session
  metadata. Conditional operations may compare those values with `:expected`.
  Stored PIDs retain their identity; they are not monitored or removed when
  their processes exit. All local data is lost when the local engine restarts.

  Functions, ports, and references remain invalid. Transactions, index
  definitions, and command metadata retain deterministic term validation.
  Replicated Concord and durable Turso writes also continue to reject PIDs.

  `Concord.Backup.create/1` with `engine: :local` refuses an export containing
  PIDs, including compressed values. Remove transient values before making a
  backup. Restores retain deterministic validation. Extracting engine state
  through `:sys` and passing it directly to Core snapshot callbacks is not a
  supported local export or migration API.
  """

  alias Concord.APIOptions

  def put(key, value, opts \\ []), do: Concord.put(key, value, APIOptions.local(opts))
  def get(key, opts \\ []), do: Concord.get(key, APIOptions.local(opts))
  def delete(key, opts \\ []), do: Concord.delete(key, APIOptions.local(opts))
  def put_if(key, value, opts), do: Concord.put_if(key, value, APIOptions.local(opts))
  def delete_if(key, opts), do: Concord.delete_if(key, APIOptions.local(opts))
  def get_all(opts \\ []), do: Concord.get_all(APIOptions.local(opts))
  def status(opts \\ []), do: Concord.status(APIOptions.local(opts))
  def members(opts \\ []), do: Concord.members(APIOptions.local(opts))

  def put_with_ttl(key, value, ttl_seconds, opts \\ []) do
    Concord.put_with_ttl(key, value, ttl_seconds, APIOptions.local(opts))
  end

  def touch(key, additional_ttl_seconds, opts \\ []) do
    Concord.touch(key, additional_ttl_seconds, APIOptions.local(opts))
  end

  def ttl(key, opts \\ []), do: Concord.ttl(key, APIOptions.local(opts))
  def get_with_ttl(key, opts \\ []), do: Concord.get_with_ttl(key, APIOptions.local(opts))
  def get_all_with_ttl(opts \\ []), do: Concord.get_all_with_ttl(APIOptions.local(opts))
  def prefix_scan(prefix, opts \\ []), do: Concord.prefix_scan(prefix, APIOptions.local(opts))
  def put_many(operations, opts \\ []), do: Concord.put_many(operations, APIOptions.local(opts))

  def put_many_with_ttl(operations, ttl_seconds, opts \\ []) do
    Concord.put_many_with_ttl(operations, ttl_seconds, APIOptions.local(opts))
  end

  def get_many(keys, opts \\ []), do: Concord.get_many(keys, APIOptions.local(opts))
  def delete_many(keys, opts \\ []), do: Concord.delete_many(keys, APIOptions.local(opts))

  def touch_many(operations, opts \\ []),
    do: Concord.touch_many(operations, APIOptions.local(opts))

  def revision(opts \\ []), do: Concord.revision(APIOptions.local(opts))
  def list(opts), do: Concord.list(APIOptions.local(opts))
  def txn(spec, opts \\ []), do: Concord.txn(spec, APIOptions.local(opts))
end
