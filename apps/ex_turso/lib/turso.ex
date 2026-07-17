defmodule Turso do
  @moduledoc """
  A thin Elixir wrapper around the [`turso`](https://crates.io/crates/turso)
  Rust crate, exposed as a `DBConnection` pool over Rustler NIFs.

  ## Starting a pool

  `Turso` is startable under a supervision tree:

      children = [
        {Turso, database: "my_app.db", name: MyApp.DB}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  Then run queries against the registered name:

      {:ok, _} = Turso.execute(MyApp.DB, "CREATE TABLE users (id INTEGER, name TEXT)")
      {:ok, _} = Turso.execute(MyApp.DB, "INSERT INTO users VALUES (?, ?)", [1, "Alice"])
      {:ok, %Turso.Result{rows: [%{"name" => "Alice"}]}} =
        Turso.query(MyApp.DB, "SELECT name FROM users WHERE id = ?", [1])

  ## Turso Cloud sync

  Pass `:remote_url` and `:auth_token` to open the local file as an embedded
  replica of a Turso Cloud database, then call `sync/2` to synchronize:

      children = [
        {Turso,
         database: "replica.db",
         remote_url: "libsql://my-db.turso.io",
         auth_token: fn -> System.fetch_env!("TURSO_AUTH_TOKEN") end,
         name: MyApp.DB}
      ]

      :ok = Turso.sync(MyApp.DB)

  ## Options

  All options are forwarded to `DBConnection.start_link/2`. The
  `Turso`-specific options are:

    * `:database` — path to the local database file (required); `":memory:"`
      opens an in-memory database per pooled connection
    * `:remote_url` — URL of a Turso Cloud database to sync with (requires
      `:auth_token`)
    * `:auth_token` — auth token for the remote database, either a string or
      a zero-arity function returning one; prefer the function form so the
      token does not sit in supervisor child specs and crash reports
  """

  alias Turso.Query

  @type conn :: DBConnection.conn()

  @doc """
  Returns a child specification so `Turso` can be supervised directly:

      {Turso, database: "my_app.db", name: MyApp.DB}
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    DBConnection.child_spec(Turso.Connection, opts)
  end

  @doc """
  Starts a connection pool linked to the current process.

  Accepts `:database` plus any `DBConnection.start_link/2` option (e.g. `:name`,
  `:pool_size`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    DBConnection.start_link(Turso.Connection, opts)
  end

  @doc """
  Runs a query and returns `{:ok, %Turso.Result{}}` or `{:error, exception}`.

  Rows come back as a list of maps keyed by column name.
  """
  @spec query(conn(), String.t(), list(), keyword()) ::
          {:ok, Turso.Result.t()} | {:error, Exception.t()}
  def query(conn, statement, params \\ [], opts \\ []) do
    run(conn, statement, :query, params, opts)
  end

  @doc """
  Executes a statement and returns `{:ok, %Turso.Result{}}` whose `num_rows`
  is the affected-row count, or `{:error, exception}`.
  """
  @spec execute(conn(), String.t(), list(), keyword()) ::
          {:ok, Turso.Result.t()} | {:error, Exception.t()}
  def execute(conn, statement, params \\ [], opts \\ []) do
    run(conn, statement, :execute, params, opts)
  end

  @doc """
  Triggers a synchronization of the local replica database with the remote Turso Cloud database.
  """
  @spec sync(conn(), keyword()) :: :ok | {:error, Exception.t()}
  def sync(conn, opts \\ []) do
    query = %Query{statement: "SYNC", command: :sync}

    case DBConnection.execute(conn, query, [], opts) do
      {:ok, _query, _result} -> :ok
      {:error, _exception} = error -> error
    end
  end

  defp run(conn, statement, command, params, opts) do
    query = %Query{statement: statement, command: command}

    case DBConnection.execute(conn, query, params, opts) do
      {:ok, _query, result} -> {:ok, result}
      {:error, _exception} = error -> error
    end
  end
end
