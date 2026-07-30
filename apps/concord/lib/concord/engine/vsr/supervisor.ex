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
      replicas: configuration.members,
      retry_timeout: Keyword.get(opts, :retry_timeout, 100)
    ]

    client_opts =
      case Keyword.fetch(opts, :client_id) do
        {:ok, client_id_base} -> Keyword.put(client_opts, :client_id_base, client_id_base)
        :error -> client_opts
      end

    children = [
      {ReplicaSupervisor, replica_opts},
      client_child_spec(client_opts),
      {VSR,
       configuration: configuration,
       command_version: Keyword.get(opts, :command_version, 0),
       wal_version: Keyword.get(opts, :wal_version, 1)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  @spec start_client(keyword()) :: GenServer.on_start()
  def start_client(opts) do
    client_id_base = Keyword.get(opts, :client_id_base, Concord.Engine.VSR)
    client_id = {client_id_base, client_incarnation()}

    opts
    |> Keyword.delete(:client_id_base)
    |> Keyword.put(:client_id, client_id)
    |> Client.start_link()
  end

  defp configuration(opts) do
    members =
      opts
      |> Keyword.get(:members, [])
      |> Enum.map(&member/1)

    if members == [] do
      raise ArgumentError,
            "VSR requires an explicit ordered :members configuration with 1 to 6 members"
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
             default_storage_path(configuration.replica_id),
         write_version: Keyword.get(opts, :wal_version, 1)}

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

  defp client_child_spec(client_opts) do
    {Client, client_opts}
    |> Supervisor.child_spec([])
    |> Map.put(:start, {__MODULE__, :start_client, [client_opts]})
  end

  defp client_incarnation, do: :crypto.strong_rand_bytes(16)
end
