defmodule Concord.Turso do
  @moduledoc """
  Explicit Turso-backed Concord API.

  This API uses a local Turso database through `ex_turso`. It is durable and
  node-local: it does not submit writes to the Raft cluster and it does not
  replicate data to Concord cluster peers.
  """

  alias Concord.APIOptions

  @db __MODULE__.DB

  @doc false
  def child_spec(opts) do
    opts = Keyword.merge(pool_options(), opts)
    ExTurso.child_spec(opts)
  end

  @doc false
  def enabled? do
    config() |> Keyword.get(:enabled, false)
  end

  @doc false
  def pool_options do
    config = config()
    database = Keyword.get(config, :database, default_database())

    if database != ":memory:" do
      database |> Path.dirname() |> File.mkdir_p!()
    end

    [
      database: database,
      name: @db,
      pool_size: Keyword.get(config, :pool_size, 1)
    ]
    |> maybe_put(:remote_url, Keyword.get(config, :remote_url))
    |> maybe_put(:auth_token, Keyword.get(config, :auth_token))
  end

  def put(key, value, opts \\ []), do: Concord.put(key, value, APIOptions.turso(opts))
  def get(key, opts \\ []), do: Concord.get(key, APIOptions.turso(opts))
  def delete(key, opts \\ []), do: Concord.delete(key, APIOptions.turso(opts))
  def put_if(key, value, opts), do: Concord.put_if(key, value, APIOptions.turso(opts))
  def delete_if(key, opts), do: Concord.delete_if(key, APIOptions.turso(opts))
  def get_all(opts \\ []), do: Concord.get_all(APIOptions.turso(opts))
  def status(opts \\ []), do: Concord.status(APIOptions.turso(opts))
  def members(opts \\ []), do: Concord.members(APIOptions.turso(opts))

  def put_with_ttl(key, value, ttl_seconds, opts \\ []) do
    Concord.put_with_ttl(key, value, ttl_seconds, APIOptions.turso(opts))
  end

  def touch(key, additional_ttl_seconds, opts \\ []) do
    Concord.touch(key, additional_ttl_seconds, APIOptions.turso(opts))
  end

  def ttl(key, opts \\ []), do: Concord.ttl(key, APIOptions.turso(opts))
  def get_with_ttl(key, opts \\ []), do: Concord.get_with_ttl(key, APIOptions.turso(opts))
  def get_all_with_ttl(opts \\ []), do: Concord.get_all_with_ttl(APIOptions.turso(opts))
  def prefix_scan(prefix, opts \\ []), do: Concord.prefix_scan(prefix, APIOptions.turso(opts))
  def put_many(operations, opts \\ []), do: Concord.put_many(operations, APIOptions.turso(opts))

  def put_many_with_ttl(operations, ttl_seconds, opts \\ []) do
    Concord.put_many_with_ttl(operations, ttl_seconds, APIOptions.turso(opts))
  end

  def get_many(keys, opts \\ []), do: Concord.get_many(keys, APIOptions.turso(opts))
  def delete_many(keys, opts \\ []), do: Concord.delete_many(keys, APIOptions.turso(opts))

  def touch_many(operations, opts \\ []),
    do: Concord.touch_many(operations, APIOptions.turso(opts))

  def revision(opts \\ []), do: Concord.revision(APIOptions.turso(opts))
  def list(opts), do: Concord.list(APIOptions.turso(opts))
  def txn(spec, opts \\ []), do: Concord.txn(spec, APIOptions.turso(opts))

  @doc """
  Synchronizes the local Turso database with a configured remote database.
  """
  def sync(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    case Process.whereis(@db) do
      nil -> {:error, :engine_not_started}
      _pid -> ExTurso.sync(@db, timeout: timeout)
    end
  end

  defp config do
    Application.get_env(:concord, :turso, [])
  end

  defp default_database do
    Application.get_env(:concord, :data_dir, "./data")
    |> Path.join("turso.db")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
