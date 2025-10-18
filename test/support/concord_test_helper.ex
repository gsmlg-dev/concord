defmodule Concord.TestHelper do
  @moduledoc """
  Helper module for setting up test environment for Concord tests.
  """

  def start_test_cluster do
    # Clean up any existing ra data to ensure fresh start
    ra_data_dir = "./nonode@nohost"
    File.rm_rf!(ra_data_dir)

    # Also clean the test data directory
    data_dir = "./data/test_#{node()}"
    File.rm_rf!(data_dir)

    # Ensure required applications are started
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:ra)

    # Stop and restart the ra system for a clean state
    try do
      :ra_system.stop_default()
    rescue
      _ -> :ok
    end

    # Increased sleep time
    Process.sleep(200)
    :ra_system.start_default()

    # Wait for RA system to be fully ready
    Process.sleep(100)

    # Start the cluster manually for tests
    node_id = {:concord_cluster, node()}
    cluster_name = :concord_cluster
    machine = {:module, Concord.StateMachine, %{}}

    data_dir = "./data/test_#{node()}"
    File.mkdir_p!(data_dir)

    # Create a proper uid from the node tuple
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

    IO.inspect(node_id, label: "Starting RA server")
    result = :ra.start_server(server_config)
    IO.inspect(result, label: "RA start_server result")

    case result do
      :ok ->
        :ra.trigger_election(node_id)
        wait_for_cluster_ready()

      {:ok, _} ->
        wait_for_cluster_ready()

      {:error, {:already_started, _}} ->
        wait_for_cluster_ready()

      {:error, :not_new} ->
        # Server already exists, try to get it running properly
        # First stop any existing server, then restart it
        try do
          :ra.stop_server(node_id)
        rescue
          _ -> :ok
        end

        # Give it time to clean up
        Process.sleep(200)

        # Force cleanup of RA data again
        ra_data_dir = "./nonode@nohost"
        File.rm_rf!(ra_data_dir)

        # Stop and restart RA system completely
        try do
          :ra_system.stop_default()
        rescue
          _ -> :ok
        end

        Process.sleep(200)
        :ra_system.start_default()
        Process.sleep(100)

        # Try starting again with fresh config
        case :ra.start_server(server_config) do
          :ok ->
            :ra.trigger_election(node_id)
            wait_for_cluster_ready()

          {:ok, _} ->
            wait_for_cluster_ready()

          {:error, reason} ->
            IO.inspect(reason, label: "Failed to restart server after full cleanup")
            {:error, reason}
        end

      {:error, reason} ->
        IO.inspect(reason, label: "Failed to start server")
        {:error, reason}
    end
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
             {:ok, members, leader} when is_list(members) ->
               # Found members and leader, cluster is ready
               IO.inspect({:ready, length(members), leader}, label: "Cluster ready")
               :ready

             {:error, :noproc} ->
               :not_ready

             {:error, reason} ->
               IO.inspect({:error, reason}, label: "RA error")
               :not_ready

             result ->
               IO.inspect(result, label: "RA members result")
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
