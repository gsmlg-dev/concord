defmodule Turso.EctoRepo do
  use Ecto.Repo,
    otp_app: :ex_turso,
    adapter: Ecto.Adapters.Turso
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

  alias Ecto.Migration.Table
  alias Turso.{EctoRepo, EctoUser}

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
