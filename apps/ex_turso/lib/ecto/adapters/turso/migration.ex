if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Ecto.Adapters.Turso.Migration do
    @moduledoc """
    Helpers for Turso schema changes that require rebuilding a table.

    `rebuild_table!/3` performs the safe create-copy-drop-rename sequence on
    one checked-out connection. The caller must provide the complete target
    `CREATE TABLE` statement and an explicit identifier-only copy mapping.

    Call it from `execute(fn -> ... end)` in explicit `up/0` and `down/0`
    migrations with `@disable_ddl_transaction true`.
    """

    alias Turso.Result

    @type sql_identifier :: atom() | String.t()
    @type copy_entry :: sql_identifier() | {sql_identifier(), sql_identifier()}
    @type object_kind :: :indexes | :triggers
    @type rebuild_options :: [
            create: (String.t() -> iodata()),
            copy: [copy_entry()],
            recreate: [object_kind()],
            validate: (term() -> :ok | {:error, term()})
          ]

    @doc """
    Atomically replaces a table using a complete target definition.

    The required `:create` function receives an already quoted temporary table
    identifier and must return one complete `CREATE TABLE` statement. The
    required `:copy` list accepts same-name columns or `{target, source}` pairs;
    raw expressions and backfills are intentionally not supported.

    Explicit indexes and attached triggers are recreated by default; pass a
    subset through `:recreate` to opt out deliberately. An optional `:validate`
    callback receives the checked-out transaction connection and must return
    `:ok` or `{:error, reason}`. Built-in foreign-key and integrity checks
    always run.

    The helper owns its checkout and transaction. It raises when called inside
    an existing transaction or checkout, so migrations must use explicit
    `up/0` and `down/0`, set `@disable_ddl_transaction true`, and invoke it from
    `execute(fn -> ... end)`.
    """
    @spec rebuild_table!(
            Ecto.Repo.t(),
            sql_identifier(),
            rebuild_options()
          ) :: :ok
    def rebuild_table!(repo, table, opts) when is_atom(repo) and is_list(opts) do
      {table, create, copy, recreate, validate, temporary_table} =
        normalize_arguments!(table, opts)

      assert_repo!(repo)
      assert_not_checked_out!(repo)

      repo
      |> connection_pool()
      |> DBConnection.run(
        fn conn ->
          assert_idle!(conn)
          create_sql = create_sql!(create, temporary_table)

          rebuild_on_connection!(
            conn,
            table,
            temporary_table,
            create_sql,
            copy,
            recreate,
            validate
          )
        end,
        timeout: :infinity
      )

      :ok
    end

    def rebuild_table!(_repo, _table, _opts) do
      raise ArgumentError,
            "rebuild_table!/3 expects a Repo module, an unqualified table name, and keyword options"
    end

    defp normalize_arguments!(table, opts) do
      unknown_options = Keyword.keys(opts) -- [:create, :copy, :recreate, :validate]

      if unknown_options != [] do
        raise ArgumentError, "unknown rebuild_table!/3 options: #{inspect(unknown_options)}"
      end

      table = normalize_identifier!(table, "table")
      create = fetch_option!(opts, :create)
      copy = opts |> fetch_option!(:copy) |> normalize_copy!()
      recreate = opts |> Keyword.get(:recreate, [:indexes, :triggers]) |> normalize_recreate!()
      validate = opts |> Keyword.get(:validate) |> normalize_validate!()

      unless is_function(create, 1) do
        raise ArgumentError, ":create must be a one-argument function"
      end

      temporary_table = "__ex_turso_rebuild_#{System.unique_integer([:positive, :monotonic])}"

      {table, create, copy, recreate, validate, temporary_table}
    end

    defp create_sql!(create, temporary_table) do
      create_sql = create.(quote_identifier(temporary_table))

      unless is_binary(create_sql) or is_list(create_sql) do
        raise ArgumentError, ":create must return SQL as a binary or iodata"
      end

      create_sql = IO.iodata_to_binary(create_sql)

      if String.trim(create_sql) == "" do
        raise ArgumentError, ":create must return a non-empty CREATE TABLE statement"
      end

      create_sql
    end

    defp fetch_option!(opts, key) do
      case Keyword.fetch(opts, key) do
        {:ok, value} -> value
        :error -> raise ArgumentError, "missing required :#{key} option"
      end
    end

    defp normalize_copy!(copy) when is_list(copy) and copy != [] do
      mapping =
        Enum.map(copy, fn
          identifier when is_atom(identifier) or is_binary(identifier) ->
            identifier = normalize_identifier!(identifier, "copy column")
            {identifier, identifier}

          {target, source} ->
            {
              normalize_identifier!(target, "copy target column"),
              normalize_identifier!(source, "copy source column")
            }

          entry ->
            raise ArgumentError,
                  "copy entries must be column names or {target, source} pairs, got: #{inspect(entry)}"
        end)

      duplicate_targets =
        mapping
        |> Enum.map(&elem(&1, 0))
        |> duplicate_values()

      if duplicate_targets != [] do
        raise ArgumentError, "duplicate target column in :copy: #{inspect(duplicate_targets)}"
      end

      mapping
    end

    defp normalize_copy!(_copy) do
      raise ArgumentError, ":copy must be a non-empty list of identifier mappings"
    end

    defp normalize_recreate!(recreate) when is_list(recreate) do
      recreate = Enum.uniq(recreate)
      unsupported = recreate -- [:indexes, :triggers]

      if unsupported != [] do
        raise ArgumentError, "unsupported :recreate entries: #{inspect(unsupported)}"
      end

      recreate
    end

    defp normalize_recreate!(_recreate) do
      raise ArgumentError, ":recreate must be a list containing :indexes and/or :triggers"
    end

    defp normalize_validate!(nil), do: nil
    defp normalize_validate!(validate) when is_function(validate, 1), do: validate

    defp normalize_validate!(_validate) do
      raise ArgumentError, ":validate must be a one-argument function"
    end

    defp duplicate_values(values) do
      values
      |> Enum.frequencies()
      |> Enum.filter(fn {_value, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
    end

    defp normalize_identifier!(identifier, description) when is_atom(identifier) do
      identifier |> Atom.to_string() |> normalize_identifier!(description)
    end

    defp normalize_identifier!(identifier, description) when is_binary(identifier) do
      cond do
        identifier == "" ->
          raise ArgumentError, "#{description} must not be empty"

        String.contains?(identifier, [".", <<0>>]) ->
          raise ArgumentError, "#{description} must be an unqualified SQL identifier"

        true ->
          identifier
      end
    end

    defp normalize_identifier!(identifier, description) do
      raise ArgumentError, "#{description} must be an atom or string, got: #{inspect(identifier)}"
    end

    defp assert_repo!(repo) do
      unless function_exported?(repo, :__adapter__, 0) and
               repo.__adapter__() == Ecto.Adapters.Turso do
        raise ArgumentError, "repo must use Ecto.Adapters.Turso"
      end
    end

    defp assert_not_checked_out!(repo) do
      if repo.checked_out?() or repo.in_transaction?() do
        raise_existing_transaction!()
      end
    end

    defp connection_pool(repo) do
      repo
      |> repo_metadata()
      |> resolve_pool()
    end

    defp repo_metadata(repo) do
      repo.get_dynamic_repo()
      |> Ecto.Adapter.lookup_meta()
    end

    defp resolve_pool(%{partition_supervisor: {name, _partitions}}) do
      {:via, PartitionSupervisor, {name, self()}}
    end

    defp resolve_pool(%{pid: pool}), do: pool

    defp assert_idle!(conn) do
      case DBConnection.status(conn) do
        :idle -> :ok
        :transaction -> raise_existing_transaction!()
      end
    end

    defp raise_existing_transaction! do
      raise Ecto.MigrationError, """
      Set @disable_ddl_transaction true and call
      Ecto.Adapters.Turso.Migration.rebuild_table!/3 from execute(fn -> ... end)
      outside an existing transaction or checkout.
      """
    end

    defp rebuild_on_connection!(
           conn,
           table,
           temporary_table,
           create_sql,
           copy,
           recreate,
           validate
         ) do
      original_foreign_keys = foreign_keys!(conn)

      try do
        set_foreign_keys!(conn, 0)

        case DBConnection.transaction(
               conn,
               fn transaction ->
                 rebuild_in_transaction!(
                   transaction,
                   table,
                   temporary_table,
                   create_sql,
                   copy,
                   recreate,
                   validate
                 )

                 :ok
               end,
               timeout: :infinity
             ) do
          {:ok, :ok} ->
            :ok

          {:error, reason} ->
            raise Ecto.MigrationError, "table rebuild rolled back: #{inspect(reason)}"
        end
      after
        set_foreign_keys!(conn, original_foreign_keys)
      end
    end

    defp rebuild_in_transaction!(
           conn,
           table,
           temporary_table,
           create_sql,
           copy,
           recreate,
           validate
         ) do
      table_sql = table_sql!(conn, table)
      reject_unsupported_table!(table, table_sql)
      ensure_name_available!(conn, temporary_table)

      original_columns = table_columns!(conn, table)
      reject_hidden_columns!(table, original_columns)
      schema_objects = schema_objects!(conn, table, recreate)
      sequence = sequence_value(conn, table)
      original_count = row_count!(conn, table)

      execute!(conn, create_sql)
      temporary_sql = table_sql!(conn, temporary_table)
      reject_unsupported_table!(temporary_table, temporary_sql)
      validate_autoincrement!(table_sql, temporary_sql)

      target_columns = table_columns!(conn, temporary_table)
      reject_hidden_columns!(temporary_table, target_columns)
      validate_copy!(copy, original_columns, target_columns)

      copy_rows!(conn, table, temporary_table, copy)

      if row_count!(conn, temporary_table) != original_count do
        raise Ecto.MigrationError, "table rebuild copied a different number of rows"
      end

      execute!(conn, ["DROP TABLE ", quote_identifier(table)])

      execute!(conn, [
        "ALTER TABLE ",
        quote_identifier(temporary_table),
        " RENAME TO ",
        quote_identifier(table)
      ])

      recreate_schema_objects!(conn, schema_objects)
      restore_sequence!(conn, table, temporary_table, sequence)
      run_custom_validation!(validate, conn)
      validate_database!(conn)
    end

    defp table_sql!(conn, table) do
      case query!(
             conn,
             "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?",
             [table]
           ).rows do
        [%{"sql" => sql}] when is_binary(sql) -> sql
        [] -> raise Ecto.MigrationError, "table #{inspect(table)} does not exist"
        _ -> raise Ecto.MigrationError, "could not read schema for table #{inspect(table)}"
      end
    end

    defp reject_unsupported_table!(table, table_sql) do
      cond do
        String.starts_with?(table, ["sqlite_", "__turso_internal_"]) ->
          raise Ecto.MigrationError, "internal table #{inspect(table)} cannot be rebuilt"

        table_sql
        |> String.trim_leading()
        |> String.upcase()
        |> String.starts_with?("CREATE VIRTUAL TABLE") ->
          raise Ecto.MigrationError, "virtual table #{inspect(table)} is not supported"

        true ->
          :ok
      end
    end

    defp ensure_name_available!(conn, name) do
      case query!(conn, "SELECT name FROM sqlite_schema WHERE name = ?", [name]).rows do
        [] -> :ok
        _ -> raise Ecto.MigrationError, "temporary table #{inspect(name)} already exists"
      end
    end

    defp table_columns!(conn, table) do
      conn
      |> query!(["PRAGMA table_xinfo(", quote_identifier(table), ")"])
      |> Map.fetch!(:rows)
    end

    defp reject_hidden_columns!(table, columns) do
      hidden = Enum.filter(columns, &(Map.get(&1, "hidden", 0) != 0))

      if hidden != [] do
        names = Enum.map(hidden, &Map.get(&1, "name"))

        raise Ecto.MigrationError,
              "table #{inspect(table)} has generated or hidden columns that are not supported: #{inspect(names)}"
      end
    end

    defp schema_objects!(conn, table, recreate) do
      types =
        Enum.map(recreate, fn
          :indexes -> "index"
          :triggers -> "trigger"
        end)

      conn
      |> query!(
        """
        SELECT type, name, sql
        FROM sqlite_schema
        WHERE tbl_name = ?
          AND type IN ('index', 'trigger')
          AND sql IS NOT NULL
        ORDER BY type, name
        """,
        [table]
      )
      |> Map.fetch!(:rows)
      |> Enum.filter(&(Map.fetch!(&1, "type") in types))
    end

    defp validate_autoincrement!(original_sql, target_sql) do
      unless autoincrement?(original_sql) == autoincrement?(target_sql) do
        raise Ecto.MigrationError,
              "target CREATE TABLE must preserve the original AUTOINCREMENT property"
      end
    end

    defp autoincrement?(sql), do: Regex.match?(~r/\bAUTOINCREMENT\b/i, sql)

    defp validate_copy!(copy, original_columns, target_columns) do
      original_names = MapSet.new(original_columns, &Map.fetch!(&1, "name"))
      target_names = MapSet.new(target_columns, &Map.fetch!(&1, "name"))

      Enum.each(copy, fn {target, source} ->
        unless MapSet.member?(original_names, source) do
          raise Ecto.MigrationError, "copy source column #{inspect(source)} does not exist"
        end

        unless MapSet.member?(target_names, target) do
          raise Ecto.MigrationError, "copy target column #{inspect(target)} does not exist"
        end
      end)

      original_primary_key = primary_key_columns(original_columns)
      target_primary_key = primary_key_columns(target_columns)
      mapping = Map.new(copy)
      mapped_primary_key = Enum.map(target_primary_key, &Map.get(mapping, &1))

      unless original_primary_key == mapped_primary_key do
        raise Ecto.MigrationError,
              "copy mapping must preserve primary key columns in order: #{inspect(original_primary_key)}"
      end
    end

    defp primary_key_columns(columns) do
      columns
      |> Enum.filter(&(Map.get(&1, "pk", 0) > 0))
      |> Enum.sort_by(&Map.fetch!(&1, "pk"))
      |> Enum.map(&Map.fetch!(&1, "name"))
    end

    defp copy_rows!(conn, table, temporary_table, copy) do
      target_columns = copy |> Enum.map(&elem(&1, 0)) |> quote_identifiers()
      source_columns = copy |> Enum.map(&elem(&1, 1)) |> quote_identifiers()

      execute!(conn, [
        "INSERT INTO ",
        quote_identifier(temporary_table),
        " (",
        target_columns,
        ") SELECT ",
        source_columns,
        " FROM ",
        quote_identifier(table)
      ])
    end

    defp quote_identifiers(identifiers) do
      Enum.map_join(identifiers, ", ", &quote_identifier/1)
    end

    defp row_count!(conn, table) do
      case query!(conn, ["SELECT COUNT(*) AS count FROM ", quote_identifier(table)]).rows do
        [%{"count" => count}] when is_integer(count) -> count
        _ -> raise Ecto.MigrationError, "could not count rows in table #{inspect(table)}"
      end
    end

    defp recreate_schema_objects!(conn, objects) do
      Enum.each(objects, fn %{"sql" => sql} -> execute!(conn, sql) end)
    end

    defp run_custom_validation!(nil, _conn), do: :ok

    defp run_custom_validation!(validate, conn) do
      case validate.(conn) do
        :ok ->
          :ok

        {:error, reason} ->
          raise Ecto.MigrationError, "custom validation failed: #{inspect(reason)}"

        result ->
          raise Ecto.MigrationError, "custom validation returned: #{inspect(result)}"
      end
    end

    defp sequence_value(conn, table) do
      if sqlite_sequence_exists?(conn) do
        case query!(conn, "SELECT seq FROM sqlite_sequence WHERE name = ?", [table]).rows do
          [%{"seq" => sequence}] when is_integer(sequence) -> sequence
          [] -> nil
          _ -> raise Ecto.MigrationError, "could not read AUTOINCREMENT sequence"
        end
      end
    end

    defp sqlite_sequence_exists?(conn) do
      query!(
        conn,
        "SELECT name FROM sqlite_schema WHERE type = 'table' AND name = 'sqlite_sequence'"
      ).rows != []
    end

    defp restore_sequence!(_conn, _table, _temporary_table, nil), do: :ok

    defp restore_sequence!(conn, table, temporary_table, original_sequence) do
      current_sequence = sequence_value(conn, table) || 0
      sequence = max(original_sequence, current_sequence)

      execute!(conn, "DELETE FROM sqlite_sequence WHERE name IN (?, ?)", [table, temporary_table])
      execute!(conn, "INSERT INTO sqlite_sequence(name, seq) VALUES (?, ?)", [table, sequence])
    end

    defp validate_database!(conn) do
      case query!(conn, "PRAGMA foreign_key_check").rows do
        [] -> :ok
        rows -> raise Ecto.MigrationError, "foreign key check failed: #{inspect(rows)}"
      end

      integrity_results =
        conn
        |> query!("PRAGMA integrity_check")
        |> Map.fetch!(:rows)
        |> Enum.flat_map(&Map.values/1)

      unless integrity_results != [] and Enum.all?(integrity_results, &(&1 == "ok")) do
        raise Ecto.MigrationError, "integrity check failed: #{inspect(integrity_results)}"
      end
    end

    defp foreign_keys!(conn) do
      case query!(conn, "PRAGMA foreign_keys").rows do
        [row] -> row |> Map.values() |> List.first()
        _ -> raise Ecto.MigrationError, "could not read PRAGMA foreign_keys"
      end
    end

    defp set_foreign_keys!(conn, value) when value in [0, 1] do
      setting = if value == 1, do: "ON", else: "OFF"
      execute!(conn, "PRAGMA foreign_keys = #{setting}")

      unless foreign_keys!(conn) == value do
        raise Ecto.MigrationError, "could not set PRAGMA foreign_keys to #{setting}"
      end
    end

    defp query!(conn, sql, params \\ []) do
      case Turso.query(conn, IO.iodata_to_binary(sql), params, timeout: :infinity) do
        {:ok, %Result{} = result} -> result
        {:error, error} -> raise error
      end
    end

    defp execute!(conn, sql, params \\ []) do
      case Turso.execute(conn, IO.iodata_to_binary(sql), params, timeout: :infinity) do
        {:ok, %Result{} = result} -> result
        {:error, error} -> raise error
      end
    end

    defp quote_identifier(identifier) do
      escaped = String.replace(identifier, "\"", "\"\"")
      "\"#{escaped}\""
    end
  end
end
