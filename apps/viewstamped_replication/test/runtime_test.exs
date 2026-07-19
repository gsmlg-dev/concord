defmodule ViewstampedReplication.RuntimeTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Client, Configuration, Member}

  setup context do
    on_exit(fn ->
      if tmp_dir = context[:tmp_dir], do: cleanup_tmp_dir(tmp_dir)
    end)

    :ok
  end

  defmodule MapStateMachine do
    @behaviour ViewstampedReplication.StateMachine

    @impl true
    def init(_opts), do: %{}

    @impl true
    def apply(_metadata, {:put, key, value}, state), do: {:ok, Map.put(state, key, value)}

    def apply(_metadata, {:get, key}, state), do: {Map.fetch(state, key), state}

    @impl true
    def snapshot(state), do: {:ok, state}

    @impl true
    def restore(snapshot) when is_map(snapshot), do: {:ok, snapshot}
    def restore(snapshot), do: {:error, {:invalid_snapshot, snapshot}}
  end

  test "public API starts, reports, and stops an independent replica" do
    group_id = unique_group()
    configuration = configuration(group_id)

    assert {:ok, pid} =
             ViewstampedReplication.start_replica(
               configuration: configuration,
               state_machine: MapStateMachine,
               bootstrap: true
             )

    assert Process.alive?(pid)

    assert {:ok,
            %{
              group_id: ^group_id,
              replica_id: 1,
              status: :normal,
              view_number: 0,
              primary_id: 1,
              configuration_hash: configuration_hash
            }} = ViewstampedReplication.status(group_id, 1)

    assert configuration_hash == Configuration.hash(configuration)
    assert {:ok, 1} = ViewstampedReplication.primary(group_id, 1)
    assert :ok = ViewstampedReplication.stop_replica(group_id, 1)
    assert {:error, :not_found} = ViewstampedReplication.status(group_id, 1)
  end

  test "client session submits a command and advances its stable request number" do
    group_id = unique_group()
    configuration = configuration(group_id)

    start_supervised!(
      {ViewstampedReplication.ReplicaSupervisor,
       configuration: configuration, state_machine: MapStateMachine, bootstrap: true}
    )

    client =
      start_supervised!(
        {Client,
         group_id: group_id,
         client_id: {:client, group_id},
         replicas: configuration.members,
         retry_timeout: 20}
      )

    assert {:ok, :ok} =
             ViewstampedReplication.command(group_id, {:put, :key, :value},
               client: client,
               timeout: 1_000
             )

    assert %{request_number: 1, command_in_progress?: false, believed_primary: {^group_id, 1}} =
             Client.status(client)
  end

  test "multiple independent groups run in one VM without sharing state" do
    first_group = unique_group()
    second_group = unique_group()

    for group_id <- [first_group, second_group] do
      assert {:ok, _pid} =
               ViewstampedReplication.start_replica(
                 configuration: configuration(group_id),
                 state_machine: MapStateMachine,
                 bootstrap: true
               )

      on_exit(fn -> ViewstampedReplication.stop_replica(group_id, 1) end)
    end

    first_client = start_client(first_group, {:client, first_group})
    second_client = start_client(second_group, {:client, second_group})

    assert {:ok, :ok} =
             ViewstampedReplication.command(first_group, {:put, :shared_key, :first},
               client: first_client
             )

    assert {:ok, :ok} =
             ViewstampedReplication.command(second_group, {:put, :shared_key, :second},
               client: second_client
             )

    assert {:ok, {:ok, :first}} =
             ViewstampedReplication.command(first_group, {:get, :shared_key},
               client: first_client
             )

    assert {:ok, {:ok, :second}} =
             ViewstampedReplication.command(second_group, {:get, :shared_key},
               client: second_client
             )

    assert {:ok, %{group_id: ^first_group, op_number: 2}} =
             ViewstampedReplication.status(first_group, 1)

    assert {:ok, %{group_id: ^second_group, op_number: 2}} =
             ViewstampedReplication.status(second_group, 1)
  end

  test "three local replicas commit, then continue with one backup stopped" do
    group_id = unique_group()
    members = members(group_id, 3)

    for replica_id <- [1, 2, 3] do
      configuration =
        Configuration.new!(
          group_id: group_id,
          replica_id: replica_id,
          members: members
        )

      assert {:ok, _pid} =
               ViewstampedReplication.start_replica(
                 configuration: configuration,
                 state_machine: MapStateMachine,
                 bootstrap: true
               )

      on_exit(fn ->
        ViewstampedReplication.stop_replica(group_id, replica_id)
      end)
    end

    client =
      start_supervised!(
        {Client,
         group_id: group_id,
         client_id: {:client, group_id},
         replicas: [1, 2, 3],
         primary: 2,
         retry_timeout: 20}
      )

    assert {:ok, :ok} =
             ViewstampedReplication.command(group_id, {:put, :available, true},
               client: client,
               timeout: 1_000
             )

    assert {:ok, %{commit_number: 1, applied_number: 1}} =
             ViewstampedReplication.status(group_id, 1)

    assert {:ok, %{commit_number: 1, applied_number: 1}} =
             ViewstampedReplication.status(group_id, 2)

    assert :ok = ViewstampedReplication.stop_replica(group_id, 3)

    assert {:ok, :ok} =
             ViewstampedReplication.command(group_id, {:put, :still_available, true},
               client: client,
               timeout: 1_000
             )

    assert {:ok, %{commit_number: 2, applied_number: 2}} =
             ViewstampedReplication.status(group_id, 1)

    assert {:ok, %{commit_number: 2, applied_number: 2}} =
             ViewstampedReplication.status(group_id, 2)
  end

  test "a primary does not report success without a quorum" do
    group_id = unique_group()

    start_supervised!(
      {ViewstampedReplication.ReplicaSupervisor,
       configuration:
         Configuration.new!(
           group_id: group_id,
           replica_id: 1,
           members: members(group_id, 3)
         ),
       state_machine: MapStateMachine,
       bootstrap: true}
    )

    client =
      start_supervised!(
        {Client,
         group_id: group_id,
         client_id: {:client, group_id},
         replicas: [1, 2, 3],
         retry_timeout: 20}
      )

    assert {:error, :quorum_unavailable} =
             ViewstampedReplication.command(group_id, {:put, :uncommitted, true},
               client: client,
               timeout: 100
             )

    assert {:ok, %{op_number: 1, commit_number: 0, applied_number: 0}} =
             ViewstampedReplication.status(group_id, 1)
  end

  @tag :tmp_dir
  test "file-backed replica replays committed operations without a snapshot", %{tmp_dir: tmp_dir} do
    group_id = unique_group()
    configuration = configuration(group_id)
    storage = {ViewstampedReplication.Storage.File, path: tmp_dir}

    assert {:ok, _pid} = start_file_replica(configuration, storage, true)
    writer = start_client(group_id, {:writer, group_id})

    assert {:ok, :ok} =
             ViewstampedReplication.command(group_id, {:put, :durable, :value},
               client: writer,
               timeout: 1_000
             )

    assert {:ok, %{applied_number: 1}} = ViewstampedReplication.status(group_id, 1)
    assert :ok = ViewstampedReplication.stop_replica(group_id, 1)
    assert {:ok, _pid} = start_file_replica(configuration, storage, false)
    reader = start_client(group_id, {:reader, group_id})

    assert {:ok, {:ok, :value}} =
             ViewstampedReplication.command(group_id, {:get, :durable},
               client: reader,
               timeout: 1_000
             )

    assert {:ok, %{status: :normal, applied_number: 2}} =
             ViewstampedReplication.status(group_id, 1)

    assert :ok = ViewstampedReplication.stop_replica(group_id, 1)
  end

  @tag :tmp_dir
  test "file-backed replica restores a checkpoint before replaying its suffix", %{
    tmp_dir: tmp_dir
  } do
    group_id = unique_group()
    configuration = configuration(group_id)
    storage = {ViewstampedReplication.Storage.File, path: tmp_dir}

    assert {:ok, _pid} = start_file_replica(configuration, storage, true)
    writer = start_client(group_id, {:writer, group_id})

    assert {:ok, :ok} =
             ViewstampedReplication.command(group_id, {:put, :checkpointed, :value},
               client: writer,
               timeout: 1_000
             )

    assert :ok = ViewstampedReplication.snapshot(group_id, 1)
    assert :ok = ViewstampedReplication.stop_replica(group_id, 1)
    assert {:ok, _pid} = start_file_replica(configuration, storage, false)
    reader = start_client(group_id, {:reader, group_id})

    assert {:ok, {:ok, :value}} =
             ViewstampedReplication.command(group_id, {:get, :checkpointed},
               client: reader,
               timeout: 1_000
             )

    assert :ok = ViewstampedReplication.stop_replica(group_id, 1)
  end

  @tag :tmp_dir
  test "file-backed three-replica group survives a whole-cluster restart", %{tmp_dir: tmp_dir} do
    group_id = unique_group()
    members = members(group_id, 3)

    configurations =
      Map.new(1..3, fn replica_id ->
        {replica_id,
         Configuration.new!(
           group_id: group_id,
           replica_id: replica_id,
           members: members
         )}
      end)

    for replica_id <- 1..3 do
      storage =
        {ViewstampedReplication.Storage.File,
         path: Path.join(tmp_dir, Integer.to_string(replica_id))}

      assert {:ok, _pid} =
               start_file_replica(Map.fetch!(configurations, replica_id), storage, true)
    end

    on_exit(fn ->
      for replica_id <- 1..3 do
        ViewstampedReplication.stop_replica(group_id, replica_id)
      end
    end)

    client = start_client(group_id, {:durable_client, group_id}, [1, 2, 3])

    assert {:ok, :ok} =
             ViewstampedReplication.command(group_id, {:put, :whole_cluster, :value},
               client: client,
               timeout: 1_000
             )

    for replica_id <- 1..3 do
      assert :ok = ViewstampedReplication.snapshot(group_id, replica_id)
      assert :ok = ViewstampedReplication.stop_replica(group_id, replica_id)

      storage_opts = [
        path: Path.join(tmp_dir, Integer.to_string(replica_id)),
        configuration_hash: Configuration.hash(Map.fetch!(configurations, replica_id)),
        replica_id: replica_id
      ]

      assert {:ok, storage_state} = ViewstampedReplication.Storage.File.open(storage_opts)

      assert {:ok, %{hard_state: %{status: :normal}}, _storage_state} =
               ViewstampedReplication.Storage.File.recover(storage_state)
    end

    for replica_id <- 1..3 do
      storage =
        {ViewstampedReplication.Storage.File,
         path: Path.join(tmp_dir, Integer.to_string(replica_id))}

      assert {:ok, _pid} =
               start_file_replica(Map.fetch!(configurations, replica_id), storage, false)
    end

    for replica_id <- 1..3 do
      assert {:ok, %{status: :normal, commit_number: 1, applied_number: 1}} =
               ViewstampedReplication.status(group_id, replica_id)
    end

    assert {:ok, {:ok, :value}} =
             ViewstampedReplication.command(group_id, {:get, :whole_cluster},
               client: client,
               timeout: 1_000
             )

    for replica_id <- 1..3 do
      assert {:ok, %{commit_number: 2, applied_number: 2}} =
               ViewstampedReplication.status(group_id, replica_id)
    end
  end

  defp configuration(group_id) do
    Configuration.new!(
      group_id: group_id,
      replica_id: 1,
      members: [%Member{id: 1, endpoint: :local_endpoint}]
    )
  end

  defp members(group_id, count) do
    for replica_id <- 1..count do
      %Member{id: replica_id, endpoint: {:local, group_id, replica_id}}
    end
  end

  defp start_file_replica(configuration, storage, bootstrap) do
    ViewstampedReplication.start_replica(
      configuration: configuration,
      state_machine: MapStateMachine,
      storage: storage,
      bootstrap: bootstrap
    )
  end

  defp start_client(group_id, client_id, replicas \\ [1]) do
    start_supervised!(%{
      id: {Client, client_id},
      start:
        {Client, :start_link,
         [
           [
             group_id: group_id,
             client_id: client_id,
             replicas: replicas,
             retry_timeout: 20
           ]
         ]}
    })
  end

  defp cleanup_tmp_dir(tmp_dir) do
    File.rm_rf!(tmp_dir)
    File.rmdir(Path.dirname(tmp_dir))
    File.rmdir(Path.expand("tmp"))
    :ok
  end

  defp unique_group, do: {:runtime_test, System.unique_integer([:positive])}
end
