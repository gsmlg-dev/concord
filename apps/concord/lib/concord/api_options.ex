defmodule Concord.APIOptions do
  @moduledoc false

  alias Concord.Engine
  alias Concord.Engine.{Local, Turso, VSR}

  def cluster(opts), do: Engine.with_engine(opts, VSR)
  def local(opts), do: Engine.with_engine(opts, Local)
  def turso(opts), do: Engine.with_engine(opts, Turso)
end
