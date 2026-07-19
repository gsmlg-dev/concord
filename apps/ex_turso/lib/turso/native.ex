defmodule Turso.Native do
  @moduledoc """
  Rustler NIF declarations for the `turso` crate.

  Every function here is replaced at load time by its native implementation in
  `native/ex_turso/src/lib.rs`. The bodies below only exist so the module
  compiles and raises a clear error if the NIF fails to load.

  All NIFs are scheduled on dirty IO threads and return `{:error, {code, reason}}`
  on failure, where `code` is an error-class atom (see `t:Turso.Error.code/0`)
  and `reason` is a string.
  """

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :ex_turso,
    crate: "ex_turso",
    base_url: "https://github.com/gsmlg-dev/ex_turso/releases/download/v#{version}",
    force_build: true,
    targets: ~w(
      aarch64-apple-darwin
      aarch64-unknown-linux-gnu
      x86_64-apple-darwin
      x86_64-pc-windows-msvc
      x86_64-unknown-freebsd
      x86_64-unknown-linux-gnu
    ),
    nif_versions: ["2.15"],
    version: version

  @typedoc "Error tuple returned by every NIF: an error-class atom plus a message."
  @type nif_error :: {Turso.Error.code(), String.t()}

  @doc "Open (or create) a local database file. Returns `{:ok, db}` or `{:error, {code, reason}}`."
  @spec open(String.t()) :: {:ok, reference()} | {:error, nif_error()}
  def open(_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Open a connection against a database handle."
  @spec connect(reference()) :: {:ok, reference()} | {:error, nif_error()}
  def connect(_db), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Run a query, returning rows as a list of maps keyed by column name."
  @spec query(reference(), String.t(), list()) ::
          {:ok, [map()]} | {:error, nif_error()}
  def query(_conn, _sql, _params), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Run a query, returning ordered column names and ordered row values."
  @spec query_rows(reference(), String.t(), list()) ::
          {:ok, {[String.t()], [[term()]]}} | {:error, nif_error()}
  def query_rows(_conn, _sql, _params), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Execute a statement, returning the number of affected rows."
  @spec execute(reference(), String.t(), list()) ::
          {:ok, non_neg_integer()} | {:error, nif_error()}
  def execute(_conn, _sql, _params), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Open (or create) a local database synced with a remote database."
  @spec open_sync(String.t(), String.t(), String.t()) ::
          {:ok, reference()} | {:error, nif_error()}
  def open_sync(_path, _remote_url, _auth_token), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Open a connection against a synced database."
  @spec connect_sync(reference()) :: {:ok, reference()} | {:error, nif_error()}
  def connect_sync(_db), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Run bidirectional sync."
  @spec sync(reference()) :: :ok | {:error, nif_error()}
  def sync(_db), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Flush and release a connection. Returns `:ok`."
  @spec close(reference()) :: :ok
  def close(_conn), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Release a local database handle. Returns `:ok`."
  @spec close_db(reference()) :: :ok
  def close_db(_db), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Release a synced database handle. Returns `:ok`."
  @spec close_sync_db(reference()) :: :ok
  def close_sync_db(_db), do: :erlang.nif_error(:nif_not_loaded)
end
