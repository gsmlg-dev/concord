defmodule Concord.Cluster.KV do
  @moduledoc "Explicit Raft-cluster `Concord.KV` API."

  alias Concord.{APIOptions, KV}

  def get(key, opts \\ []), do: KV.get(key, APIOptions.cluster(opts))
  def revision(opts \\ []), do: KV.revision(APIOptions.cluster(opts))
  def history(key, opts \\ []), do: KV.history(key, APIOptions.cluster(opts))
  def list(opts \\ []), do: KV.list(APIOptions.cluster(opts))
  def put(key, value, opts \\ []), do: KV.put(key, value, APIOptions.cluster(opts))
  def delete(key, opts \\ []), do: KV.delete(key, APIOptions.cluster(opts))
  def create(key, value, opts \\ []), do: KV.create(key, value, APIOptions.cluster(opts))

  def replace(key, value, opts \\ []),
    do: KV.replace(key, value, APIOptions.cluster(opts))

  def update_if(key, value, opts \\ []),
    do: KV.update_if(key, value, APIOptions.cluster(opts))

  def delete_if(key, opts \\ []), do: KV.delete_if(key, APIOptions.cluster(opts))
end
