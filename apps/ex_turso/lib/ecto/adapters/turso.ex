if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Ecto.Adapters.Turso do
    @moduledoc """
    Optional Ecto SQL adapter for Turso.

    This adapter is compiled only when `ecto_sql` is available. It uses
    `Turso.Connection` for DBConnection pooling and Turso native execution,
    while rendering SQL with Turso's SQLite-compatible dialect.

    Configure a repo with:

        config :my_app, MyApp.Repo,
          database: "my_app.db",
          pool_size: 5

    `:database`, `:remote_url`, and `:auth_token` are forwarded to Turso.
    `:memory` and `":memory:"` open an in-memory database; use `pool_size: 1`
    when using an in-memory repo so all operations share the same handle.

    The adapter supports normal schema and query operations plus `ecto_sql`
    migrations. Streams and multi-result queries are not supported by the
    current native connection.
    """

    use Ecto.Adapters.SQL,
      driver: :ex_turso

    @behaviour Ecto.Adapter.Storage
    @behaviour Ecto.Adapter.Structure

    alias Ecto.Adapters.Turso.Codec

    @impl Ecto.Adapter.Storage
    def storage_down(options) do
      db_path = options |> Keyword.fetch!(:database) |> normalize_database()

      case File.rm(db_path) do
        :ok ->
          File.rm(db_path <> "-shm")
          File.rm(db_path <> "-wal")
          :ok

        _otherwise ->
          {:error, :already_down}
      end
    end

    @impl Ecto.Adapter.Storage
    def storage_status(options) do
      db_path = options |> Keyword.fetch!(:database) |> normalize_database()

      if File.exists?(db_path) do
        :up
      else
        :down
      end
    end

    @impl Ecto.Adapter.Storage
    def storage_up(options) do
      database = options |> Keyword.get(:database) |> normalize_database()
      options = Keyword.put(options, :database, database)
      pool_size = Keyword.get(options, :pool_size)

      cond do
        is_nil(database) ->
          raise ArgumentError,
                """
                No Turso database path specified. Please check the configuration for your Repo.
                Your config/*.exs file should have something like this in it:

                  config :my_app, MyApp.Repo,
                    adapter: Ecto.Adapters.Turso,
                    database: "/path/to/sqlite/database"
                """

        File.exists?(database) ->
          {:error, :already_up}

        database == ":memory:" && pool_size != 1 ->
          raise ArgumentError, """
          In memory databases must have a pool_size of 1
          """

        true ->
          {:ok, state} = Turso.Connection.connect(options)
          :ok = Turso.Connection.disconnect(:normal, state)
      end
    end

    defp normalize_database(:memory), do: ":memory:"
    defp normalize_database(database), do: database

    @impl Ecto.Adapter.Migration
    def supports_ddl_transaction?, do: true

    @impl Ecto.Adapter.Migration
    def lock_for_migrations(_meta, _options, fun) do
      fun.()
    end

    @impl Ecto.Adapter.Structure
    def structure_dump(default, config) do
      path = config[:dump_path] || Path.join(default, "structure.sql")

      with {:ok, contents} <- dump_schema(config),
           {:ok, versions} <- dump_versions(config) do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, contents <> versions)
        {:ok, path}
      else
        err -> err
      end
    end

    @impl Ecto.Adapter.Structure
    def structure_load(default, config) do
      path = config[:dump_path] || Path.join(default, "structure.sql")

      case run_with_cmd("sqlite3", [config[:database], ".read #{path}"]) do
        {_output, 0} -> {:ok, path}
        {output, _} -> {:error, output}
      end
    end

    @impl Ecto.Adapter.Structure
    def dump_cmd(args, opts \\ [], config) when is_list(config) and is_list(args) do
      run_with_cmd("sqlite3", ["-init", "/dev/null", config[:database] | args], opts)
    end

    @impl Ecto.Adapter.Schema
    def autogenerate(:id), do: nil
    def autogenerate(:embed_id), do: Ecto.UUID.generate()

    def autogenerate(:binary_id) do
      case Application.get_env(:ex_turso, :binary_id_type, :string) do
        :string -> Ecto.UUID.generate()
        :binary -> Ecto.UUID.bingenerate()
      end
    end

    ##
    ## Loaders
    ##

    @default_datetime_type :iso8601

    @impl Ecto.Adapter
    def loaders(:boolean, type) do
      [&Codec.bool_decode/1, type]
    end

    @impl Ecto.Adapter
    def loaders(:naive_datetime_usec, type) do
      [&Codec.naive_datetime_decode/1, type]
    end

    @impl Ecto.Adapter
    def loaders(:time, type) do
      [&Codec.time_decode/1, type]
    end

    @impl Ecto.Adapter
    def loaders(:utc_datetime_usec, type) do
      [&Codec.utc_datetime_decode/1, type]
    end

    @impl Ecto.Adapter
    def loaders(:utc_datetime, type) do
      [&Codec.utc_datetime_decode/1, type]
    end

    @impl Ecto.Adapter
    def loaders(:naive_datetime, type) do
      [&Codec.naive_datetime_decode/1, type]
    end

    @impl Ecto.Adapter
    def loaders(:date, type) do
      [&Codec.date_decode/1, type]
    end

    @impl Ecto.Adapter
    def loaders({:map, _}, type) do
      [&Codec.json_decode/1, &Ecto.Type.embedded_load(type, &1, :json)]
    end

    @impl Ecto.Adapter
    def loaders({:array, _}, type) do
      [&Codec.json_decode/1, type]
    end

    @impl Ecto.Adapter
    def loaders(:map, type) do
      [&Codec.json_decode/1, type]
    end

    @impl Ecto.Adapter
    def loaders(:float, type) do
      [&Codec.float_decode/1, type]
    end

    @impl Ecto.Adapter
    def loaders(:decimal, type) do
      [&Codec.decimal_decode/1, type]
    end

    @impl Ecto.Adapter
    def loaders(:binary_id, type) do
      case Application.get_env(:ex_turso, :binary_id_type, :string) do
        :string -> [type]
        :binary -> [Ecto.UUID, type]
      end
    end

    @impl Ecto.Adapter
    def loaders(:uuid, type) do
      case Application.get_env(:ex_turso, :uuid_type, :string) do
        :string -> []
        :binary -> [type]
      end
    end

    @impl Ecto.Adapter
    def loaders(primitive_type, ecto_type) do
      loader_from_extension(primitive_type, ecto_type)
    end

    ##
    ## Dumpers
    ##

    @impl Ecto.Adapter
    def dumpers(:binary, type) do
      [type, &Codec.blob_encode/1]
    end

    @impl Ecto.Adapter
    def dumpers(:boolean, type) do
      [type, &Codec.bool_encode/1]
    end

    @impl Ecto.Adapter
    def dumpers(:decimal, type) do
      [type, &Codec.decimal_encode/1]
    end

    @impl Ecto.Adapter
    def dumpers(:binary_id, type) do
      case Application.get_env(:ex_turso, :binary_id_type, :string) do
        :string -> [type]
        :binary -> [type, Ecto.UUID]
      end
    end

    @impl Ecto.Adapter
    def dumpers(:uuid, type) do
      case Application.get_env(:ex_turso, :uuid_type, :string) do
        :string -> []
        :binary -> [type]
      end
    end

    @impl Ecto.Adapter
    def dumpers(:time, type) do
      [type, &Codec.time_encode/1]
    end

    @impl Ecto.Adapter
    def dumpers(:time_usec, type) do
      [type, &Codec.time_encode/1]
    end

    @impl Ecto.Adapter
    def dumpers(:date, type) do
      [type, &Codec.date_encode/1]
    end

    @impl Ecto.Adapter
    def dumpers(:utc_datetime, type) do
      dt_type = Application.get_env(:ex_turso, :datetime_type, @default_datetime_type)
      [type, &Codec.utc_datetime_encode(&1, dt_type)]
    end

    @impl Ecto.Adapter
    def dumpers(:utc_datetime_usec, type) do
      dt_type = Application.get_env(:ex_turso, :datetime_type, @default_datetime_type)
      [type, &Codec.utc_datetime_encode(&1, dt_type)]
    end

    @impl Ecto.Adapter
    def dumpers(:naive_datetime, type) do
      dt_type = Application.get_env(:ex_turso, :datetime_type, @default_datetime_type)
      [type, &Codec.naive_datetime_encode(&1, dt_type)]
    end

    @impl Ecto.Adapter
    def dumpers(:naive_datetime_usec, type) do
      dt_type = Application.get_env(:ex_turso, :datetime_type, @default_datetime_type)
      [type, &Codec.naive_datetime_encode(&1, dt_type)]
    end

    @impl Ecto.Adapter
    def dumpers({:array, _}, type) do
      [type, &Codec.json_encode/1]
    end

    @impl Ecto.Adapter
    def dumpers({:map, _}, type) do
      [&Ecto.Type.embedded_dump(type, &1, :json), &Codec.json_encode/1]
    end

    @impl Ecto.Adapter
    def dumpers(:map, type) do
      [type, &Codec.json_encode/1]
    end

    @impl Ecto.Adapter
    def dumpers(primitive_type, ecto_type) do
      dumper_from_extension(primitive_type, ecto_type)
    end

    ##
    ## HELPERS
    ##

    defp dump_versions(config) do
      table = config[:migration_source] || "schema_migrations"

      # `.dump` command also returns CREATE TABLE which will clash with CREATE we already run in dump_schema
      # So we set mode to insert which makes every SELECT statement to issue the result
      # as the INSERT statements instead of pure text data.
      case run_with_cmd("sqlite3", [
             config[:database],
             ".mode insert #{table}",
             "SELECT * FROM #{table}"
           ]) do
        {output, 0} -> {:ok, output}
        {output, _} -> {:error, output}
      end
    end

    defp dump_schema(config) do
      case run_with_cmd("sqlite3", [config[:database], ".schema"]) do
        {output, 0} -> {:ok, output}
        {output, _} -> {:error, output}
      end
    end

    defp run_with_cmd(cmd, args, cmd_opts \\ []) do
      unless System.find_executable(cmd) do
        raise "could not find executable `#{cmd}` in path, " <>
                "please guarantee it is available before running ecto commands"
      end

      cmd_opts = Keyword.put_new(cmd_opts, :stderr_to_stdout, true)

      System.cmd(cmd, args, cmd_opts)
    end

    defp extensions do
      Application.get_env(:ex_turso, :type_extensions, [])
    end

    defp loader_from_extension(primitive_type, ecto_type) do
      loader_from_extension(extensions(), primitive_type, ecto_type)
    end

    defp loader_from_extension([], _primitive_type, ecto_type), do: [ecto_type]

    defp loader_from_extension([extension | other_extensions], primitive_type, ecto_type) do
      case extension.loaders(primitive_type, ecto_type) do
        nil -> loader_from_extension(other_extensions, primitive_type, ecto_type)
        loader -> loader
      end
    end

    defp dumper_from_extension(primitive_type, ecto_type) do
      dumper_from_extension(extensions(), primitive_type, ecto_type)
    end

    defp dumper_from_extension([], _primitive_type, ecto_type), do: [ecto_type]

    defp dumper_from_extension([extension | other_extensions], primitive_type, ecto_type) do
      case extension.dumpers(primitive_type, ecto_type) do
        nil -> dumper_from_extension(other_extensions, primitive_type, ecto_type)
        dumper -> dumper
      end
    end
  end
end
