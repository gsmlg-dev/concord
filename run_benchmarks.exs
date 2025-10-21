#!/usr/bin/env elixir

# Simple benchmark runner for Concord embedded database performance
# Run with: mix run run_benchmarks.exs

defmodule BenchmarkRunner do
  def run_all do
    IO.puts("🚀 Concord Embedded Database Performance Benchmarks")
    IO.puts("==================================================")
    IO.puts("Testing performance for embedded Elixir applications...")
    IO.puts("")

    # Check if we're in a project context
    if Code.ensure_loaded?(Mix) do
      IO.puts("✅ Running in Mix project context")
    else
      IO.puts("⚠️  Not in Mix context - some features may be limited")
    end

    # Start Concord
    start_concord()

    # Run basic performance tests
    run_basic_performance_tests()

    # Run embedded scenario tests
    run_embedded_scenario_tests()

    # Run HTTP API performance tests
    run_http_api_tests()

    # Run memory analysis
    run_memory_analysis()

    IO.puts("\n🎉 All benchmarks completed!")
    IO.puts("📊 Check the results above for performance characteristics")
    IO.puts("")
    IO.puts("💡 For more detailed benchmarks, consider adding Benchee:")
    IO.puts("   Add to mix.exs: {:benchee, \"~> 1.1\", only: :dev}")
  end

  defp start_concord do
    IO.puts("\n🔧 Starting Concord cluster...")

    try do
      # Try to start Concord if not already running
      case Application.start(:concord) do
        :ok -> IO.puts("✅ Concord started successfully")
        {:error, {:already_started, :concord}} -> IO.puts("✅ Concord already running")
        {:error, reason} ->
          IO.puts("⚠️  Could not start Concord: #{inspect(reason)}")
          IO.puts("   Trying to ensure all applications are started...")
          Application.ensure_all_started(:concord)
      end
    rescue
      _ ->
        IO.puts("⚠️  Could not start Concord, running in limited mode")
    end

    # Give cluster time to initialize
    :timer.sleep(1000)

    # Clear any existing data for clean testing
    try do
      :ets.delete_all_objects(:concord_store)
      IO.puts("✅ Test environment prepared")
    rescue
      _ -> IO.puts("⚠️  Could not clear ETS table")
    end
  end

  defp run_basic_performance_tests do
    IO.puts("\n📊 Basic KV Operations Performance")
    IO.puts("==================================")

    test_operations = [
      {"Small value put (100 bytes)", fn ->
        Concord.put("test:small:#{System.unique_integer()}", String.duplicate("x", 100))
      end},

      {"Small value get", fn ->
        key = "test:get:small:#{System.unique_integer()}"
        Concord.put(key, "test_value")
        Concord.get(key)
      end},

      {"Medium value put (1KB)", fn ->
        Concord.put("test:medium:#{System.unique_integer()}", String.duplicate("x", 1000))
      end},

      {"Medium value get", fn ->
        key = "test:get:medium:#{System.unique_integer()}"
        Concord.put(key, String.duplicate("x", 1000))
        Concord.get(key)
      end},

      {"Large value put (10KB)", fn ->
        Concord.put("test:large:#{System.unique_integer()}", String.duplicate("x", 10000))
      end},

      {"Large value get", fn ->
        key = "test:get:large:#{System.unique_integer()}"
        Concord.put(key, String.duplicate("x", 10000))
        Concord.get(key)
      end},

      {"Delete operation", fn ->
        key = "test:delete:#{System.unique_integer()}"
        Concord.put(key, "test_value")
        Concord.delete(key)
      end},

      {"TTL put (1 hour)", fn ->
        Concord.put("test:ttl:#{System.unique_integer()}", "ttl_value", [ttl: 3600])
      end},

      {"TTL touch (extend)", fn ->
        key = "test:touch:#{System.unique_integer()}"
        Concord.put(key, "ttl_value", [ttl: 300])
        Concord.touch(key, 3600)
      end},

      {"Get with TTL", fn ->
        key = "test:get_ttl:#{System.unique_integer()}"
        Concord.put(key, "ttl_value", [ttl: 3600])
        Concord.get_with_ttl(key)
      end}
    ]

    run_performance_suite(test_operations)
  end

  defp run_embedded_scenario_tests do
    IO.puts("\n🏗️  Embedded Application Scenarios")
    IO.puts("=================================")

    scenario_operations = [
      {"User session store", fn ->
        session_data = %{
          user_id: System.unique_integer(),
          csrf_token: Base.encode64(:crypto.strong_rand_bytes(16)),
          last_activity: DateTime.utc_now(),
          ip_address: "192.168.1.#{:rand.uniform(255)}"
        }
        Concord.put("session:#{session_data.user_id}", session_data, [ttl: 1800])
      end},

      {"Rate limit check", fn ->
        user_id = :rand.uniform(1000)
        key = "rate_limit:#{user_id}:#{Date.utc_today()}"

        current = case Concord.get(key) do
          {:ok, count} -> count
          {:error, :not_found} -> 0
        end

        Concord.put(key, current + 1, [ttl: 86400])
        current < 100
      end},

      {"Feature flag check", fn ->
        flag_key = "feature:new_ui"
        case Concord.get(flag_key) do
          {:ok, flag} -> flag.enabled
          {:error, :not_found} -> false
        end
      end},

      {"Cache API response", fn ->
        endpoint = "/api/resource#{:rand.uniform(50)}"
        response = %{
          data: "response_data_#{System.unique_integer()}",
          cached_at: DateTime.utc_now()
        }
        Concord.put("cache:api:#{endpoint}", response, [ttl: 300])
      end},

      {"Configuration lookup", fn ->
        case Concord.get("config:database") do
          {:ok, config} -> config.port
          {:error, :not_found} -> 5432
        end
      end},

      {"Distributed lock acquire", fn ->
        lock_key = "lock:resource:#{System.unique_integer()}"
        lock_data = %{owner: self(), acquired_at: DateTime.utc_now()}
        Concord.put(lock_key, lock_data, [ttl: 30])
      end}
    ]

    run_performance_suite(scenario_operations)
  end

  defp run_http_api_tests do
    IO.puts("\n🌐 HTTP API Performance (if available)")
    IO.puts("====================================")

    # Test if HTTP API is running
    api_available = try do
      :httpc.request(:get, {"http://localhost:4000/api/v1/health", []}, [], [])
      true
    rescue
      _ -> false
    end

    if api_available do
      IO.puts("✅ HTTP API is running - testing performance...")

      api_operations = [
        {"Health check", fn ->
          :httpc.request(:get, {"http://localhost:4000/api/v1/health", []}, [], [])
        end},

        {"OpenAPI spec", fn ->
          :httpc.request(:get, {"http://localhost:4000/api/v1/openapi.json", []}, [], [])
        end}
      ]

      run_performance_suite(api_operations)
    else
      IO.puts("⚠️  HTTP API not running - skipping HTTP performance tests")
      IO.puts("   Start HTTP API with: CONCORD_API_PORT=4000 mix start")
    end
  end

  defp run_memory_analysis do
    IO.puts("\n💾 Memory Usage Analysis")
    IO.puts("=======================")

    initial_memory = :erlang.memory()
    IO.puts("Initial memory: #{format_memory(initial_memory)}")

    # Test memory usage with increasing data
    test_sizes = [100, 1000, 5000]

    for size <- test_sizes do
      IO.puts("\nTesting with #{size} items (~#{size * 100} bytes total):")

      # Clear data and force GC
      try do
        :ets.delete_all_objects(:concord_store)
        :erlang.garbage_collect()
      rescue
        _ -> :ok
      end

      memory_before = :erlang.memory()

      # Insert test data
      test_data = for i <- 1..size do
        value = "data_#{i}_" <> String.duplicate("x", 90)  # ~100 bytes per item
        Concord.put("memory_test:#{i}", value)
      end

      memory_after = :erlang.memory()

      memory_used = memory_after[:total] - memory_before[:total]
      memory_per_item = memory_used / size

      IO.puts("  Total memory: #{format_memory(memory_after)}")
      IO.puts("  Memory used: #{Float.round(memory_used / 1024 / 1024, 2)}MB")
      IO.puts("  Memory per item: #{Float.round(memory_per_item, 2)} bytes")

      # Test lookup performance with this data size
      {lookup_time, _} = :timer.tc(fn ->
        for i <- 1..min(size, 1000) do
          Concord.get("memory_test:#{rem(i, size) + 1}")
        end
      end)

      ops_per_sec = Float.round(1000 * 1_000_000 / lookup_time, 2)
      IO.puts("  Lookup speed: #{ops_per_sec} ops/sec (1000 lookups)")
    end
  end

  defp run_performance_suite(operations) do
    for {name, operation} <- operations do
      IO.write("#{name}: ... ")

      try do
        # Warm up
        operation.()

        # Measure multiple iterations
        measurements = for _i <- 1..100 do
          {time_us, _result} = :timer.tc(operation)
          time_us
        end

        # Calculate statistics
        avg_time = Enum.sum(measurements) / length(measurements)
        min_time = Enum.min(measurements)
        max_time = Enum.max(measurements)
        ops_per_sec = Float.round(1_000_000 / avg_time, 2)

        IO.puts("#{Float.round(avg_time, 2)}μs avg (#{ops_per_sec} ops/sec)")
        IO.puts("  Range: #{min_time}μs - #{max_time}μs")

      rescue
        error ->
          IO.puts("FAILED - #{inspect(error)}")
      end
    end
  end

  defp format_memory(memory) do
    total_mb = Float.round(memory[:total] / (1024 * 1024), 2)
    ets_mb = Float.round(memory[:ets] / (1024 * 1024), 2)
    processes_mb = Float.round(memory[:processes] / (1024 * 1024), 2)

    "Total: #{total_mb}MB, ETS: #{ets_mb}MB, Processes: #{processes_mb}MB"
  end
end

# Run the benchmarks
BenchmarkRunner.run_all()