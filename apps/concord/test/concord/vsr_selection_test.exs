defmodule Concord.VSRSelectionTest do
  use ExUnit.Case, async: false

  alias Concord.Engine

  setup do
    previous =
      for key <- [:cluster_enabled, :clustering, :replication_engine], into: %{} do
        {key, Application.fetch_env(:concord, key)}
      end

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:concord, key, value)
        {key, :error} -> Application.delete_env(:concord, key)
      end)
    end)

    :ok
  end

  test "Ra remains the default engine and explicit engine options take precedence" do
    Application.delete_env(:concord, :replication_engine)

    assert Engine.engine([]) == Engine.Cluster
    assert Engine.engine(engine: :raft) == Engine.Cluster
    assert Engine.engine(engine: :vsr) == Engine.VSR
    assert Engine.module(:vsr) == Engine.VSR

    Application.put_env(:concord, :replication_engine, :vsr)

    assert Engine.engine([]) == Engine.VSR
    assert Engine.engine(engine: :raft) == Engine.Cluster
  end

  test "the default Ra application branch preserves the existing cluster children" do
    Application.put_env(:concord, :cluster_enabled, true)
    Application.put_env(:concord, :clustering, true)
    Application.delete_env(:concord, :replication_engine)

    children = Concord.Application.children()

    assert child?(children, Cluster.Supervisor)
    assert child?(children, Concord.TTL)
    assert child?(children, Concord.Sync.Dispatcher)
    assert child?(children, Concord.Sync.WatchHub)
    assert task_child?(children)
    refute child?(children, Engine.VSR.Supervisor)
  end

  test "the VSR application branch replaces only the Ra consensus runtime" do
    Application.put_env(:concord, :cluster_enabled, true)
    Application.put_env(:concord, :clustering, true)
    Application.put_env(:concord, :replication_engine, :vsr)

    children = Concord.Application.children()

    assert child?(children, Concord.TTL)
    assert child?(children, Concord.Sync.Dispatcher)
    assert child?(children, Concord.Sync.WatchHub)
    assert child?(children, Engine.VSR.Supervisor)
    refute child?(children, Cluster.Supervisor)
    refute task_child?(children)
  end

  test "disabling the cluster starts neither consensus runtime nor common cluster workers" do
    Application.put_env(:concord, :cluster_enabled, false)
    Application.put_env(:concord, :replication_engine, :vsr)

    children = Concord.Application.children()

    assert child?(children, Engine.Local)
    refute child?(children, Engine.VSR.Supervisor)
    refute child?(children, Cluster.Supervisor)
    refute child?(children, Concord.TTL)
    refute child?(children, Concord.Sync.Dispatcher)
    refute child?(children, Concord.Sync.WatchHub)
    refute task_child?(children)
  end

  defp child?(children, module) do
    Enum.any?(children, fn
      {^module, _opts} -> true
      %{start: {^module, _function, _args}} -> true
      ^module -> true
      _child -> false
    end)
  end

  defp task_child?(children) do
    Enum.any?(children, fn
      {Task, _start} -> true
      %{start: {Task, _function, _args}} -> true
      _child -> false
    end)
  end
end
