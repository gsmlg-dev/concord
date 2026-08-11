defmodule Turso.EctoRepo do
  use Ecto.Repo,
    otp_app: :ex_turso,
    adapter: Ecto.Adapters.Turso
end

defmodule Turso.SandboxRepo do
  use Ecto.Repo,
    otp_app: :ex_turso,
    adapter: Ecto.Adapters.Turso
end

defmodule Turso.ReversibleMigration do
  use Ecto.Migration

  def change do
    create table(:migration_records) do
      add(:name, :string)
    end
  end
end

defmodule Turso.EctoUser do
  use Ecto.Schema

  import Ecto.Changeset

  schema "ecto_users" do
    field(:name, :string)
    field(:score, :float)
    field(:active, :boolean)
    field(:metadata, :map)
    field(:birthday, :date)
    field(:data, :binary)
  end

  def changeset(user, attrs) do
    cast(user, attrs, [:name, :score, :active, :metadata, :birthday, :data])
  end
end

defmodule Turso.EctoTursoTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Table
  alias Turso.{EctoRepo, EctoUser, ReversibleMigration, SandboxRepo}

  setup do
    start_supervised!({EctoRepo, database: ":memory:", pool_size: 1, log: false})

    EctoRepo.query!("""
    CREATE TABLE ecto_users (
      id INTEGER PRIMARY KEY,
      name TEXT,
      score NUMERIC,
      active INTEGER,
      metadata TEXT,
      birthday TEXT,
      data BLOB
    )
    """)

    :ok
  end

  test "Repo.query!/3 returns ordered columns and row values" do
    result = EctoRepo.query!("SELECT ? AS b, ? AS a", [2, 1])

    assert result.columns == ["b", "a"]
    assert result.rows == [[2, 1]]
    assert result.num_rows == 1
  end

  test "schema operations work through Ecto.Adapters.Turso" do
    {:ok, inserted} =
      %EctoUser{}
      |> EctoUser.changeset(%{
        name: "Alice",
        score: 9.5,
        active: true,
        metadata: %{"role" => "admin"},
        birthday: ~D[2026-01-02],
        data: "raw-bytes"
      })
      |> EctoRepo.insert()

    assert is_integer(inserted.id)

    loaded = EctoRepo.get!(EctoUser, inserted.id)
    assert loaded.name == "Alice"
    assert loaded.score == 9.5
    assert loaded.active == true
    assert loaded.metadata == %{"role" => "admin"}
    assert loaded.birthday == ~D[2026-01-02]
    assert loaded.data == "raw-bytes"

    assert [{"Alice", inserted.id}] ==
             EctoRepo.all(
               from(u in EctoUser,
                 where: u.active == true,
                 order_by: [desc: u.id],
                 select: {u.name, u.id}
               )
             )

    {:ok, updated} =
      inserted
      |> EctoUser.changeset(%{name: "Ada", active: false})
      |> EctoRepo.update()

    assert updated.name == "Ada"
    assert EctoRepo.get!(EctoUser, inserted.id).active == false

    assert {:ok, %EctoUser{}} = EctoRepo.delete(updated)
    assert EctoRepo.get(EctoUser, inserted.id) == nil
  end

  test "delete_all uses the target table in filtered predicates" do
    first =
      %EctoUser{}
      |> EctoUser.changeset(%{name: "First", active: true})
      |> EctoRepo.insert!()

    second =
      %EctoUser{}
      |> EctoUser.changeset(%{name: "Second", active: true})
      |> EctoRepo.insert!()

    assert {1, nil} =
             EctoRepo.delete_all(from(user in EctoUser, where: user.id == ^first.id))

    assert EctoRepo.get(EctoUser, first.id) == nil
    assert EctoRepo.get!(EctoUser, second.id).name == "Second"
  end

  test "migration rollback deletes the applied schema version" do
    version = 20_260_811_000_001

    assert :ok = Ecto.Migrator.up(EctoRepo, version, ReversibleMigration, log: false)
    assert version in Ecto.Migrator.migrated_versions(EctoRepo)

    assert :ok = Ecto.Migrator.down(EctoRepo, version, ReversibleMigration, log: false)
    refute version in Ecto.Migrator.migrated_versions(EctoRepo)
  end

  test "transactions rollback through Ecto" do
    assert {:error, :stop} =
             EctoRepo.transaction(fn ->
               %EctoUser{}
               |> EctoUser.changeset(%{name: "Rollback", active: true})
               |> EctoRepo.insert!()

               EctoRepo.rollback(:stop)
             end)

    assert EctoRepo.aggregate(EctoUser, :count) == 0
  end

  test "transactions inside a sandbox checkout use savepoints" do
    start_supervised!(
      {SandboxRepo,
       database: ":memory:", pool: Ecto.Adapters.SQL.Sandbox, pool_size: 1, log: false}
    )

    Sandbox.unboxed_run(SandboxRepo, fn ->
      SandboxRepo.query!("CREATE TABLE sandbox_records (id INTEGER PRIMARY KEY)")
    end)

    assert :ok = Sandbox.checkout(SandboxRepo)

    try do
      refute SandboxRepo.in_transaction?()

      assert {:ok, :ok} =
               SandboxRepo.transaction(fn ->
                 assert SandboxRepo.in_transaction?()
                 SandboxRepo.query!("INSERT INTO sandbox_records VALUES (?)", [1])
                 :ok
               end)

      assert {:error, :stop} =
               SandboxRepo.transaction(fn ->
                 SandboxRepo.query!("INSERT INTO sandbox_records VALUES (?)", [2])
                 SandboxRepo.rollback(:stop)
               end)

      assert %{rows: [[1]]} =
               SandboxRepo.query!("SELECT id FROM sandbox_records ORDER BY id")

      assert {:ok, :ok} = SandboxRepo.transaction(fn -> :ok end)
      refute SandboxRepo.in_transaction?()
    after
      Sandbox.checkin(SandboxRepo)
    end

    assert :ok = Sandbox.checkout(SandboxRepo)

    try do
      assert %{rows: []} = SandboxRepo.query!("SELECT id FROM sandbox_records")
    after
      Sandbox.checkin(SandboxRepo)
    end
  end

  test "nullable ALTER TABLE columns preserve foreign keys" do
    EctoRepo.query!("CREATE TABLE alter_parents (id INTEGER PRIMARY KEY)")

    EctoRepo.query!(
      "CREATE TABLE alter_children " <>
        "(id INTEGER PRIMARY KEY, " <>
        "parent_id INTEGER REFERENCES alter_parents(id))"
    )

    [alter_sql] =
      Ecto.Adapters.Turso.Connection.execute_ddl(
        {:alter, %Table{name: "alter_children"},
         [{:add, :request_metadata, :string, [null: true]}]}
      )

    alter_sql = IO.iodata_to_binary(alter_sql)

    assert alter_sql ==
             ~s|ALTER TABLE "alter_children" ADD COLUMN "request_metadata" TEXT|

    EctoRepo.query!(alter_sql)

    assert %{columns: columns, rows: [row]} =
             EctoRepo.query!("PRAGMA foreign_key_list(alter_children)")

    assert %{"table" => "alter_parents", "from" => "parent_id", "to" => "id"} =
             columns
             |> Enum.zip(row)
             |> Map.new()

    EctoRepo.query!("INSERT INTO alter_parents VALUES (?)", [1])

    EctoRepo.query!(
      "INSERT INTO alter_children (id, parent_id) VALUES (?, ?)",
      [1, 1]
    )

    assert_raise Turso.Error, ~r/FOREIGN KEY constraint failed/, fn ->
      EctoRepo.query!(
        "INSERT INTO alter_children (id, parent_id) VALUES (?, ?)",
        [2, -1]
      )
    end
  end

  test "migration DDL supports string check constraints" do
    [create_sql] =
      Ecto.Adapters.Turso.Connection.execute_ddl(
        {:create, %Table{name: "checked_users"},
         [
           {:add, :role, :string,
            [
              null: false,
              default: "user",
              check: "role in ('admin', 'user')"
            ]}
         ]}
      )

    create_sql = IO.iodata_to_binary(create_sql)

    assert create_sql =~
             ~S|"role" TEXT DEFAULT 'user' NOT NULL CHECK (role in ('admin', 'user'))|

    EctoRepo.query!(create_sql)
    EctoRepo.query!("INSERT INTO checked_users (role) VALUES (?)", ["admin"])

    assert_raise Turso.Error, ~r/CHECK constraint failed/, fn ->
      EctoRepo.query!("INSERT INTO checked_users (role) VALUES (?)", ["guest"])
    end
  end

  test "migration DDL supports named check constraints during create table" do
    [create_sql] =
      Ecto.Adapters.Turso.Connection.execute_ddl(
        {:create, %Table{name: "named_checked_users"},
         [
           {:add, :role, :string,
            [
              null: false,
              default: "user",
              check: %{name: "users_role_check", expr: "role in ('admin', 'user')"}
            ]}
         ]}
      )

    create_sql = IO.iodata_to_binary(create_sql)

    assert create_sql =~
             ~S|CONSTRAINT users_role_check CHECK (role in ('admin', 'user'))|

    EctoRepo.query!(create_sql)

    assert_raise Turso.Error, ~r/CHECK constraint failed/, fn ->
      EctoRepo.query!("INSERT INTO named_checked_users (role) VALUES (?)", ["guest"])
    end
  end
end
