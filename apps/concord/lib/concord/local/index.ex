defmodule Concord.Local.Index do
  @moduledoc "Node-local `Concord.Index` API."

  alias Concord.{APIOptions, Index}

  def create(name, extractor, opts \\ []) do
    Index.create(name, extractor, APIOptions.local(opts))
  end

  def drop(name, opts \\ []), do: Index.drop(name, APIOptions.local(opts))

  def lookup(name, value, opts \\ []),
    do: Index.lookup(name, value, APIOptions.local(opts))

  def list(opts \\ []), do: Index.list(APIOptions.local(opts))
  def reindex(name, opts \\ []), do: Index.reindex(name, APIOptions.local(opts))
end
