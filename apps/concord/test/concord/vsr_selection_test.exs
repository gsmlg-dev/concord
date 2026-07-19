defmodule Concord.VSRSelectionTest do
  use ExUnit.Case, async: false

  alias Concord.Engine

  setup do
    previous_cluster_enabled = Application.fetch_env(:concord, :cluster_enabled)

    on_exit(fn ->
      restore_env(:cluster_enabled, previous_cluster_enabled)
    end)

    :ok
  end

  test "VSR is the only replicated engine and generic cluster aliases select it" do
    assert Engine.engine([]) == Engine.VSR
    assert Engine.engine(engine: :vsr) == Engine.VSR
    assert Engine.module(:viewstamped_replication) == Engine.VSR
    assert Engine.module(:cluster) == Engine.VSR
    assert Engine.module(:kv_cluster) == Engine.VSR
    assert Engine.module(:concord) == Engine.VSR
    assert Engine.engine(Concord.APIOptions.cluster(engine: :local)) == Engine.VSR
  end

  test "the cluster application branch starts the VSR runtime and common workers" do
    Application.put_env(:concord, :cluster_enabled, true)
    children = Concord.Application.children()

    assert child?(children, Concord.TTL)
    assert child?(children, Concord.Sync.Dispatcher)
    assert child?(children, Concord.Sync.WatchHub)
    assert child?(children, Engine.VSR.Supervisor)
  end

  test "disabling the cluster starts neither VSR nor common cluster workers" do
    Application.put_env(:concord, :cluster_enabled, false)
    children = Concord.Application.children()

    assert child?(children, Engine.Local)
    refute child?(children, Engine.VSR.Supervisor)
    refute child?(children, Concord.TTL)
    refute child?(children, Concord.Sync.Dispatcher)
    refute child?(children, Concord.Sync.WatchHub)
  end

  defp child?(children, module) do
    Enum.any?(children, fn
      {^module, _opts} -> true
      %{start: {^module, _function, _args}} -> true
      ^module -> true
      _child -> false
    end)
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:concord, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:concord, key)
end
