defmodule Concord.Cluster.Txn do
  @moduledoc "Explicit VSR-cluster `Concord.Txn` API."

  alias Concord.{APIOptions, Txn}

  def commit(spec, opts \\ []), do: Txn.commit(spec, APIOptions.cluster(opts))
end
