defmodule Concord.Cluster.Index do
  @moduledoc "Explicit VSR-cluster `Concord.Index` API."

  alias Concord.{APIOptions, Index}

  def create(name, extractor, opts \\ []) do
    Index.create(name, extractor, APIOptions.cluster(opts))
  end

  def drop(name, opts \\ []), do: Index.drop(name, APIOptions.cluster(opts))

  def lookup(name, value, opts \\ []),
    do: Index.lookup(name, value, APIOptions.cluster(opts))

  def list(opts \\ []), do: Index.list(APIOptions.cluster(opts))
  def reindex(name, opts \\ []), do: Index.reindex(name, APIOptions.cluster(opts))
end
