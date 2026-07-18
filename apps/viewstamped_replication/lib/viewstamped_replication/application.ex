defmodule ViewstampedReplication.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    ViewstampedReplication.Supervisor.start_link()
  end
end
