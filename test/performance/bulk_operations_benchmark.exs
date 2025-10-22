defmodule Concord.Performance.BulkOperationsBenchmark do
  @moduledoc """
  Comprehensive performance benchmark for Concord bulk operations.

  This benchmark tests the performance characteristics of bulk operations
  compared to individual operations, measuring throughput, latency, and
  efficiency gains across different batch sizes and data patterns.
  """

  def run_bulk_benchmarks do
    IO.puts("🚀 Concord Bulk Operations Performance Benchmark")
    IO.puts("===============================================")
    IO.puts("Testing bulk operations vs individual operations...")
    IO.puts("")

    setup_concord()

    # Test different batch sizes
    test_batch_size_performance()

    # Test different data sizes
    test_data_size_performance()

    # Test operation types
    test_operation_types_performance()

    # Test efficiency comparisons
    test_efficiency_comparison()

    # Test memory usage patterns
    test_memory_usage_patterns()

    IO.puts("\n✅ All bulk operations benchmarks completed!")
  end

  defp setup_concord do
    Application.ensure_all_started(:concord)
    :timer.sleep(1000)
    :ets.delete_all_objects(:concord_store)
    IO.puts("✅ Concord ready for bulk operations testing")
  end

  defp test_batch_size_performance do
    IO.puts("\n📊 Batch Size Performance Analysis")
    IO.puts("=================================")

    batch_sizes = [1, 5, 10, 25, 50, 100, 200, 500]
    value_size = 100  # 100 bytes per value

    for batch_size <- batch_sizes do
      IO.puts("\nTesting batch size: #{batch_size}")

      # Prepare test data
      operations = prepare_bulk_operations(batch_size, value_size)

      # Benchmark bulk operations
      bulk_time = benchmark_bulk_operations(operations, batch_size)

      # Benchmark individual operations
      individual_time = benchmark_individual_operations(operations, batch_size)

      # Calculate efficiency
      efficiency = calculate_efficiency(bulk_time, individual_time, batch_size)

      # Calculate per-operation metrics
      bulk_per_op = bulk_time / batch_size
      individual_per_op = individual_time / batch_size
      speedup = individual_per_op / bulk_per_op

      IO.puts("  Bulk operations:     #{format_time(bulk_time)} (#{format_time(bulk_per_op)} per op)")
      IO.puts("  Individual ops:      #{format_time(individual_time)} (#{format_time(individual_per_op)} per op)")
      IO.puts("  Speedup:             #{Float.round(speedup, 2)}x")
      IO.puts("  Efficiency gain:     #{Float.round(efficiency, 1)}%")
      IO.puts("  Throughput:          #{Float.round(batch_size * 1_000_000 / bulk_time, 2)} ops/sec")
    end
  end

  defp test_data_size_performance do
    IO.puts("\n💾 Data Size Performance Analysis")
    IO.puts("=================================")

    data_sizes = [10, 100, 500, 1000, 5000]  # bytes
    batch_size = 50

    for data_size <- data_sizes do
      IO.puts("\nTesting data size: #{data_size} bytes (batch of #{batch_size})")

      operations = prepare_bulk_operations(batch_size, data_size)

      # Test put_many
      put_time = benchmark_put_many(operations)

      # Test get_many
      # First put the data
      Concord.put_many(operations)
      get_time = benchmark_get_many(Enum.map(operations, fn {key, _} -> key end))

      # Test delete_many
      delete_time = benchmark_delete_many(Enum.map(operations, fn {key, _} -> key end))

      total_time = put_time + get_time + delete_time

      IO.puts("  put_many:  #{format_time(put_time)} (#{format_time(put_time / batch_size)} per op)")
      IO.puts("  get_many:  #{format_time(get_time)} (#{format_time(get_time / batch_size)} per op)")
      IO.puts("  delete_many: #{format_time(delete_time)} (#{format_time(delete_time / batch_size)} per op)")
      IO.puts("  Total:     #{format_time(total_time)} (#{format_time(total_time / (batch_size * 3))} per op)")
      IO.puts("  Throughput: #{Float.round(batch_size * 3 * 1_000_000 / total_time, 2)} ops/sec")
    end
  end

  defp test_operation_types_performance do
    IO.puts("\n🔄 Operation Types Performance Analysis")
    IO.puts("=====================================")

    batch_size = 100
    operations = prepare_bulk_operations(batch_size, 200)
    keys = Enum.map(operations, fn {key, _} -> key end)

    # Put data first
    Concord.put_many(operations)

    # Prepare touch operations
    touch_operations = Enum.map(keys, fn key -> {key, 3600} end)

    operation_tests = [
      {"put_many", fn -> Concord.put_many(operations) end},
      {"get_many", fn -> Concord.get_many(keys) end},
      {"delete_many", fn -> Concord.delete_many(keys) end},
      {"touch_many", fn -> Concord.touch_many(touch_operations) end},
      {"put_many_with_ttl", fn -> Concord.put_many_with_ttl(operations, 3600) end}
    ]

    for {op_name, op_function} <- operation_tests do
      IO.puts("\nTesting #{op_name}:")

      # Prepare data if needed
      if op_name == "put_many" or op_name == "put_many_with_ttl" do
        :ets.delete_all_objects(:concord_store)
      end

      if op_name == "get_many" or op_name == "delete_many" or op_name == "touch_many" do
        if :ets.info(:concord_store, :size) == 0 do
          Concord.put_many(operations)
        end
      end

      # Benchmark
      measurements = for _i <- 1..50 do
        {time_us, _result} = :timer.tc(op_function)
        time_us
      end

      avg_time = Enum.sum(measurements) / length(measurements)
      min_time = Enum.min(measurements)
      max_time = Enum.max(measurements)
      ops_per_sec = Float.round(batch_size * 1_000_000 / avg_time, 2)
      per_op_time = avg_time / batch_size

      IO.puts("  Average:    #{format_time(avg_time)} (#{format_time(per_op_time)} per op)")
      IO.puts("  Range:      #{format_time(min_time)} - #{format_time(max_time)}")
      IO.puts("  Throughput: #{ops_per_sec} ops/sec")
    end
  end

  defp test_efficiency_comparison do
    IO.puts("\n⚡ Efficiency Comparison Analysis")
    IO.puts("===============================")

    test_scenarios = [
      {"Small batch (5 ops)", 5},
      {"Medium batch (50 ops)", 50},
      {"Large batch (200 ops)", 200}
    ]

    for {scenario_name, batch_size} <- test_scenarios do
      IO.puts("\n#{scenario_name}:")

      operations = prepare_bulk_operations(batch_size, 150)

      # Test bulk vs individual for each operation type
      comparisons = [
        {"put", fn op -> Concord.put(elem(op, 0), elem(op, 1)) end,
         fn ops -> Concord.put_many(ops) end},
        {"get", fn key -> Concord.get(key) end,
         fn keys -> Concord.get_many(keys) end}
      ]

      for {op_type, individual_fn, bulk_fn} <- comparisons do
        # Put data first if testing get
        if op_type == "get" do
          :ets.delete_all_objects(:concord_store)
          Concord.put_many(operations)
        end

        # Benchmark individual operations
        individual_time = benchmark_individual_operations(operations, batch_size, individual_fn)

        # Benchmark bulk operations
        bulk_time = benchmark_bulk_operations(operations, batch_size, bulk_fn)

        # Calculate metrics
        speedup = individual_time / bulk_time
        efficiency_gain = ((individual_time - bulk_time) / individual_time) * 100

        IO.puts("  #{op_type}:")
        IO.puts("    Individual: #{format_time(individual_time)} (#{format_time(individual_time / batch_size)} per op)")
        IO.puts("    Bulk:       #{format_time(bulk_time)} (#{format_time(bulk_time / batch_size)} per op)")
        IO.puts("    Speedup:    #{Float.round(speedup, 2)}x")
        IO.puts("    Efficiency: #{Float.round(efficiency_gain, 1)}% gain")
      end
    end
  end

  defp test_memory_usage_patterns do
    IO.puts("\n🧠 Memory Usage Patterns Analysis")
    IO.puts("=================================")

    # Test memory efficiency with bulk operations
    test_sizes = [100, 500, 1000, 2000]

    for size <- test_sizes do
      IO.puts("\nTesting #{size} operations:")

      # Clear and measure initial memory
      :ets.delete_all_objects(:concord_store)
      :erlang.garbage_collect()
      initial_memory = :erlang.memory()

      # Prepare and execute bulk operations
      operations = prepare_bulk_operations(size, 100)

      memory_before_bulk = :erlang.memory()
      Concord.put_many(operations)
      memory_after_bulk = :erlang.memory()

      # Test individual operations comparison
      :ets.delete_all_objects(:concord_store)
      :erlang.garbage_collect()

      memory_before_individual = :erlang.memory()
      for {key, value} <- operations do
        Concord.put(key, value)
      end
      memory_after_individual = :erlang.memory()

      # Calculate memory usage
      bulk_memory_used = memory_after_bulk[:total] - memory_before_bulk[:total]
      individual_memory_used = memory_after_individual[:total] - memory_before_individual[:total]

      memory_per_item_bulk = bulk_memory_used / size
      memory_per_item_individual = individual_memory_used / size
      memory_efficiency = ((individual_memory_used - bulk_memory_used) / individual_memory_used) * 100

      IO.puts("  Bulk operations:")
      IO.puts("    Total memory: #{format_memory(memory_after_bulk)}")
      IO.puts("    Memory used:  #{Float.round(bulk_memory_used / 1024 / 1024, 2)}MB")
      IO.puts("    Per item:     #{Float.round(memory_per_item_bulk, 2)} bytes")

      IO.puts("  Individual operations:")
      IO.puts("    Total memory: #{format_memory(memory_after_individual)}")
      IO.puts("    Memory used:  #{Float.round(individual_memory_used / 1024 / 1024, 2)}MB")
      IO.puts("    Per item:     #{Float.round(memory_per_item_individual, 2)} bytes")

      IO.puts("  Memory efficiency: #{Float.round(memory_efficiency, 1)}% improvement")
    end
  end

  # Helper functions

  defp prepare_bulk_operations(count, value_size) do
    for i <- 1..count do
      key = "bulk_test:#{System.unique_integer()}:#{i}"
      value = String.duplicate("x", value_size)
      {key, value}
    end
  end

  defp benchmark_bulk_operations(operations, batch_size, operation_fn \\ nil) do
    operation_fn = operation_fn || fn ops -> Concord.put_many(ops) end

    # Warm up
    operation_fn.(operations)
    :ets.delete_all_objects(:concord_store)

    # Benchmark
    measurements = for _i <- 1..20 do
      {time_us, _result} = :timer.tc(fn -> operation_fn.(operations) end)
      time_us
    end

    Enum.sum(measurements) / length(measurements)
  end

  defp benchmark_individual_operations(operations, batch_size, operation_fn \\ nil) do
    operation_fn = operation_fn || fn {key, value} -> Concord.put(key, value) end

    # Warm up
    for op <- operations do
      operation_fn.(op)
    end
    :ets.delete_all_objects(:concord_store)

    # Benchmark
    measurements = for _i <- 1..10 do
      {time_us, _result} = :timer.tc(fn ->
        for op <- operations do
          operation_fn.(op)
        end
      end)
      time_us
    end

    Enum.sum(measurements) / length(measurements)
  end

  defp benchmark_put_many(operations) do
    measurements = for _i <- 1..20 do
      {time_us, _result} = :timer.tc(fn -> Concord.put_many(operations) end)
      time_us
    end
    Enum.sum(measurements) / length(measurements)
  end

  defp benchmark_get_many(keys) do
    measurements = for _i <- 1..20 do
      {time_us, _result} = :timer.tc(fn -> Concord.get_many(keys) end)
      time_us
    end
    Enum.sum(measurements) / length(measurements)
  end

  defp benchmark_delete_many(keys) do
    measurements = for _i <- 1..20 do
      {time_us, _result} = :timer.tc(fn -> Concord.delete_many(keys) end)
      time_us
    end
    Enum.sum(measurements) / length(measurements)
  end

  defp calculate_efficiency(bulk_time, individual_time, batch_size) do
    if individual_time > 0 do
      ((individual_time - bulk_time) / individual_time) * 100
    else
      0
    end
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

  defp format_memory(memory) do
    total_mb = Float.round(memory[:total] / (1024 * 1024), 2)
    ets_mb = Float.round(memory[:ets] / (1024 * 1024), 2)
    processes_mb = Float.round(memory[:processes] / (1024 * 1024), 2)

    "Total: #{total_mb}MB, ETS: #{ets_mb}MB, Processes: #{processes_mb}MB"
  end
end