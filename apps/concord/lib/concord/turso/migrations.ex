defmodule Concord.Turso.Migrations do
  @moduledoc false

  alias Elixir.Turso, as: TursoClient

  @default_db Concord.Turso.DB

  @spec migrate(DBConnection.conn()) :: :ok | {:error, term()}
  def migrate(db \\ @default_db) do
    with :ok <- execute(db, "CREATE TABLE IF NOT EXISTS concord_turso_meta (
                name TEXT PRIMARY KEY,
                value INTEGER NOT NULL
              )"),
         :ok <- execute(db, "CREATE TABLE IF NOT EXISTS concord_turso_current (
                key TEXT PRIMARY KEY,
                record BLOB NOT NULL,
                expires_at INTEGER,
                mod_revision INTEGER NOT NULL,
                version INTEGER NOT NULL
              )"),
         :ok <- execute(db, "CREATE TABLE IF NOT EXISTS concord_turso_history (
                key TEXT NOT NULL,
                revision INTEGER NOT NULL,
                record BLOB NOT NULL,
                PRIMARY KEY (key, revision)
              )"),
         :ok <- execute(db, "CREATE INDEX IF NOT EXISTS concord_turso_history_key_revision
                ON concord_turso_history (key, revision)"),
         :ok <- execute(db, "INSERT OR IGNORE INTO concord_turso_meta (name, value)
                VALUES ('revision', 0)") do
      :ok
    end
  end

  @spec migrate!(DBConnection.conn()) :: :ok
  def migrate!(db \\ @default_db) do
    case migrate(db) do
      :ok -> :ok
      {:error, reason} -> raise "failed to migrate Turso database: #{inspect(reason)}"
    end
  end

  defp execute(db, sql) do
    case TursoClient.execute(db, sql) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
