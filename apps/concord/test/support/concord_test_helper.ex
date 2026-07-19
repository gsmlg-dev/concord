defmodule Concord.TestHelper do
  @moduledoc """
  Helper module for running Concord tests against an isolated singleton VSR
  cluster.
  """

  alias Concord.Engine.VSR

  @supervisor_key {__MODULE__, :supervisor}

  def start_test_cluster do
    stop_test_cluster()
    {:ok, _started} = Application.ensure_all_started(:viewstamped_replication)

    group_id = {:concord_test, System.unique_integer([:positive, :monotonic])}

    opts = [
      group_id: group_id,
      replica_id: 1,
      members: [%{id: 1, endpoint: {:local_test_endpoint, group_id}}],
      transport: :local,
      storage: :memory,
      bootstrap: true,
      retry_timeout: 10,
      client_id: {:concord_test_client, group_id}
    ]

    Application.put_env(:concord, :vsr, opts)

    with {:ok, supervisor} <- VSR.Supervisor.start_link(opts) do
      Process.unlink(supervisor)
      :persistent_term.put(@supervisor_key, supervisor)
      wait_for_cluster_ready()
    end
  end

  def stop_test_cluster do
    stored_supervisor = :persistent_term.get(@supervisor_key, nil)
    stop_supervisor(stored_supervisor)

    case Process.whereis(VSR.Supervisor) do
      ^stored_supervisor -> :ok
      supervisor -> stop_supervisor(supervisor)
    end
  after
    :persistent_term.erase(@supervisor_key)
    clear_materialized_views()
  end

  def wait_for_cluster_ready(timeout \\ 10_000) do
    until = System.monotonic_time(:millisecond) + timeout

    case loop(until, fn ->
           case VSR.status() do
             {:ok, %{cluster: %{status: :normal}}} -> :ready
             _result -> :not_ready
           end
         end) do
      :ok -> :ok
      :timeout -> {:error, :timeout}
    end
  end

  defp loop(until, fun) do
    case fun.() do
      :ready ->
        :ok

      :not_ready ->
        if System.monotonic_time(:millisecond) < until do
          Process.sleep(10)
          loop(until, fun)
        else
          :timeout
        end
    end
  end

  defp clear_materialized_views do
    Enum.each(:ets.all(), fn table ->
      if materialized_view?(table) do
        try do
          :ets.delete_all_objects(table)
        rescue
          ArgumentError -> :ok
        end
      end
    end)
  end

  defp materialized_view?(table) when is_atom(table) do
    name = Atom.to_string(table)

    table in [:concord_store, :concord_current, :concord_history, :concord_leases] or
      String.starts_with?(name, "concord_index_")
  end

  defp materialized_view?(_table), do: false

  defp stop_supervisor(supervisor) when is_pid(supervisor) do
    if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
  catch
    :exit, _reason -> :ok
  end

  defp stop_supervisor(_supervisor), do: :ok
end
