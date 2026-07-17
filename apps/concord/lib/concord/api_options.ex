defmodule Concord.APIOptions do
  @moduledoc false

  alias Concord.Engine
  alias Concord.Engine.{Cluster, Local, Turso}

  def cluster(opts), do: Engine.with_engine(opts, Cluster)
  def local(opts), do: Engine.with_engine(opts, Local)
  def turso(opts), do: Engine.with_engine(opts, Turso)
end
