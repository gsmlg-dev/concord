defmodule Concord.Performance.RaftConsensusBenchmark do
  @moduledoc """
  Raft consensus performance benchmark for Concord.

  This benchmark tests the performance characteristics of Raft consensus
  operations, including leader election, log replication, and cluster coordination.
  """

  def run_raft_benchmarks do
    IO.puts("🚀 Concord Raft Consensus Performance Benchmark")
    IO.puts("==============================================")
    IO.puts("Testing Raft consensus performance characteristics...")
    IO.puts("")

    setup_concord()

    # Test consensus overhead
    test_consensus_overhead()

    # Test leader performance
    test_leader_performance()

    # Test log replication
    test_log_replication()

    # Test cluster coordination
    test_cluster_coordination()

    IO.puts("\n✅ All Raft consensus benchmarks completed!")
  end

  defp setup_concord do
    Application.ensure_all_started(:concord)
    :timer.sleep(2000)
    :ets.delete_all_objects(:concord_store)
    IO.puts("✅ Concord ready for Raft testing")
  end

  defp test_consensus_overhead do
    IO.puts("\n📊 Raft Consensus Overhead Analysis")
    IO.puts("===================================")

    # Compare direct ETS vs Raft operations
    test_count = 1000

    # Test direct ETS operations (baseline)
    ets_time = benchmark_direct_ets(test_count)

    # Test Raft operations
    raft_time = benchmark_raft_operations(test_count)

    overhead = raft_time - ets_time
    overhead_percentage = (overhead / ets_time) * 100

    IO.puts("Direct ETS operations (#{test_count} ops):")
    IO.puts("  Total time:       #{format_time(ets_time)}")
    IO.puts("  Avg per operation: #{format_time(ets_time / test_count)}")
    IO.puts("  Throughput:       #{Float.round(test_count * 1_000_000 / ets_time, 2)} ops/sec")

    IO.puts("Raft operations (#{test_count} ops):")
    IO.puts("  Total time:       #{format_time(raft_time)}")
    IO.puts("  Avg per operation: #{format_time(raft_time / test_count)}")
    IO.puts("  Throughput:       #{Float.round(test_count * 1_000_000 / raft_time, 2)} ops/sec")

    IO.puts("Consensus overhead:")
    IO.puts("  Additional time:   #{format_time(overhead)}")
    IO.puts("  Overhead %:        #{Float.round(overhead_percentage, 1)}%")
    IO.puts("  Slowdown factor:   #{Float.round(raft_time / ets_time, 2)}x")
  end

  defp test_leader_performance do
    IO.puts("\n👑 Raft Leader Performance Test")
    IO.puts("==============================")

    # Test different operation types on leader
    operations = [
      {"put operations", fn ->
        Concord.put("leader_test:#{System.unique_integer()}", "test_value")
      end},
      {"get operations", fn ->
        key = "leader_test:get:#{:rand.uniform(100)}"
        Concord.put(key, "test_value")  # Ensure key exists
        Concord.get(key)
      end},
      {"delete operations", fn ->
        key = "leader_test:delete:#{System.unique_integer()}"
        Concord.put(key, "test_value")  # Ensure key exists
        Concord.delete(key)
      end},
      {"TTL operations", fn ->
        key = "leader_test:ttl:#{System.unique_integer()}"
        Concord.put(key, "test_value", [ttl: 3600])
        Concord.touch(key, 7200)
      end}
    ]

    for {op_name, op_function} <- operations do
      IO.puts("\nTesting #{op_name}:")

      # Warm up
      for _i <- 1..10 do
        op_function.()
      end

      # Benchmark
      measurements = for _i <- 1..100 do
        {time_us, _result} = :timer.tc(op_function)
        time_us
      end

      avg_time = Enum.sum(measurements) / length(measurements)
      min_time = Enum.min(measurements)
      max_time = Enum.max(measurements)
      throughput = 1_000_000 / avg_time

      IO.puts("  Average: #{format_time(avg_time)}")
      IO.puts("  Range:   #{format_time(min_time)} - #{format_time(max_time)}")
      IO.puts("  Throughput: #{Float.round(throughput, 2)} ops/sec")
    end
  end

  defp test_log_replication do
    IO.puts("\n📝 Raft Log Replication Test")
    IO.puts("===========================")

    # Test different data sizes for log replication
    data_sizes = [100, 1000, 5000, 10000]  # bytes

    for data_size <- data_sizes do
      IO.puts("\nTesting log replication with #{data_size}-byte values:")

      test_data = String.duplicate("x", data_size)

      # Test single operation
      single_time = benchmark_single_replication(test_data)

      # Test batch operations
      batch_time = benchmark_batch_replication(test_data, 10)

      # Calculate efficiency
      batch_per_op = batch_time / 10
      efficiency = ((single_time * 10 - batch_time) / (single_time * 10)) * 100

      IO.puts("  Single operation: #{format_time(single_time)}")
      IO.puts("  Batch (10 ops):  #{format_time(batch_time)} (#{format_time(batch_per_op)} per op)")
      IO.puts("  Efficiency gain:  #{Float.round(efficiency, 1)}%")
      IO.puts("  Throughput:       #{Float.round(1_000_000 / batch_per_op, 2)} ops/sec")
    end
  end

  defp test_cluster_coordination do
    IO.puts("\n🔄 Cluster Coordination Test")
    IO.puts("===========================")

    # Test cluster status and coordination
    test_cluster_status()
    test_consistency_verification()
    test_recovery_simulation()
  end

  defp test_cluster_status do
    IO.puts("\nCluster Status Information:")

    # Get current cluster information
    case Concord.status() do
      {:ok, status} ->
        IO.puts("  Cluster healthy: #{status[:healthy]}")
        IO.puts("  Leader: #{status[:leader]}")
        IO.puts("  Term: #{status[:term]}")
        IO.puts("  Nodes: #{inspect(status[:nodes])}")
        IO.puts("  Log index: #{status[:log_index]}")
        IO.puts("  Commit index: #{status[:commit_index]}")
      {:error, reason} ->
        IO.puts("  Error getting status: #{inspect(reason)}")
    end
  end

  defp test_consistency_verification do
    IO.puts("\nConsistency Verification Test:")

    # Write test data and verify consistency
    test_keys = for i <- 1..10 do
      key = "consistency_test:#{i}"
      value = "test_value_#{i}_#{System.unique_integer()}"
      Concord.put(key, value)
      {key, value}
    end

    # Verify all data is consistent
    consistent_count = for {key, expected_value} <- test_keys do
      case Concord.get(key) do
        {:ok, ^expected_value} -> 1
        _ -> 0
      end
    end

    total_consistent = Enum.sum(consistent_count)
    consistency_rate = (total_consistent / length(test_keys)) * 100

    IO.puts("  Keys tested: #{length(test_keys)}")
    IO.puts("  Consistent reads: #{total_consistent}")
    IO.puts("  Consistency rate: #{Float.round(consistency_rate, 1)}%")
  end

  defp test_recovery_simulation do
    IO.puts("\nRecovery Simulation Test:")

    # Simulate recovery scenarios
    test_data = for i <- 1..50 do
      {"recovery_test:#{i}", "value_#{i}"}
    end

    # Write test data
    write_time = benchmark_batch_write(test_data)

    # Simulate recovery by reading back all data
    recovery_time = benchmark_recovery_read(test_data)

    recovery_rate = (length(test_data) * 1_000_000) / recovery_time

    IO.puts("  Write time (50 ops): #{format_time(write_time)}")
    IO.puts("  Recovery time (50 ops): #{format_time(recovery_time)}")
    IO.puts("  Recovery throughput: #{Float.round(recovery_rate, 2)} ops/sec")
  end

  # Benchmark helper functions

  defp benchmark_direct_ets(count) do
    table = :ets.new(:benchmark_test, [:set, :public])

    {time_us, _} = :timer.tc(fn ->
      for i <- 1..count do
        key = "ets_test:#{i}"
        value = "ets_value_#{i}"
        :ets.insert(table, {key, value})
      end
    end)

    :ets.delete(table)
    time_us
  end

  defp benchmark_raft_operations(count) do
    {time_us, _} = :timer.tc(fn ->
      for i <- 1..count do
        key = "raft_test:#{i}"
        value = "raft_value_#{i}"
        Concord.put(key, value)
      end
    end)

    time_us
  end

  defp benchmark_single_replication(test_data) do
    # Warm up
    Concord.put("warmup", "warmup_value")

    measurements = for _i <- 1..20 do
      {time_us, _result} = :timer.tc(fn ->
        Concord.put("single_test:#{System.unique_integer()}", test_data)
      end)
      time_us
    end

    Enum.sum(measurements) / length(measurements)
  end

  defp benchmark_batch_replication(test_data, batch_size) do
    operations = for i <- 1..batch_size do
      {"batch_test:#{i}:#{System.unique_integer()}", test_data}
    end

    # Warm up
    Concord.put_many([{"warmup", "warmup_value"}])

    measurements = for _i <- 1..10 do
      {time_us, _result} = :timer.tc(fn ->
        Concord.put_many(operations)
      end)
      time_us
    end

    Enum.sum(measurements) / length(measurements)
  end

  defp benchmark_batch_write(operations) do
    {time_us, _result} = :timer.tc(fn ->
      Concord.put_many(operations)
    end)
    time_us
  end

  defp benchmark_recovery_read(operations) do
    keys = Enum.map(operations, fn {key, _} -> key end)

    {time_us, _result} = :timer.tc(fn ->
      for key <- keys do
        Concord.get(key)
      end
    end)
    time_us
  end

  defp format_time(microseconds) when microseconds < 1000 do
    "#{Float.round(microseconds, 2)}μs"
  end

  defp format_time(microseconds) when microseconds < 1_000_000 do
    "#{Float.round(microseconds / 1000, 2)}ms"
  end

  defp format_time(microseconds) do
    "#{Float.round(microseconds / 1_000_000, 2)}s"
  end
end