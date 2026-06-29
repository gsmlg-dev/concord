defmodule Concord.Engine do
  @moduledoc """
  Storage engine boundary for Concord's public KV surface.

  `Concord` uses `Concord.Engine.Cluster` by default to preserve the current
  Raft-backed behavior. Explicit APIs such as `Concord.Local` pass a different
  engine per call.
  """

  @type command :: term()
  @type query :: term()
  @type reason :: term()

  @callback command(command(), keyword()) :: {:ok, term()} | {:error, reason()}
  @callback query(query(), keyword()) :: {:ok, term()} | {:error, reason()}
  @callback status(keyword()) :: {:ok, map()} | {:error, reason()}
  @callback members(keyword()) :: {:ok, list()} | {:error, reason()}

  @doc false
  @spec module(atom() | module()) :: module()
  def module(Concord.Engine.Cluster), do: Concord.Engine.Cluster
  def module(Concord.Engine.Local), do: Concord.Engine.Local
  def module(Concord.Engine.Turso), do: Concord.Engine.Turso
  def module(:kv_cluster), do: Concord.Engine.Cluster
  def module(:cluster), do: Concord.Engine.Cluster
  def module(:raft), do: Concord.Engine.Cluster
  def module(:raft_ets), do: Concord.Engine.Cluster
  def module(:concord), do: Concord.Engine.Cluster
  def module(:kv_local), do: Concord.Engine.Local
  def module(:local), do: Concord.Engine.Local
  def module(:ets_local), do: Concord.Engine.Local
  def module(:turso), do: Concord.Engine.Turso
  def module(module) when is_atom(module), do: module

  @spec command(command(), keyword()) :: {:ok, term()} | {:error, reason()}
  def command(command, opts \\ []) do
    engine(opts).command(command, opts)
  end

  @spec query(query(), keyword()) :: {:ok, term()} | {:error, reason()}
  def query(query, opts \\ []) do
    engine(opts).query(query, opts)
  end

  @spec status(keyword()) :: {:ok, map()} | {:error, reason()}
  def status(opts \\ []) do
    engine(opts).status(opts)
  end

  @spec members(keyword()) :: {:ok, list()} | {:error, reason()}
  def members(opts \\ []) do
    engine(opts).members(opts)
  end

  @doc false
  @spec with_engine(keyword(), atom() | module()) :: keyword()
  def with_engine(opts, engine), do: Keyword.put(opts, :engine, engine)

  @doc false
  @spec engine(keyword()) :: module()
  def engine(opts), do: opts |> Keyword.get(:engine, :kv_cluster) |> module()
end
