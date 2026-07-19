import Config

# Read node name from environment variable for per-node data directories
node_name = System.get_env("NODE_NAME", "node")

# Data directory: only use /tmp for dev and test environments.
# Production must use a persistent directory.
data_dir =
  case config_env() do
    :prod ->
      System.get_env("CONCORD_DATA_DIR", "/var/lib/concord/data/#{node_name}")

    _dev_or_test ->
      Path.join(System.tmp_dir!(), "concord_data/#{node_name}")
  end

cluster_enabled =
  System.get_env("CONCORD_CLUSTER_ENABLED", "true")
  |> String.downcase()
  |> then(&(&1 in ["1", "true", "yes", "on"]))

vsr_group_id =
  System.get_env("CONCORD_VSR_GROUP_ID", "concord_cluster")
  |> String.to_atom()

vsr_replica_id =
  System.get_env("CONCORD_VSR_REPLICA_ID", Atom.to_string(node()))
  |> String.to_atom()

vsr_members =
  System.get_env("CONCORD_VSR_MEMBERS", "")
  |> String.split(",", trim: true)
  |> Enum.map(fn member ->
    case String.split(member, "=", parts: 2) do
      [id, endpoint] ->
        [id: String.to_atom(String.trim(id)), endpoint: String.to_atom(String.trim(endpoint))]

      [id_and_endpoint] ->
        id_and_endpoint = id_and_endpoint |> String.trim() |> String.to_atom()
        [id: id_and_endpoint, endpoint: id_and_endpoint]
    end
  end)
  |> case do
    [] -> [[id: vsr_replica_id, endpoint: node()]]
    members -> members
  end

vsr_transport =
  case System.get_env("CONCORD_VSR_TRANSPORT", "distribution") |> String.downcase() do
    "distribution" -> :distribution
    "local" -> :local
    value -> raise "invalid CONCORD_VSR_TRANSPORT=#{inspect(value)}"
  end

vsr_storage =
  case System.get_env("CONCORD_VSR_STORAGE", "file") |> String.downcase() do
    "file" -> :file
    "memory" -> :memory
    value -> raise "invalid CONCORD_VSR_STORAGE=#{inspect(value)}"
  end

vsr_bootstrap =
  System.get_env("CONCORD_VSR_BOOTSTRAP", "false")
  |> String.downcase()
  |> then(&(&1 in ["1", "true", "yes", "on"]))

config :concord,
  cluster_name: :concord_cluster,
  cluster_enabled: cluster_enabled,
  vsr: [
    group_id: vsr_group_id,
    replica_id: vsr_replica_id,
    members: vsr_members,
    transport: vsr_transport,
    storage: vsr_storage,
    storage_path:
      System.get_env(
        "CONCORD_VSR_STORAGE_PATH",
        Path.join([data_dir, "vsr", Atom.to_string(vsr_replica_id)])
      ),
    bootstrap: vsr_bootstrap,
    retry_timeout: String.to_integer(System.get_env("CONCORD_VSR_RETRY_TIMEOUT", "100"))
  ],
  data_dir: data_dir

turso_enabled =
  System.get_env("CONCORD_TURSO_ENABLED", "false")
  |> String.downcase()
  |> then(&(&1 in ["1", "true", "yes", "on"]))

turso_auth_token =
  case System.get_env("CONCORD_TURSO_AUTH_TOKEN") || System.get_env("TURSO_AUTH_TOKEN") do
    nil ->
      nil

    "" ->
      nil

    _token ->
      fn ->
        System.get_env("CONCORD_TURSO_AUTH_TOKEN") || System.fetch_env!("TURSO_AUTH_TOKEN")
      end
  end

turso_pool_size =
  System.get_env("CONCORD_TURSO_POOL_SIZE", "1")
  |> String.to_integer()

config :concord,
  turso: [
    enabled: turso_enabled,
    database: System.get_env("CONCORD_TURSO_DATABASE", Path.join(data_dir, "turso.db")),
    pool_size: turso_pool_size,
    remote_url:
      System.get_env("CONCORD_TURSO_REMOTE_URL") || System.get_env("TURSO_DATABASE_URL"),
    auth_token: turso_auth_token
  ]
