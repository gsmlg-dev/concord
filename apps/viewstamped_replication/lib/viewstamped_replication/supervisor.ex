defmodule ViewstampedReplication.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    children = [
      {Registry, keys: :unique, name: ViewstampedReplication.Registry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: ViewstampedReplication.ReplicaDynamicSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
