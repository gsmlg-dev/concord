defmodule Concord.TestHelper do
  @moduledoc """
  Helper module for setting up test environment for Concord tests.
  """

  def start_test_cluster do
    cleanup_test_data()
    ensure_applications_started()
    restart_ra_system()

    {node_id, server_config} = setup_server_config()
    result = start_ra_server({node_id, server_config})

    handle_server_start_result(result, {node_id, server_config})
  end

  defp cleanup_test_data do
    ra_data_dir = "./nonode@nohost"
    data_dir = "./data/test_#{node()}"

    File.rm_rf!(ra_data_dir)
    File.rm_rf!(data_dir)
  end

  defp ensure_applications_started do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:ra)
  end

  defp restart_ra_system do
    try do
      :ra_system.stop_default()
    rescue
      _ -> :ok
    end

    Process.sleep(200)
    :ra_system.start_default()
    Process.sleep(100)
  end

  defp setup_server_config do
    node_id = {:concord_cluster, node()}
    cluster_name = :concord_cluster
    machine = {:module, Concord.StateMachine, %{}}

    data_dir = "./data/test_#{node()}"
    File.mkdir_p!(data_dir)

    uid = node_id |> Tuple.to_list() |> Enum.join("_") |> String.replace("@", "_")

    server_config = %{
      id: node_id,
      uid: uid,
      cluster_name: cluster_name,
      machine: machine,
      log_init_args: %{
        uid: uid,
        data_dir: data_dir
      },
      initial_members: [node_id]
    }

    {node_id, server_config}
  end

  defp start_ra_server({_node_id, server_config}) do
    :ra.start_server(server_config)
  end

  defp handle_server_start_result(result, {node_id, _server_config}) do
    case result do
      :ok ->
        :ra.trigger_election(node_id)
        wait_for_cluster_ready()

      {:ok, _} ->
        wait_for_cluster_ready()

      {:error, {:already_started, _}} ->
        wait_for_cluster_ready()

      {:error, :not_new} ->
        handle_server_already_exists(node_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_server_already_exists(node_id) do
    cleanup_existing_server(node_id)

    {node_id, server_config} = setup_server_config()

    case start_ra_server({node_id, server_config}) do
      :ok ->
        :ra.trigger_election(node_id)
        wait_for_cluster_ready()

      {:ok, _} ->
        wait_for_cluster_ready()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_existing_server(node_id) do
    try do
      :ra.stop_server(node_id)
    rescue
      _ -> :ok
    end

    Process.sleep(200)
    cleanup_test_data()
    restart_ra_system()
  end

  def stop_test_cluster do
    node_id = {:concord_cluster, node()}

    try do
      :ra.stop_server(node_id)
    rescue
      _ -> :ok
    end

    # Give it time to clean up
    Process.sleep(200)

    # Clean up any remaining ETS tables first
    try do
      :ets.delete_all_objects(:concord_store)
    rescue
      _ -> :ok
    end

    # Try to stop the ra system completely
    try do
      :ra_system.stop_default()
    rescue
      _ -> :ok
    end

    # Give it more time to shut down completely
    Process.sleep(200)

    # Clean up test data
    data_dir = "./data/test_#{node()}"
    File.rm_rf!(data_dir)

    # Clean up ra data - this is critical for clean restarts
    ra_data_dir = "./nonode@nohost"
    File.rm_rf!(ra_data_dir)

    # Double-check that ra data is gone
    if File.exists?(ra_data_dir) do
      File.rm_rf!(ra_data_dir)
    end
  end

  def wait_for_cluster_ready(timeout \\ 10_000) do
    start_time = System.monotonic_time(:millisecond)
    until = start_time + timeout
    node_id = {:concord_cluster, node()}

    case loop(until, fn ->
           case :ra.members(node_id) do
             {:ok, members, _leader} when is_list(members) ->
               # Found members and leader, cluster is ready
               :ready

             {:error, :noproc} ->
               :not_ready

             {:error, _reason} ->
               :not_ready

             _result ->
               :not_ready
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
          Process.sleep(100)
          loop(until, fun)
        else
          :timeout
        end
    end
  end
end
