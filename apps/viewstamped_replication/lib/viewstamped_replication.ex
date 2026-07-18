defmodule ViewstampedReplication do
  @moduledoc """
  Protocol-generic Viewstamped Replication runtime.
  """

  alias ViewstampedReplication.{Client, Configuration, Replica, ReplicaSupervisor}

  @spec start_replica(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_replica(opts) do
    with {:ok, configuration} <- configuration(opts),
         child_opts <- Keyword.put(opts, :configuration, configuration),
         {:ok, _supervisor} <-
           DynamicSupervisor.start_child(
             ViewstampedReplication.ReplicaDynamicSupervisor,
             {ReplicaSupervisor, child_opts}
           ),
         pid when is_pid(pid) <- Replica.whereis(configuration.group_id, configuration.replica_id) do
      {:ok, pid}
    else
      {:error, {:already_started, _supervisor}} -> {:error, :already_started}
      {:error, _reason} = error -> error
      nil -> {:error, :replica_start_failed}
    end
  end

  @spec stop_replica(term(), term()) :: :ok | {:error, :not_found}
  def stop_replica(group_id, replica_id) do
    case ReplicaSupervisor.whereis(group_id, replica_id) do
      nil ->
        {:error, :not_found}

      supervisor ->
        DynamicSupervisor.terminate_child(
          ViewstampedReplication.ReplicaDynamicSupervisor,
          supervisor
        )
    end
  end

  @spec status(term(), term()) :: {:ok, map()} | {:error, :not_found}
  def status(group_id, replica_id), do: Replica.status(group_id, replica_id)

  @spec primary(term(), term()) :: {:ok, term()} | {:error, :not_found}
  def primary(group_id, replica_id), do: Replica.primary(group_id, replica_id)

  @spec snapshot(term(), term()) :: :ok | {:error, term()}
  def snapshot(group_id, replica_id), do: Replica.snapshot(group_id, replica_id)

  @spec command(term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def command(group_id, operation, opts) do
    with {:ok, client} <- Keyword.fetch(opts, :client) do
      Client.command(
        client,
        operation,
        group_id: group_id,
        timeout: Keyword.get(opts, :timeout, 5_000)
      )
    else
      :error -> {:error, :client_required}
    end
  end

  defp configuration(opts) do
    case Keyword.fetch(opts, :configuration) do
      {:ok, %Configuration{} = configuration} -> Configuration.validate(configuration)
      {:ok, attributes} -> Configuration.new(attributes)
      :error -> Configuration.new(Map.new(Keyword.take(opts, [:group_id, :replica_id, :members])))
    end
  end
end
