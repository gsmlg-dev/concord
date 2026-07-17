defmodule Concord.Local.Txn do
  @moduledoc "Node-local `Concord.Txn` API."

  alias Concord.{APIOptions, Txn}

  def commit(spec, opts \\ []), do: Txn.commit(spec, APIOptions.local(opts))
end
