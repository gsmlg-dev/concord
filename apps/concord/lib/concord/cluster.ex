defmodule Concord.Cluster do
  @moduledoc """
  Explicit Raft-cluster Concord API.

  `Concord` itself remains cluster-backed for compatibility. This module exists
  when call sites should state the storage/concurrency model directly.
  """

  alias Concord.APIOptions

  def put(key, value, opts \\ []), do: Concord.put(key, value, APIOptions.cluster(opts))
  def get(key, opts \\ []), do: Concord.get(key, APIOptions.cluster(opts))
  def delete(key, opts \\ []), do: Concord.delete(key, APIOptions.cluster(opts))
  def put_if(key, value, opts), do: Concord.put_if(key, value, APIOptions.cluster(opts))
  def delete_if(key, opts), do: Concord.delete_if(key, APIOptions.cluster(opts))
  def get_all(opts \\ []), do: Concord.get_all(APIOptions.cluster(opts))
  def status(opts \\ []), do: Concord.status(APIOptions.cluster(opts))
  def members(opts \\ []), do: Concord.members(APIOptions.cluster(opts))

  def put_with_ttl(key, value, ttl_seconds, opts \\ []) do
    Concord.put_with_ttl(key, value, ttl_seconds, APIOptions.cluster(opts))
  end

  def touch(key, additional_ttl_seconds, opts \\ []) do
    Concord.touch(key, additional_ttl_seconds, APIOptions.cluster(opts))
  end

  def ttl(key, opts \\ []), do: Concord.ttl(key, APIOptions.cluster(opts))
  def get_with_ttl(key, opts \\ []), do: Concord.get_with_ttl(key, APIOptions.cluster(opts))
  def get_all_with_ttl(opts \\ []), do: Concord.get_all_with_ttl(APIOptions.cluster(opts))
  def prefix_scan(prefix, opts \\ []), do: Concord.prefix_scan(prefix, APIOptions.cluster(opts))
  def put_many(operations, opts \\ []), do: Concord.put_many(operations, APIOptions.cluster(opts))

  def put_many_with_ttl(operations, ttl_seconds, opts \\ []) do
    Concord.put_many_with_ttl(operations, ttl_seconds, APIOptions.cluster(opts))
  end

  def get_many(keys, opts \\ []), do: Concord.get_many(keys, APIOptions.cluster(opts))
  def delete_many(keys, opts \\ []), do: Concord.delete_many(keys, APIOptions.cluster(opts))

  def touch_many(operations, opts \\ []),
    do: Concord.touch_many(operations, APIOptions.cluster(opts))

  def revision(opts \\ []), do: Concord.revision(APIOptions.cluster(opts))
  def list(opts), do: Concord.list(APIOptions.cluster(opts))
  def txn(spec, opts \\ []), do: Concord.txn(spec, APIOptions.cluster(opts))
end
