defmodule Concord.Engine.VSR.Supervisor do
  @moduledoc false

  use Supervisor

  alias Concord.Engine.VSR
  alias ViewstampedReplication.{Client, Configuration, Member, ReplicaSupervisor}
  alias ViewstampedReplication.Storage
  alias ViewstampedReplication.Transport

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(overrides) do
    opts =
      :concord
      |> Application.get_env(:vsr, [])
      |> Keyword.merge(overrides)

    configuration = configuration(opts)
    storage = storage(opts, configuration)

    replica_opts = [
      configuration: configuration,
      state_machine: VSR.StateMachine,
      state_machine_opts: Keyword.get(opts, :state_machine_opts, []),
      transport: transport(opts),
      storage: storage,
      bootstrap: Keyword.get(opts, :bootstrap, false)
    ]

    client_opts = [
      name: VSR.Client,
      group_id: configuration.group_id,
      client_id: Keyword.get_lazy(opts, :client_id, &default_client_id/0),
      replicas: Enum.map(configuration.members, & &1.id),
      retry_timeout: Keyword.get(opts, :retry_timeout, 100)
    ]

    children = [
      {ReplicaSupervisor, replica_opts},
      {Client, client_opts},
      {VSR, configuration: configuration}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp configuration(opts) do
    members =
      opts
      |> Keyword.get(:members, [])
      |> Enum.map(&member/1)

    if members == [] do
      raise ArgumentError,
            "VSR requires an explicit ordered :members configuration with 1, 3, or 5 members"
    end

    Configuration.new!(
      group_id:
        Keyword.get(
          opts,
          :group_id,
          Application.get_env(:concord, :cluster_name, :concord_cluster)
        ),
      replica_id: Keyword.get(opts, :replica_id) || node(),
      members: members
    )
  end

  defp member(%Member{} = member), do: member
  defp member(member) when is_list(member), do: member |> Map.new() |> member()

  defp member(%{id: id, endpoint: endpoint}) do
    %Member{id: id, endpoint: endpoint}
  end

  defp storage(opts, configuration) do
    case Keyword.get(opts, :storage, :file) do
      :file ->
        {Storage.File,
         path:
           Keyword.get(opts, :storage_path) ||
             default_storage_path(configuration.replica_id)}

      :memory ->
        Storage.Memory

      {module, module_opts} when is_atom(module) and is_list(module_opts) ->
        {module, module_opts}

      module when is_atom(module) ->
        module
    end
  end

  defp transport(opts) do
    case Keyword.get(opts, :transport, :distribution) do
      :distribution -> Transport.Distribution
      :local -> Transport.Local
      {module, transport_state} when is_atom(module) -> {module, transport_state}
      module when is_atom(module) -> module
    end
  end

  defp default_storage_path(replica_id) do
    replica =
      replica_id
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9_.-]/, "_")

    :concord
    |> Application.get_env(:data_dir, "./data")
    |> Path.join("vsr")
    |> Path.join(replica)
  end

  defp default_client_id do
    {Concord.Engine.VSR, node(), System.unique_integer([:positive, :monotonic])}
  end
end
