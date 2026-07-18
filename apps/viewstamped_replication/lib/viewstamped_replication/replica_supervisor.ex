defmodule ViewstampedReplication.ReplicaSupervisor do
  @moduledoc false

  use Supervisor

  alias ViewstampedReplication.Configuration

  def start_link(opts) do
    configuration = Keyword.fetch!(opts, :configuration)

    Supervisor.start_link(
      __MODULE__,
      opts,
      name: via_tuple(configuration.group_id, configuration.replica_id)
    )
  end

  @impl true
  def init(opts) do
    Supervisor.init([{ViewstampedReplication.Replica, opts}], strategy: :one_for_one)
  end

  def child_spec(opts) do
    %Configuration{group_id: group_id, replica_id: replica_id} =
      Keyword.fetch!(opts, :configuration)

    %{
      id: {__MODULE__, group_id, replica_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :supervisor
    }
  end

  @spec whereis(term(), term()) :: pid() | nil
  def whereis(group_id, replica_id) do
    case Registry.lookup(
           ViewstampedReplication.Registry,
           {:replica_supervisor, group_id, replica_id}
         ) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp via_tuple(group_id, replica_id) do
    {:via, Registry,
     {ViewstampedReplication.Registry, {:replica_supervisor, group_id, replica_id}}}
  end
end
