defmodule Concord.Turso.Migrations do
  @moduledoc false

  alias Concord.Turso.Codec
  alias Elixir.Turso, as: TursoClient

  @default_db Concord.Turso.DB

  @spec migrate(DBConnection.conn(), keyword()) :: :ok | {:error, term()}
  def migrate(db \\ @default_db, opts \\ []) do
    case DBConnection.transaction(
           db,
           fn conn ->
             case migrate_schema(conn, opts) do
               :ok -> :ok
               {:error, reason} -> DBConnection.rollback(conn, reason)
             end
           end,
           opts
         ) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp migrate_schema(db, opts) do
    with :ok <- execute(db, "CREATE TABLE IF NOT EXISTS concord_turso_meta (
                name TEXT PRIMARY KEY,
                value INTEGER NOT NULL
              )", [], opts),
         :ok <- execute(db, "CREATE TABLE IF NOT EXISTS concord_turso_current (
                key TEXT PRIMARY KEY,
                record BLOB NOT NULL,
                expires_at INTEGER,
                mod_revision INTEGER NOT NULL,
                version INTEGER NOT NULL,
                record_metadata BLOB
              )", [], opts),
         :ok <- ensure_record_metadata(db, opts),
         :ok <- execute(db, "CREATE TABLE IF NOT EXISTS concord_turso_history (
                key TEXT NOT NULL,
                revision INTEGER NOT NULL,
                record BLOB NOT NULL,
                PRIMARY KEY (key, revision)
              )", [], opts),
         :ok <- execute(db, "CREATE INDEX IF NOT EXISTS concord_turso_history_key_revision
                ON concord_turso_history (key, revision)", [], opts),
         :ok <- execute(db, "CREATE TABLE IF NOT EXISTS concord_turso_txn_requests (
                idempotency_key TEXT PRIMARY KEY,
                request_hash BLOB NOT NULL,
                result BLOB NOT NULL,
                revision INTEGER NOT NULL,
                cached_at INTEGER NOT NULL
              )", [], opts),
         :ok <- execute(db, "INSERT OR IGNORE INTO concord_turso_meta (name, value)
                VALUES ('revision', 0)", [], opts) do
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

  defp ensure_record_metadata(db, opts) do
    with {:ok, %{rows: columns}} <-
           TursoClient.query(db, "PRAGMA table_info(concord_turso_current)", [], opts),
         :ok <- add_record_metadata(db, columns, opts),
         :ok <- execute(db, "CREATE INDEX IF NOT EXISTS concord_turso_current_missing_metadata
                 ON concord_turso_current (key) WHERE record_metadata IS NULL", [], opts),
         :ok <- execute(db, "CREATE INDEX IF NOT EXISTS concord_turso_current_metadata
                 ON concord_turso_current (key, record_metadata, version, expires_at)", [], opts) do
      backfill_record_metadata(db, opts)
    end
  end

  defp add_record_metadata(db, columns, opts) do
    if Enum.any?(columns, &(&1["name"] == "record_metadata")) do
      :ok
    else
      execute(db, "ALTER TABLE concord_turso_current ADD COLUMN record_metadata BLOB", [], opts)
    end
  end

  defp backfill_record_metadata(db, opts) do
    with :ok <- check_deadline(opts),
         {:ok, %{rows: rows}} <-
           TursoClient.query(db, "SELECT key FROM concord_turso_current
             INDEXED BY concord_turso_current_missing_metadata
             WHERE record_metadata IS NULL LIMIT 100", [], opts) do
      backfill_record_metadata_rows(db, rows, opts)
    end
  end

  defp backfill_record_metadata_rows(_db, [], _opts), do: :ok

  defp backfill_record_metadata_rows(db, rows, opts) do
    Enum.reduce_while(rows, :ok, fn %{"key" => key}, :ok ->
      with :ok <- check_deadline(opts),
           {:ok, %{rows: [%{"record" => binary}]}} <-
             TursoClient.query(
               db,
               "SELECT record FROM concord_turso_current WHERE key = ?",
               [key],
               opts
             ),
           metadata = binary |> Codec.decode_record() |> Codec.encode_record_metadata(),
           :ok <-
             execute(
               db,
               "UPDATE concord_turso_current SET record_metadata = ? WHERE key = ?",
               [metadata, key],
               opts
             ) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> backfill_record_metadata(db, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_deadline(opts) do
    case Keyword.get(opts, :deadline) do
      nil ->
        :ok

      deadline ->
        if System.monotonic_time(:millisecond) < deadline, do: :ok, else: {:error, :timeout}
    end
  end

  defp execute(db, sql, params, opts) do
    case TursoClient.execute(db, sql, params, opts) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
