#!/usr/bin/env elixir

# Simple bulk operations benchmark runner for Concord
# Run with: mix run run_bulk_benchmarks.exs

defmodule BulkBenchmarkRunner do
  def run do
    IO.puts("🚀 Concord Bulk Operations Performance Benchmark")
    IO.puts("===============================================")
    IO.puts("")

    # Start Concord
    start_concord()

    # Test bulk operations
    test_bulk_operations()

    IO.puts("\n✅ Bulk operations benchmark completed!")
  end

  defp start_concord do
    IO.puts("🔧 Starting Concord...")
    Application.ensure_all_started(:concord)
    :timer.sleep(2000)
    :ets.delete_all_objects(:concord_store)
    IO.puts("✅ Concord ready")
  end

  defp test_bulk_operations do
    IO.puts("\n📊 Testing Bulk Operations Performance")
    IO.puts("=====================================")

    # Test different batch sizes
    batch_sizes = [10, 50, 100, 200]

    for batch_size <- batch_sizes do
      IO.puts("\nTesting batch size: #{batch_size}")

      # Prepare test data
      operations = prepare_test_data(batch_size, 100)

      # Test put_many
      put_time = benchmark_put_many(operations)
      put_per_op = put_time / batch_size
      put_throughput = Float.round(batch_size * 1_000_000 / put_time, 2)

      # Test get_many
      get_time = benchmark_get_many(Enum.map(operations, fn {key, _} -> key end))
      get_per_op = get_time / batch_size
      get_throughput = Float.round(batch_size * 1_000_000 / get_time, 2)

      # Test delete_many
      delete_time = benchmark_delete_many(Enum.map(operations, fn {key, _} -> key end))
      delete_per_op = delete_time / batch_size
      delete_throughput = Float.round(batch_size * 1_000_000 / delete_time, 2)

      IO.puts("  put_many:    #{format_time(put_time)} (#{format_time(put_per_op)} per op, #{put_throughput} ops/sec)")
      IO.puts("  get_many:    #{format_time(get_time)} (#{format_time(get_per_op)} per op, #{get_throughput} ops/sec)")
      IO.puts("  delete_many: #{format_time(delete_time)} (#{format_time(delete_per_op)} per op, #{delete_throughput} ops/sec)")

      # Compare with individual operations
      individual_put_time = benchmark_individual_puts(operations)
      individual_get_time = benchmark_individual_gets(Enum.map(operations, fn {key, _} -> key end))

      put_speedup = individual_put_time / put_time
      get_speedup = individual_get_time / get_time

      IO.puts("  vs Individual:")
      IO.puts("    put speedup:   #{Float.round(put_speedup, 2)}x")
      IO.puts("    get speedup:   #{Float.round(get_speedup, 2)}x")
    end

    # Test memory efficiency
    test_memory_efficiency()
  end

  defp test_memory_efficiency do
    IO.puts("\n💾 Memory Efficiency Test")
    IO.puts("==========================")

    test_sizes = [100, 500, 1000]

    for size <- test_sizes do
      IO.puts("\nTesting #{size} items:")

      # Clear and measure initial memory
      :ets.delete_all_objects(:concord_store)
      :erlang.garbage_collect()
      memory_before = :erlang.memory()

      # Prepare test data
      operations = prepare_test_data(size, 100)

      # Test bulk operations memory
      memory_before_bulk = :erlang.memory()
      Concord.put_many(operations)
      memory_after_bulk = :erlang.memory()

      # Clean up
      :ets.delete_all_objects(:concord_store)
      :erlang.garbage_collect()

      # Test individual operations memory
      memory_before_individual = :erlang.memory()
      for {key, value} <- operations do
        Concord.put(key, value)
      end
      memory_after_individual = :erlang.memory()

      # Calculate memory usage
      bulk_memory_used = memory_after_bulk[:total] - memory_before_bulk[:total]
      individual_memory_used = memory_after_individual[:total] - memory_before_individual[:total]

      IO.puts("  Bulk:       #{Float.round(bulk_memory_used / 1024 / 1024, 2)}MB (#{Float.round(bulk_memory_used / size, 2)} bytes per item)")
      IO.puts("  Individual: #{Float.round(individual_memory_used / 1024 / 1024, 2)}MB (#{Float.round(individual_memory_used / size, 2)} bytes per item)")

      if individual_memory_used > 0 do
        efficiency = ((individual_memory_used - bulk_memory_used) / individual_memory_used) * 100
        IO.puts("  Efficiency: #{Float.round(efficiency, 1)}% memory savings")
      end
    end
  end

  defp prepare_test_data(count, value_size) do
    for i <- 1..count do
      key = "bulk_test:#{System.unique_integer()}:#{i}"
      value = String.duplicate("x", value_size)
      {key, value}
    end
  end

  defp benchmark_put_many(operations) do
    # Warm up
    Concord.put_many(operations)
    :ets.delete_all_objects(:concord_store)

    # Benchmark
    measurements = for _i <- 1..10 do
      {time_us, _result} = :timer.tc(fn -> Concord.put_many(operations) end)
      time_us
    end

    Enum.sum(measurements) / length(measurements)
  end

  defp benchmark_get_many(keys) do
    # Ensure data exists
    operations = Enum.map(keys, fn key -> {key, "test_value"} end)
    Concord.put_many(operations)

    # Benchmark
    measurements = for _i <- 1..10 do
      {time_us, _result} = :timer.tc(fn -> Concord.get_many(keys) end)
      time_us
    end

    Enum.sum(measurements) / length(measurements)
  end

  defp benchmark_delete_many(keys) do
    # Ensure data exists
    operations = Enum.map(keys, fn key -> {key, "test_value"} end)
    Concord.put_many(operations)

    # Benchmark
    measurements = for _i <- 1..10 do
      {time_us, _result} = :timer.tc(fn -> Concord.delete_many(keys) end)
      time_us
    end

    Enum.sum(measurements) / length(measurements)
  end

  defp benchmark_individual_puts(operations) do
    # Clear data
    :ets.delete_all_objects(:concord_store)

    # Benchmark
    measurements = for _i <- 1..5 do
      {time_us, _result} = :timer.tc(fn ->
        for {key, value} <- operations do
          Concord.put(key, value)
        end
      end)
      time_us
    end

    Enum.sum(measurements) / length(measurements)
  end

  defp benchmark_individual_gets(keys) do
    # Ensure data exists
    operations = Enum.map(keys, fn key -> {key, "test_value"} end)
    Concord.put_many(operations)

    # Benchmark
    measurements = for _i <- 1..5 do
      {time_us, _result} = :timer.tc(fn ->
        for key <- keys do
          Concord.get(key)
        end
      end)
      time_us
    end

    Enum.sum(measurements) / length(measurements)
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

# Run the benchmark
BulkBenchmarkRunner.run()