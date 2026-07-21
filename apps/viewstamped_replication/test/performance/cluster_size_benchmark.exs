defmodule ViewstampedReplication.Performance.ClusterSizeBenchmark do
  use ExUnit.Case, async: false

  alias ViewstampedReplication.{Client, Configuration, Member}
  alias ViewstampedReplication.Test.RegisterStateMachine

  @moduletag :performance

  test "measures concurrent command performance for one through six replicas" do
    client_count = positive_env("VSR_BENCHMARK_CLIENTS", 4)
    operations_per_client = positive_env("VSR_BENCHMARK_OPERATIONS_PER_CLIENT", 100)

    results =
      for replica_count <- 1..6 do
        benchmark_group(replica_count, client_count, operations_per_client)
      end

    print_results(results, client_count)
    assert_thresholds(results)

    assert Enum.map(results, & &1.replica_count) == Enum.to_list(1..6)
  end

  defp benchmark_group(replica_count, client_count, operations_per_client) do
    group_id = {:performance, replica_count, System.unique_integer([:positive])}
    members = members(group_id, replica_count)

    start_replicas(group_id, members)

    on_exit(fn ->
      for replica_id <- 1..replica_count do
        ViewstampedReplication.stop_replica(group_id, replica_id)
      end
    end)

    try do
      clients = start_clients(group_id, members, client_count)
      warm_up(group_id, clients)

      {elapsed_us, worker_results} =
        :timer.tc(fn ->
          clients
          |> Enum.with_index(1)
          |> Task.async_stream(
            fn {client, client_number} ->
              for operation_number <- 1..operations_per_client do
                :timer.tc(fn ->
                  ViewstampedReplication.command(
                    group_id,
                    {:write, {client_number, operation_number}},
                    client: client,
                    timeout: 5_000
                  )
                end)
              end
            end,
            max_concurrency: client_count,
            ordered: false,
            timeout: :infinity
          )
          |> Enum.to_list()
        end)

      measurements =
        Enum.flat_map(worker_results, fn
          {:ok, client_measurements} -> client_measurements
          {:exit, reason} -> flunk("benchmark client exited: #{inspect(reason)}")
        end)

      assert Enum.all?(measurements, fn {_latency_us, result} -> result == {:ok, :ok} end)

      latencies = Enum.map(measurements, &elem(&1, 0)) |> Enum.sort()
      operation_count = client_count * operations_per_client

      %{
        replica_count: replica_count,
        quorum_size: div(replica_count, 2) + 1,
        operation_count: operation_count,
        operations_per_second: operation_count * 1_000_000 / max(elapsed_us, 1),
        p50_us: percentile(latencies, 0.50),
        p95_us: percentile(latencies, 0.95),
        p99_us: percentile(latencies, 0.99)
      }
    after
      for replica_id <- 1..replica_count do
        ViewstampedReplication.stop_replica(group_id, replica_id)
      end
    end
  end

  defp start_replicas(group_id, members) do
    for %Member{id: replica_id} <- members do
      configuration =
        Configuration.new!(
          group_id: group_id,
          replica_id: replica_id,
          members: members
        )

      assert {:ok, _pid} =
               ViewstampedReplication.start_replica(
                 configuration: configuration,
                 state_machine: RegisterStateMachine,
                 bootstrap: true
               )
    end
  end

  defp start_clients(group_id, members, client_count) do
    for client_number <- 1..client_count do
      client_id = {:performance_client, group_id, client_number}

      start_supervised!(%{
        id: {Client, client_id},
        start:
          {Client, :start_link,
           [
             [
               group_id: group_id,
               client_id: client_id,
               replicas: members,
               retry_timeout: 20
             ]
           ]}
      })
    end
  end

  defp warm_up(group_id, clients) do
    for {client, client_number} <- Enum.with_index(clients, 1) do
      assert {:ok, :ok} =
               ViewstampedReplication.command(
                 group_id,
                 {:write, {:warm_up, client_number}},
                 client: client,
                 timeout: 5_000
               )
    end
  end

  defp members(group_id, replica_count) do
    for replica_id <- 1..replica_count do
      %Member{id: replica_id, endpoint: {:local, group_id, replica_id}}
    end
  end

  defp percentile(sorted_values, percentile) do
    index = ceil(length(sorted_values) * percentile) - 1
    Enum.at(sorted_values, max(index, 0))
  end

  defp print_results(results, client_count) do
    IO.puts("\nVSR local-memory command benchmark (#{client_count} concurrent clients)")
    IO.puts("replicas quorum operations ops/sec p50-us p95-us p99-us")

    for result <- results do
      IO.puts(
        Enum.join(
          [
            result.replica_count,
            result.quorum_size,
            result.operation_count,
            round(result.operations_per_second),
            result.p50_us,
            result.p95_us,
            result.p99_us
          ],
          " "
        )
      )
    end
  end

  defp assert_thresholds(results) do
    if minimum_ops = optional_number_env("VSR_BENCHMARK_MIN_OPS_PER_SECOND") do
      assert Enum.all?(results, &(&1.operations_per_second >= minimum_ops)),
             "at least one cluster size fell below #{minimum_ops} ops/sec"
    end

    if maximum_p99 = optional_number_env("VSR_BENCHMARK_MAX_P99_US") do
      assert Enum.all?(results, &(&1.p99_us <= maximum_p99)),
             "at least one cluster size exceeded #{maximum_p99}us p99 latency"
    end
  end

  defp positive_env(name, default) do
    case Integer.parse(System.get_env(name, "")) do
      {value, ""} when value > 0 -> value
      _invalid -> default
    end
  end

  defp optional_number_env(name) do
    case Float.parse(System.get_env(name, "")) do
      {value, ""} when value > 0 -> value
      _invalid -> nil
    end
  end
end
