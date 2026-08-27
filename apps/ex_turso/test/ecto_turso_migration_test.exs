defmodule Turso.MigrationRepo do
  use Ecto.Repo,
    otp_app: :ex_turso,
    adapter: Ecto.Adapters.Turso
end

defmodule Turso.MigrationSandboxRepo do
  use Ecto.Repo,
    otp_app: :ex_turso,
    adapter: Ecto.Adapters.Turso
end

defmodule Turso.NullableRebuildMigration do
  use Ecto.Migration

  alias Ecto.Adapters.Turso.Migration

  @disable_ddl_transaction true

  def up do
    execute(fn -> rebuild(null: true) end)
  end

  def down do
    execute(fn -> rebuild(null: false) end)
  end

  defp rebuild(opts) do
    Migration.rebuild_table!(
      repo(),
      :migration_nullable_records,
      create: fn temporary_table ->
        nullability = if opts[:null], do: "", else: " NOT NULL"
        "CREATE TABLE #{temporary_table} (id INTEGER PRIMARY KEY, value TEXT#{nullability})"
      end,
      copy: [:id, :value]
    )
  end
end

defmodule Turso.EctoTursoMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.Turso.Migration
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Table
  alias Turso.{MigrationRepo, MigrationSandboxRepo, NullableRebuildMigration}

  @tag :tmp_dir
  test "runs from reversible Ecto up and down migrations", %{tmp_dir: tmp_dir} do
    repo = start_repo!(tmp_dir, "migrator.db")

    repo.query!(
      "CREATE TABLE migration_nullable_records (id INTEGER PRIMARY KEY, value TEXT NOT NULL)"
    )

    repo.query!("INSERT INTO migration_nullable_records VALUES (1, 'present')")
    version = 20_260_827_000_082

    assert :ok = Ecto.Migrator.up(repo, version, NullableRebuildMigration, log: false)

    assert %{num_rows: 1} =
             repo.query!("INSERT INTO migration_nullable_records VALUES (2, NULL)")

    repo.query!("DELETE FROM migration_nullable_records WHERE id = 2")

    assert :ok = Ecto.Migrator.down(repo, version, NullableRebuildMigration, log: false)

    assert_raise Turso.Error, ~r/NOT NULL constraint failed/, fn ->
      repo.query!("INSERT INTO migration_nullable_records VALUES (2, NULL)")
    end
  end

  @tag :tmp_dir
  test "rebuilds a table while preserving schema objects and behavior", %{tmp_dir: tmp_dir} do
    repo = start_repo!(tmp_dir, "success.db")
    create_import_fixture!(repo)

    assert :ok =
             Migration.rebuild_table!(
               repo,
               :github_import_runs,
               create: &nullable_import_runs_sql/1,
               copy: [
                 :id,
                 :source_owner_github_id,
                 :source_owner_login,
                 :state,
                 :finished_at
               ],
               validate: fn conn ->
                 case Turso.query(conn, "SELECT COUNT(*) AS count FROM github_import_runs") do
                   {:ok, %Turso.Result{rows: [%{"count" => 1}]}} ->
                     send(self(), :custom_validation_ran)
                     :ok

                   result ->
                     {:error, result}
                 end
               end
             )

    assert_received :custom_validation_ran
    assert %{rows: [[1]]} = repo.query!("PRAGMA foreign_keys")

    assert %{rows: [[1, 7, "octocat", "pending", nil]]} =
             repo.query!("SELECT * FROM github_import_runs")

    assert %{rows: [[1, 1]]} = repo.query!("SELECT id, run_id FROM github_import_items")

    assert %{rows: [[table_sql]]} =
             repo.query!(
               "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = 'github_import_runs'"
             )

    refute table_sql =~ ~r/source_owner_github_id\s+INTEGER\s+NOT NULL/i
    assert table_sql =~ "github_import_runs_owner_check"

    assert %{rows: objects} =
             repo.query!("""
             SELECT type, name, sql
             FROM sqlite_schema
             WHERE tbl_name = 'github_import_runs'
               AND type IN ('index', 'trigger')
               AND sql IS NOT NULL
             ORDER BY type, name
             """)

    assert [
             ["index", "github_import_runs_lower_login_idx", expression_index_sql],
             ["index", "github_import_runs_open_owner_idx", partial_index_sql],
             ["index", "github_import_runs_owner_login_idx", _unique_index_sql],
             ["index", "github_import_runs_state_idx", _ordinary_index_sql],
             ["trigger", "github_import_runs_audit", _trigger_sql]
           ] = objects

    assert expression_index_sql =~ ~r/lower\s*\(source_owner_login\)/i
    assert partial_index_sql =~ ~r/WHERE\s+finished_at\s+IS\s+NULL/i

    assert %{rows: [[42, 7, "pending"]]} =
             repo.query!("""
             INSERT INTO github_import_runs (source_owner_login)
             VALUES ('default-owner')
             RETURNING id, source_owner_github_id, state
             """)

    assert %{rows: [[43]]} =
             repo.query!("""
             INSERT INTO github_import_runs (source_owner_github_id, source_owner_login)
             VALUES (NULL, 'nullable-owner')
             RETURNING id
             """)

    assert_raise Turso.Error, ~r/FOREIGN KEY constraint failed/, fn ->
      repo.query!("""
      INSERT INTO github_import_runs (source_owner_github_id, source_owner_login)
      VALUES (999, 'missing-owner')
      """)
    end

    assert_raise Turso.Error, ~r/FOREIGN KEY constraint failed/, fn ->
      repo.query!("INSERT INTO github_import_items VALUES (2, 999)")
    end

    assert_raise Turso.Error, ~r/github_import_runs_owner_check/, fn ->
      repo.query!("""
      INSERT INTO github_import_runs (source_owner_github_id, source_owner_login)
      VALUES (NULL, NULL)
      """)
    end

    assert_raise Turso.Error, ~r/UNIQUE constraint failed/, fn ->
      repo.query!("""
      INSERT INTO github_import_runs (source_owner_github_id, source_owner_login)
      VALUES (7, 'octocat')
      """)
    end

    repo.query!("UPDATE github_import_runs SET state = 'done' WHERE id = 1")
    assert %{rows: [[1, "done"]]} = repo.query!("SELECT run_id, state FROM github_import_audit")
    assert %{rows: []} = repo.query!("PRAGMA foreign_key_check")
    assert %{rows: [["ok"]]} = repo.query!("PRAGMA integrity_check")
  end

  @tag :tmp_dir
  test "preserves disabled foreign key enforcement after a successful rebuild", %{
    tmp_dir: tmp_dir
  } do
    repo = start_repo!(tmp_dir, "foreign-keys-off.db")
    repo.query!("CREATE TABLE fk_off_records (id INTEGER PRIMARY KEY)")
    repo.query!("PRAGMA foreign_keys = OFF")

    assert :ok =
             Migration.rebuild_table!(
               repo,
               :fk_off_records,
               create: fn temporary_table ->
                 "CREATE TABLE #{temporary_table} (id INTEGER PRIMARY KEY)"
               end,
               copy: [:id]
             )

    assert %{rows: [[0]]} = repo.query!("PRAGMA foreign_keys")
  end

  @tag :tmp_dir
  test "allows selecting which schema object kinds are recreated", %{tmp_dir: tmp_dir} do
    repo = start_repo!(tmp_dir, "recreate.db")
    repo.query!("CREATE TABLE rebuild_audit (record_id INTEGER)")
    repo.query!("CREATE TABLE recreate_records (id INTEGER PRIMARY KEY, value TEXT)")
    repo.query!("CREATE INDEX recreate_records_value_idx ON recreate_records(value)")

    repo.query!("""
    CREATE TRIGGER recreate_records_audit
    AFTER INSERT ON recreate_records
    BEGIN
      INSERT INTO rebuild_audit VALUES (NEW.id);
    END
    """)

    assert :ok =
             Migration.rebuild_table!(
               repo,
               :recreate_records,
               create: fn temporary_table ->
                 "CREATE TABLE #{temporary_table} (id INTEGER PRIMARY KEY, value TEXT)"
               end,
               copy: [:id, :value],
               recreate: [:indexes]
             )

    assert %{rows: [["recreate_records_value_idx"]]} =
             repo.query!(
               "SELECT name FROM sqlite_schema WHERE type = 'index' AND tbl_name = 'recreate_records'"
             )

    assert %{rows: []} =
             repo.query!(
               "SELECT name FROM sqlite_schema WHERE type = 'trigger' AND tbl_name = 'recreate_records'"
             )
  end

  @tag :tmp_dir
  test "rolls back a failed rebuild and restores foreign key enforcement", %{tmp_dir: tmp_dir} do
    repo = start_repo!(tmp_dir, "rollback.db")
    repo.query!("CREATE TABLE rollback_records (id INTEGER PRIMARY KEY, value TEXT)")
    repo.query!("INSERT INTO rollback_records VALUES (1, NULL)")

    schema_before = schema_snapshot(repo)

    assert_raise Turso.Error, ~r/NOT NULL constraint failed/, fn ->
      Migration.rebuild_table!(
        repo,
        :rollback_records,
        create: fn temporary_table ->
          "CREATE TABLE #{temporary_table} (id INTEGER PRIMARY KEY, value TEXT NOT NULL)"
        end,
        copy: [:id, :value]
      )
    end

    assert schema_snapshot(repo) == schema_before
    assert %{rows: [[1, nil]]} = repo.query!("SELECT id, value FROM rollback_records")
    assert %{rows: [[1]]} = repo.query!("PRAGMA foreign_keys")
    assert %{rows: [["ok"]]} = repo.query!("PRAGMA integrity_check")
  end

  @tag :tmp_dir
  test "rejects an existing transaction before changing the database", %{tmp_dir: tmp_dir} do
    repo = start_repo!(tmp_dir, "transaction.db")
    repo.query!("CREATE TABLE transaction_records (id INTEGER PRIMARY KEY)")
    schema_before = schema_snapshot(repo)

    assert {:ok, :rejected} =
             repo.transaction(fn ->
               assert_raise Ecto.MigrationError,
                            ~r/@disable_ddl_transaction true.*existing transaction/s,
                            fn ->
                              Migration.rebuild_table!(
                                repo,
                                :transaction_records,
                                create: fn temporary_table ->
                                  "CREATE TABLE #{temporary_table} (id INTEGER PRIMARY KEY)"
                                end,
                                copy: [:id]
                              )
                            end

               :rejected
             end)

    assert schema_snapshot(repo) == schema_before
    assert %{rows: [[1]]} = repo.query!("PRAGMA foreign_keys")
  end

  @tag :tmp_dir
  test "rejects a hidden sandbox transaction", %{tmp_dir: tmp_dir} do
    start_supervised!(
      {MigrationSandboxRepo,
       database: Path.join(tmp_dir, "sandbox.db"), pool: Sandbox, pool_size: 1, log: false}
    )

    Sandbox.unboxed_run(MigrationSandboxRepo, fn ->
      MigrationSandboxRepo.query!("CREATE TABLE sandbox_records (id INTEGER PRIMARY KEY)")
    end)

    assert :ok = Sandbox.checkout(MigrationSandboxRepo)

    try do
      assert_raise Ecto.MigrationError, ~r/@disable_ddl_transaction true/, fn ->
        Migration.rebuild_table!(
          MigrationSandboxRepo,
          :sandbox_records,
          create: fn temporary_table ->
            "CREATE TABLE #{temporary_table} (id INTEGER PRIMARY KEY)"
          end,
          copy: [:id]
        )
      end
    after
      Sandbox.checkin(MigrationSandboxRepo)
    end
  end

  @tag :tmp_dir
  test "rejects invalid identifiers and copy mappings", %{tmp_dir: tmp_dir} do
    repo = start_repo!(tmp_dir, "invalid.db")
    repo.query!("CREATE TABLE invalid_records (id INTEGER PRIMARY KEY, value TEXT)")

    create = fn temporary_table ->
      "CREATE TABLE #{temporary_table} (id INTEGER PRIMARY KEY, value TEXT)"
    end

    assert_raise ArgumentError, ~r/unqualified/, fn ->
      Migration.rebuild_table!(repo, "aux.invalid_records", create: create, copy: [:id])
    end

    assert_raise ArgumentError, ~r/duplicate target column/, fn ->
      Migration.rebuild_table!(
        repo,
        :invalid_records,
        create: create,
        copy: [:id, {:id, :value}]
      )
    end

    schema_before = schema_snapshot(repo)

    assert_raise Ecto.MigrationError, ~r/copy source column.*missing/, fn ->
      Migration.rebuild_table!(
        repo,
        :invalid_records,
        create: create,
        copy: [:id, {:value, :missing}]
      )
    end

    assert schema_snapshot(repo) == schema_before

    assert_raise ArgumentError, ~r/unsupported :recreate/, fn ->
      Migration.rebuild_table!(
        repo,
        :invalid_records,
        create: create,
        copy: [:id, :value],
        recreate: [:views]
      )
    end

    repo.query!("CREATE TABLE sequence_records (id INTEGER PRIMARY KEY AUTOINCREMENT)")
    repo.query!("INSERT INTO sequence_records DEFAULT VALUES")
    sequence_schema_before = schema_snapshot(repo)

    assert_raise Ecto.MigrationError, ~r/preserve.*AUTOINCREMENT/, fn ->
      Migration.rebuild_table!(
        repo,
        :sequence_records,
        create: fn temporary_table ->
          "CREATE TABLE #{temporary_table} (id INTEGER PRIMARY KEY)"
        end,
        copy: [:id]
      )
    end

    assert schema_snapshot(repo) == sequence_schema_before
  end

  test "unsupported Ecto modify points to the rebuild helper" do
    command =
      {:alter, %Table{name: "github_import_runs"},
       [{:modify, :source_owner_github_id, :bigint, null: true}]}

    assert_raise ArgumentError, ~r/Ecto\.Adapters\.Turso\.Migration\.rebuild_table!\/3/, fn ->
      Ecto.Adapters.Turso.Connection.execute_ddl(command)
    end
  end

  defp start_repo!(tmp_dir, filename) do
    start_supervised!(
      {MigrationRepo, database: Path.join(tmp_dir, filename), pool_size: 1, log: false}
    )

    MigrationRepo
  end

  defp create_import_fixture!(repo) do
    repo.query!("CREATE TABLE import_owners (id INTEGER PRIMARY KEY)")
    repo.query!("CREATE TABLE github_import_audit (run_id INTEGER NOT NULL, state TEXT NOT NULL)")

    repo.query!("""
    CREATE TABLE github_import_runs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      source_owner_github_id INTEGER NOT NULL DEFAULT 7 REFERENCES import_owners(id),
      source_owner_login TEXT COLLATE NOCASE,
      state TEXT NOT NULL DEFAULT 'pending',
      finished_at TEXT,
      CONSTRAINT github_import_runs_owner_check
        CHECK (source_owner_github_id IS NOT NULL OR source_owner_login IS NOT NULL)
    )
    """)

    repo.query!("""
    CREATE TABLE github_import_items (
      id INTEGER PRIMARY KEY,
      run_id INTEGER NOT NULL REFERENCES github_import_runs(id) ON DELETE CASCADE
    )
    """)

    repo.query!("CREATE INDEX github_import_runs_state_idx ON github_import_runs(state)")

    repo.query!("""
    CREATE UNIQUE INDEX github_import_runs_owner_login_idx
    ON github_import_runs(source_owner_github_id, source_owner_login)
    """)

    repo.query!("""
    CREATE INDEX github_import_runs_open_owner_idx
    ON github_import_runs(source_owner_github_id)
    WHERE finished_at IS NULL
    """)

    repo.query!("""
    CREATE INDEX github_import_runs_lower_login_idx
    ON github_import_runs(lower(source_owner_login))
    """)

    repo.query!("""
    CREATE TRIGGER github_import_runs_audit
    AFTER UPDATE OF state ON github_import_runs
    BEGIN
      INSERT INTO github_import_audit(run_id, state) VALUES (NEW.id, NEW.state);
    END
    """)

    repo.query!("INSERT INTO import_owners VALUES (7)")
    repo.query!("INSERT INTO import_owners VALUES (8)")

    repo.query!("""
    INSERT INTO github_import_runs
      (id, source_owner_github_id, source_owner_login, state, finished_at)
    VALUES
      (1, 7, 'octocat', 'pending', NULL),
      (41, 8, 'deleted-high-water', 'done', '2026-08-27')
    """)

    repo.query!("DELETE FROM github_import_runs WHERE id = 41")
    repo.query!("INSERT INTO github_import_items VALUES (1, 1)")
  end

  defp nullable_import_runs_sql(temporary_table) do
    """
    CREATE TABLE #{temporary_table} (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      source_owner_github_id INTEGER DEFAULT 7 REFERENCES import_owners(id),
      source_owner_login TEXT COLLATE NOCASE,
      state TEXT NOT NULL DEFAULT 'pending',
      finished_at TEXT,
      CONSTRAINT github_import_runs_owner_check
        CHECK (source_owner_github_id IS NOT NULL OR source_owner_login IS NOT NULL)
    )
    """
  end

  defp schema_snapshot(repo) do
    repo.query!("""
    SELECT type, name, tbl_name, sql
    FROM sqlite_schema
    ORDER BY type, name
    """).rows
  end
end
