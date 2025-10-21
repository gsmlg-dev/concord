defmodule Concord.Performance.KVOperationsBenchmark do
  @moduledoc """
  Performance benchmarks for Concord core KV operations.

  These benchmarks test Concord as an embedded database within Elixir applications,
  focusing on realistic usage patterns for embedded distributed systems.
  """

  # Use Benchee for comprehensive benchmarking
  # Add to mix.exs: {:benchee, "~> 1.1", only: :dev}

  def run_all_benchmarks do
    IO.puts("🚀 Starting Concord Performance Benchmarks")
    IO.puts("=====================================")
    IO.puts("Testing Concord as embedded Elixir database...")
    IO.puts("")

    # Start Concord in embedded mode
    setup_concord()

    # Run different benchmark categories
    run_basic_kv_benchmarks()
    run_bulk_operation_benchmarks()
    run_ttl_benchmarks()
    run_concurrent_access_benchmarks()
    run_memory_usage_benchmarks()

    IO.puts("\n✅ All benchmarks completed!")
  end

  defp setup_concord do
    Application.ensure_all_started(:concord)

    # Wait for cluster to be ready
    :timer.sleep(1000)

    # Clear any existing data
    :ets.delete_all_objects(:concord_store)

    IO.puts("✅ Concord cluster ready for benchmarking")
  end

  def run_basic_kv_benchmarks do
    IO.puts("\n📊 Basic KV Operations Benchmark")
    IO.puts("===============================")

    # Small values (typical configuration data)
    benchee_run(%{
      "put_small_value" => fn ->
        Concord.put("bench:small:#{:erlang.unique_integer()}", "small_value_#{System.unique_integer()}")
      end,
      "get_small_value" => fn ->
        # Pre-populate test data
        key = "bench:get:small:#{System.unique_integer()}"
        Concord.put(key, "small_value")
        Concord.get(key)
      end,
      "delete_small_value" => fn ->
        key = "bench:delete:small:#{System.unique_integer()}"
        Concord.put(key, "small_value")
        Concord.delete(key)
      end
    }, "Small Values (config, flags, counters)")

    # Medium values (user sessions, API responses)
    medium_value = Jason.encode!(%{
      user_id: System.unique_integer(),
      session_data: "x" |> String.duplicate(100),
      metadata: %{timestamp: DateTime.utc_now(), ip: "192.168.1.100"}
    })

    benchee_run(%{
      "put_medium_value" => fn ->
        Concord.put("bench:medium:#{:erlang.unique_integer()}", medium_value)
      end,
      "get_medium_value" => fn ->
        key = "bench:get:medium:#{System.unique_integer()}"
        Concord.put(key, medium_value)
        Concord.get(key)
      end
    }, "Medium Values (sessions, API responses)")

    # Large values (documents, cached data)
    large_value = "x" |> String.duplicate(10_000)

    benchee_run(%{
      "put_large_value" => fn ->
        Concord.put("bench:large:#{:erlang.unique_integer()}", large_value)
      end,
      "get_large_value" => fn ->
        key = "bench:get:large:#{System.unique_integer()}"
        Concord.put(key, large_value)
        Concord.get(key)
      end
    }, "Large Values (documents, cache)")
  end

  def run_bulk_operation_benchmarks do
    IO.puts("\n📦 Bulk Operations Benchmark")
    IO.puts("===========================")

    # Small batches (typical application operations)
    small_operations = for i <- 1..10 do
      %{"key" => "bulk:small:#{i}", "value" => "bulk_value_#{i}"}
    end

    benchee_run(%{
      "bulk_put_10_items" => fn ->
        Concord.put_many(small_operations)
      end
    }, "Small Bulk Operations (10 items)")

    # Medium batches (bulk data loading)
    medium_operations = for i <- 1..100 do
      %{"key" => "bulk:medium:#{i}", "value" => %{"data" => "value_#{i}", "index" => i}}
    end

    benchee_run(%{
      "bulk_put_100_items" => fn ->
        Concord.put_many(medium_operations)
      end
    }, "Medium Bulk Operations (100 items)")

    # Large batches (data import/export)
    large_operations = for i <- 1..500 do
      %{"key" => "bulk:large:#{i}", "value" => "large_value_#{i}"}
    end

    benchee_run(%{
      "bulk_put_500_items" => fn ->
        Concord.put_many(large_operations)
      end
    }, "Large Bulk Operations (500 items - max limit)")

    # Bulk get operations
    keys = for i <- 1..100, do: "bulk:get:#{i}"
    # Pre-populate data
    for key <- keys do
      Concord.put(key, "pre_populated_value")
    end

    benchee_run(%{
      "bulk_get_100_items" => fn ->
        Concord.get_many(keys)
      end
    }, "Bulk Get Operations (100 items)")
  end

  def run_ttl_benchmarks do
    IO.puts("\n⏰ TTL Operations Benchmark")
    IO.puts("===========================")

    benchee_run(%{
      "put_with_ttl" => fn ->
        Concord.put("bench:ttl:#{:erlang.unique_integer()}", "ttl_value", [ttl: 3600])
      end,
      "touch_extend_ttl" => fn ->
        key = "bench:touch:#{System.unique_integer()}"
        Concord.put(key, "value", [ttl: 300])
        Concord.touch(key, 3600)
      end,
      "get_ttl_value" => fn ->
        key = "bench:get_ttl:#{System.unique_integer()}"
        Concord.put(key, "value", [ttl: 3600])
        Concord.get_with_ttl(key)
      end,
      "get_ttl_only" => fn ->
        key = "bench:ttl_only:#{System.unique_integer()}"
        Concord.put(key, "value", [ttl: 3600])
        Concord.ttl(key)
      end
    }, "TTL Operations")
  end

  def run_concurrent_access_benchmarks do
    IO.puts("\n🔀 Concurrent Access Benchmark")
    IO.puts("=============================")

    # Test concurrent writes (multiple processes writing to different keys)
    benchee_run(%{
      "concurrent_writes_10_processes" => fn ->
        tasks = for i <- 1..10 do
          Task.async(fn ->
            for j <- 1..10 do
              Concord.put("concurrent:write:#{i}:#{j}", "value_#{i}_#{j}")
            end
          end)
        end

        Task.await_many(tasks, 10_000)
      end
    }, "Concurrent Writes (10 processes × 10 ops = 100 total)")

    # Test concurrent reads (multiple processes reading different keys)
    # Pre-populate data
    for i <- 1..100 do
      Concord.put("concurrent:read:data:#{i}", "value_#{i}")
    end

    benchee_run(%{
      "concurrent_reads_10_processes" => fn ->
        tasks = for i <- 1..10 do
          Task.async(fn ->
            for j <- 1..10 do
              key = "concurrent:read:data:#{((i-1)*10 + j)}"
              Concord.get(key)
            end
          end)
        end

        Task.await_many(tasks, 10_000)
      end
    }, "Concurrent Reads (10 processes × 10 ops = 100 total)")

    # Test mixed workload (realistic application scenario)
    benchee_run(%{
      "mixed_workload_5_processes" => fn ->
        tasks = for i <- 1..5 do
          Task.async(fn ->
            for j <- 1..20 do
              case rem(j, 4) do
                0 -> # Write operation
                  Concord.put("mixed:#{i}:#{j}", "mixed_value_#{j}")
                1 -> # Read operation
                  key = "mixed:#{i}:#{j-1}"
                  Concord.get(key)
                2 -> # TTL operation
                  key = "mixed:#{i}:#{j-2}"
                  Concord.touch(key, 3600)
                3 -> # Delete operation
                  key = "mixed:#{i}:#{j-3}"
                  Concord.delete(key)
              end
            end
          end)
        end

        Task.await_many(tasks, 15_000)
      end
    }, "Mixed Workload (5 processes, 100 ops total)")
  end

  def run_memory_usage_benchmarks do
    IO.puts("\n💾 Memory Usage Analysis")
    IO.puts("=========================")

    # Memory usage over time
    memory_before = get_memory_info()
    IO.puts("Memory before operations: #{format_memory(memory_before)}")

    # Store increasing amounts of data
    IO.puts("Testing memory usage with increasing data volume...")

    sizes = [100, 1000, 5000, 10000]

    for size <- sizes do
      # Clear data
      :ets.delete_all_objects(:concord_store)
      :garbage_collect()

      # Insert data
      values = for i <- 1..size do
        value = "data_" <> String.duplicate("x", 100)  # ~100 bytes per value
        Concord.put("memory:test:#{i}", value)
      end

      memory_after = get_memory_info()
      memory_per_item = (memory_after.total - memory_before.total) / size

      IO.puts("#{size} items: #{format_memory(memory_after)} (~#{Float.round(memory_per_item, 2)} bytes/item)")
    end

    # Test ETS table performance characteristics
    IO.puts("\nETS Table Performance Analysis:")
    analyze_ets_performance()
  end

  defp analyze_ets_performance do
    # Test different ETS table configurations
    table_types = [
      {:set, :ordered_set},
      {:bag, :duplicate_bag}
    ]

    for {type, subtype} <- table_types do
      IO.puts("\nTesting #{type}/#{subtype} characteristics:")

      # Create test table
      table = :ets.new(:test_table, [type, subtype, :public])

      # Insert performance
      {insert_time, _} = :timer.tc(fn ->
        for i <- 1..1000 do
          :ets.insert(table, {i, "value_#{i}"})
        end
      end)

      # Lookup performance
      {lookup_time, _} = :timer.tc(fn ->
        for i <- 1..1000 do
          :ets.lookup(table, i)
        end
      end)

      IO.puts("  Insert 1000 items: #{insert_time}μs (#{Float.round(1000_000 / insert_time, 2)} ops/sec)")
      IO.puts("  Lookup 1000 items: #{lookup_time}μs (#{Float.round(1000_000 / lookup_time, 2)} ops/sec)")

      :ets.delete(table)
    end
  end

  defp get_memory_info do
    :erlang.memory()
  end

  defp format_memory(memory) do
    total_mb = Float.round(memory[:total] / (1024 * 1024), 2)
    ets_mb = Float.round(memory[:ets] / (1024 * 1024), 2)
    processes_mb = Float.round(memory[:processes] / (1024 * 1024), 2)
    system_mb = Float.round(memory[:system] / (1024 * 1024), 2)

    "Total: #{total_mb}MB, ETS: #{ets_mb}MB, Processes: #{processes_mb}MB, System: #{system_mb}MB"
  end

  defp benchee_run(jobs, description) do
    IO.puts("\n#{description}:")

    try do
      # Try to use Benchee if available
      if Code.ensure_loaded?(Benchee) do
        Benchee.run(%{
          time: 5,
          memory_time: 2,
          print: [configuration: false],
          inputs: %{
            "Concord KV Operations" => jobs
          }
        })
      else
        # Fallback to simple timing if Benchee not available
        simple_benchmark(jobs)
      end
    rescue
      _ -> simple_benchmark(jobs)
    end
  end

  defp simple_benchmark(jobs) do
    for {name, fun} <- jobs do
      # Warm up
      fun.()

      # Measure
      {time_us, result} = :timer.tc(fun)
      ops_per_sec = Float.round(1_000_000 / time_us, 2)

      IO.puts("  #{name}: #{time_us}μs (#{ops_per_sec} ops/sec)")

      # Verify result is successful
      case result do
        :ok -> :ok
        {:ok, _} -> :ok
        _ -> IO.puts("    ⚠️  Unexpected result: #{inspect(result)}")
      end
    end
  end
end