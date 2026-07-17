defmodule Turso.Connection do
  @moduledoc """
  `DBConnection` implementation backed by a local turso database.

  Each pooled connection opens its own database handle and connection via the
  native layer. Connection options:

    * `:database` — path to the local database file (required). `":memory:"`
      opens an in-memory database.
    * `:remote_url` — URL of a Turso Cloud database to sync with (optional,
      requires `:auth_token`).
    * `:auth_token` — auth token for the remote database, either a string or a
      zero-arity function returning one (optional, requires `:remote_url`).
  """

  use DBConnection

  alias Turso.{Error, Native, Query, Result}

  # Errors in these classes mean the underlying connection is unusable; the
  # pool drops the connection and opens a fresh one.
  @disconnect_codes [:io, :corrupt]

  @type t :: %__MODULE__{
          db: reference(),
          conn: reference(),
          sync_db: reference() | nil,
          status: :idle | :transaction
        }

  defstruct [:db, :conn, :sync_db, status: :idle]

  @impl true
  def connect(opts) do
    database = Keyword.fetch!(opts, :database)
    remote_url = opts[:remote_url]
    auth_token = resolve_secret(opts[:auth_token])

    result =
      cond do
        remote_url && auth_token ->
          with {:ok, db} <- Native.open_sync(database, remote_url, auth_token),
               {:ok, conn} <- Native.connect_sync(db) do
            {:ok, db, conn, true}
          end

        remote_url || auth_token ->
          {:error, "both :remote_url and :auth_token must be provided for a synced database"}

        true ->
          with {:ok, db} <- Native.open(database),
               {:ok, conn} <- Native.connect(db) do
            {:ok, db, conn, false}
          end
      end

    case result do
      {:ok, db, conn, is_sync} ->
        {:ok, %__MODULE__{db: db, conn: conn, sync_db: if(is_sync, do: db, else: nil)}}

      {:error, reason} ->
        {:error, wrap_error(reason)}
    end
  end

  @impl true
  def disconnect(_err, %__MODULE__{} = state) do
    close_conn(state.conn)
    close_db(state)
    :ok
  end

  @impl true
  def checkout(state), do: {:ok, state}

  @impl true
  def ping(%__MODULE__{conn: conn} = state) do
    case Native.query_rows(conn, "SELECT 1", []) do
      {:ok, _} -> {:ok, state}
      {:error, reason} -> {:disconnect, wrap_error(reason), state}
    end
  end

  @impl true
  def handle_status(_opts, %__MODULE__{status: status} = state), do: {status, state}

  @impl true
  def handle_begin(_opts, %__MODULE__{conn: conn} = state) do
    case Native.execute(conn, "BEGIN", []) do
      {:ok, _} -> {:ok, %Result{}, %{state | status: :transaction}}
      {:error, reason} -> {:disconnect, wrap_error(reason), state}
    end
  end

  @impl true
  def handle_commit(_opts, %__MODULE__{conn: conn} = state) do
    case Native.execute(conn, "COMMIT", []) do
      {:ok, _} -> {:ok, %Result{}, %{state | status: :idle}}
      {:error, reason} -> {:disconnect, wrap_error(reason), state}
    end
  end

  @impl true
  def handle_rollback(_opts, %__MODULE__{conn: conn} = state) do
    case Native.execute(conn, "ROLLBACK", []) do
      {:ok, _} -> {:ok, %Result{}, %{state | status: :idle}}
      {:error, reason} -> {:disconnect, wrap_error(reason), state}
    end
  end

  @impl true
  def handle_execute(%Query{command: :sync} = query, _params, _opts, state) do
    cond do
      state.status == :transaction ->
        {:error, %Error{message: "cannot sync database inside a transaction"}, state}

      is_nil(state.sync_db) ->
        {:error, %Error{message: "database is not configured for cloud sync"}, state}

      true ->
        case Native.sync(state.sync_db) do
          :ok -> {:ok, query, %Result{rows: nil, num_rows: 0}, state}
          {:error, reason} -> error_or_disconnect(reason, state)
        end
    end
  end

  @impl true
  def handle_execute(%Query{command: :query, statement: sql} = query, params, _opts, state) do
    case Native.query_rows(state.conn, sql, params) do
      {:ok, {columns, rows}} ->
        map_rows = Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
        {:ok, query, %Result{columns: columns, rows: map_rows, num_rows: length(rows)}, state}

      {:error, reason} ->
        error_or_disconnect(reason, state)
    end
  end

  @impl true
  def handle_execute(%Query{command: :query_rows, statement: sql} = query, params, _opts, state) do
    case Native.query_rows(state.conn, sql, params) do
      {:ok, {columns, rows}} ->
        {:ok, query, %Result{columns: columns, rows: rows, num_rows: length(rows)}, state}

      {:error, reason} ->
        error_or_disconnect(reason, state)
    end
  end

  def handle_execute(%Query{command: :execute, statement: sql} = query, params, _opts, state) do
    case Native.execute(state.conn, sql, params) do
      {:ok, affected} ->
        {:ok, query, %Result{rows: nil, num_rows: affected}, state}

      {:error, reason} ->
        error_or_disconnect(reason, state)
    end
  end

  # Statements are not prepared server-side; prepare/close are no-ops so the
  # query flows straight to handle_execute/4.
  @impl true
  def handle_prepare(query, _opts, state), do: {:ok, query, state}

  @impl true
  def handle_close(_query, _opts, state), do: {:ok, %Result{}, state}

  # Server-side cursors are not supported.
  @impl true
  def handle_declare(_query, _params, _opts, state) do
    {:error, %Error{message: "cursors are not supported"}, state}
  end

  @impl true
  def handle_fetch(_query, _cursor, _opts, state) do
    {:error, %Error{message: "cursors are not supported"}, state}
  end

  @impl true
  def handle_deallocate(_query, _cursor, _opts, state) do
    {:error, %Error{message: "cursors are not supported"}, state}
  end

  defp resolve_secret(fun) when is_function(fun, 0), do: fun.()
  defp resolve_secret(value), do: value

  defp close_conn(conn) when is_reference(conn), do: Native.close(conn)
  defp close_conn(_conn), do: :ok

  defp close_db(%__MODULE__{sync_db: sync_db}) when is_reference(sync_db),
    do: Native.close_sync_db(sync_db)

  defp close_db(%__MODULE__{db: db}) when is_reference(db), do: Native.close_db(db)
  defp close_db(_state), do: :ok

  defp wrap_error({code, message}) when is_atom(code) and is_binary(message),
    do: %Error{code: code, message: message}

  defp wrap_error(message) when is_binary(message), do: %Error{message: message}

  defp error_or_disconnect(reason, state) do
    error = wrap_error(reason)

    if error.code in @disconnect_codes do
      {:disconnect, error, state}
    else
      {:error, error, state}
    end
  end
end
