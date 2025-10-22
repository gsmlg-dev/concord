defmodule Concord.Performance.ConcurrentAccessBenchmark do
  @moduledoc """
  Comprehensive concurrent access patterns benchmark for Concord.

  This benchmark tests Concord's performance under various concurrent access patterns
  typical in embedded applications, including read/write conflicts, high concurrency
  scenarios, and contention analysis.
  """

  def run_concurrent_benchmarks do
    IO.puts("🚀 Concord Concurrent Access Patterns Benchmark")
    IO.puts("===============================================")
    IO.puts("Testing concurrent performance characteristics...")
    IO.puts("")

    setup_concord()

    # Test different concurrency patterns
    test_read_heavy_workload()
    test_write_heavy_workload()
    test_mixed_read_write_workload()
    test_contention_scenarios()
    test_session_concurrency()
    test_feature_flag_concurrency()
    test_rate_limiting_concurrency()

    IO.puts("\n✅ All concurrent access benchmarks completed!")
  end

  defp setup_concord do
    Application.ensure_all_started(:concord)
    :timer.sleep(2000)
    :ets.delete_all_objects(:concord_store)
    IO.puts("✅ Concord ready for concurrent testing")
  end

  defp test_read_heavy_workload do
    IO.puts("\n📖 Read-Heavy Workload Test")
    IO.puts("============================")

    # Pre-populate data
    keys = for i <- 1..1000 do
      key = "read_test:#{i}"
      Concord.put(key, "value_#{i}")
      key
    end

    concurrency_levels = [1, 5, 10, 20, 50]

    for concurrency <- concurrency_levels do
      IO.puts("\nTesting #{concurrency} concurrent readers:")

      # Test concurrent reads
      {read_time, read_results} = :timer.tc(fn ->
        tasks = for _i <- 1..concurrency do
          Task.async(fn ->
            # Each reader performs 100 reads
            for _j <- 1..100 do
              key = Enum.random(keys)
              Concord.get(key)
            end
          end)
        end

        results = for task <- tasks do
          Task.await(task, 10_000)
        end

        results
      end)

      total_reads = concurrency * 100
      successful_reads = count_successful_reads(read_results)
      success_rate = (successful_reads / total_reads) * 100

      avg_time_per_read = read_time / total_reads
      reads_per_sec = Float.round(total_reads * 1_000_000 / read_time, 2)

      IO.puts("  Total reads:      #{total_reads}")
      IO.puts("  Successful:       #{successful_reads} (#{Float.round(success_rate, 1)}%)")
      IO.puts("  Total time:       #{format_time(read_time)}")
      IO.puts("  Avg per read:     #{format_time(avg_time_per_read)}")
      IO.puts("  Throughput:       #{reads_per_sec} reads/sec")
    end
  end

  defp test_write_heavy_workload do
    IO.puts("\n✍️  Write-Heavy Workload Test")
    IO.puts("=============================")

    concurrency_levels = [1, 5, 10, 20]

    for concurrency <- concurrency_levels do
      IO.puts("\nTesting #{concurrency} concurrent writers:")

      # Test concurrent writes
      {write_time, write_results} = :timer.tc(fn ->
        tasks = for i <- 1..concurrency do
          Task.async(fn ->
            # Each writer performs 50 writes
            for j <- 1..50 do
              key = "write_test:#{i}:#{j}:#{System.unique_integer()}"
              value = "data_#{i}_#{j}"
              Concord.put(key, value)
            end
          end)
        end

        results = for task <- tasks do
          Task.await(task, 15_000)
        end

        results
      end)

      total_writes = concurrency * 50
      successful_writes = count_successful_writes(write_results)
      success_rate = (successful_writes / total_writes) * 100

      avg_time_per_write = write_time / total_writes
      writes_per_sec = Float.round(total_writes * 1_000_000 / write_time, 2)

      IO.puts("  Total writes:     #{total_writes}")
      IO.puts("  Successful:       #{successful_writes} (#{Float.round(success_rate, 1)}%)")
      IO.puts("  Total time:       #{format_time(write_time)}")
      IO.puts("  Avg per write:    #{format_time(avg_time_per_write)}")
      IO.puts("  Throughput:       #{writes_per_sec} writes/sec")
    end
  end

  defp test_mixed_read_write_workload do
    IO.puts("\n🔄 Mixed Read/Write Workload Test")
    IO.puts("=================================")

    # Pre-populate some data for reading
    for i <- 1..500 do
      Concord.put("mixed_test:#{i}", "initial_value_#{i}")
    end

    read_write_ratios = [
      {80, 20},  # 80% reads, 20% writes
      {50, 50},  # 50% reads, 50% writes
      {20, 80}   # 20% reads, 80% writes
    ]

    concurrency = 10

    for {read_pct, write_pct} <- read_write_ratios do
      IO.puts("\nTesting #{read_pct}% reads / #{write_pct}% writes with #{concurrency} concurrent workers:")

      {mixed_time, mixed_results} = :timer.tc(fn ->
        tasks = for i <- 1..concurrency do
          Task.async(fn ->
            # Each worker performs 100 operations
            for j <- 1..100 do
              if :rand.uniform(100) <= read_pct do
                # Read operation
                key = "mixed_test:#{:rand.uniform(500)}"
                Concord.get(key)
              else
                # Write operation
                key = "mixed_test:#{i}:#{j}:#{System.unique_integer()}"
                value = "mixed_data_#{i}_#{j}"
                Concord.put(key, value)
              end
            end
          end)
        end

        results = for task <- tasks do
          Task.await(task, 15_000)
        end

        results
      end)

      total_ops = concurrency * 100
      total_reads = round(total_ops * read_pct / 100)
      total_writes = round(total_ops * write_pct / 100)

      avg_time_per_op = mixed_time / total_ops
      ops_per_sec = Float.round(total_ops * 1_000_000 / mixed_time, 2)

      IO.puts("  Total operations: #{total_ops} (#{total_reads} reads, #{total_writes} writes)")
      IO.puts("  Total time:       #{format_time(mixed_time)}")
      IO.puts("  Avg per operation: #{format_time(avg_time_per_op)}")
      IO.puts("  Throughput:       #{ops_per_sec} ops/sec")
    end
  end

  defp test_contention_scenarios do
    IO.puts("\n⚔️  Contention Scenarios Test")
    IO.puts("===========================")

    # Test hot key contention
    IO.puts("\nTesting hot key contention:")

    hot_key = "contention:hot_key"
    concurrency = 20

    # Pre-populate the hot key
    Concord.put(hot_key, "initial_value")

    {contention_time, contention_results} = :timer.tc(fn ->
      tasks = for i <- 1..concurrency do
        Task.async(fn ->
          for j <- 1..50 do
            case :rand.uniform(3) do
              1 -> Concord.get(hot_key)
              2 -> Concord.put(hot_key, "updated_by_#{i}_#{j}")
              3 -> Concord.touch(hot_key, 3600)
            end
          end
        end)
      end

      results = for task <- tasks do
        Task.await(task, 20_000)
      end

      results
    end)

    total_ops = concurrency * 50
    avg_time_per_op = contention_time / total_ops
    ops_per_sec = Float.round(total_ops * 1_000_000 / contention_time, 2)

    IO.puts("  Total operations: #{total_ops}")
    IO.puts("  Total time:       #{format_time(contention_time)}")
    IO.puts("  Avg per operation: #{format_time(avg_time_per_op)}")
    IO.puts("  Throughput:       #{ops_per_sec} ops/sec")
    IO.puts("  Hot key: #{hot_key}")
  end

  defp test_session_concurrency do
    IO.puts("\n👥 Session Management Concurrency Test")
    IO.puts("=====================================")

    # Simulate concurrent session operations typical in web applications
    concurrency = 15

    {session_time, session_results} = :timer.tc(fn ->
      tasks = for i <- 1..concurrency do
        Task.async(fn ->
          user_id = i + 1000

          # Simulate session lifecycle
          operations = [
            # Create session
            fn ->
              session_key = "session:user:#{user_id}"
              session_data = %{
                user_id: user_id,
                csrf_token: Base.encode64(:crypto.strong_rand_bytes(16)),
                last_activity: DateTime.utc_now(),
                ip_address: "192.168.1.#{rem(user_id, 255)}"
              }
              Concord.put(session_key, session_data, [ttl: 1800])
            end,

            # Extend session (simulate user activity)
            fn ->
              session_key = "session:user:#{user_id}"
              Concord.touch(session_key, 1800)
            end,

            # Update session
            fn ->
              session_key = "session:user:#{user_id}"
              case Concord.get(session_key) do
                {:ok, session_data} ->
                  updated_data = %{session_data | last_activity: DateTime.utc_now()}
                  Concord.put(session_key, updated_data, [ttl: 1800])
                _ -> :error
              end
            end,

            # Read session
            fn ->
              session_key = "session:user:#{user_id}"
              Concord.get(session_key)
            end
          ]

          # Execute operations in random order multiple times
          for _j <- 1..25 do
            operation = Enum.random(operations)
            operation.()
            :timer.sleep(:rand.uniform(5))  # Small delay to simulate real usage
          end
        end)
      end

      results = for task <- tasks do
        Task.await(task, 30_000)
      end

      results
    end)

    total_session_ops = concurrency * 25 * 4  # 25 cycles × 4 operations per cycle
    avg_time_per_op = session_time / total_session_ops
    ops_per_sec = Float.round(total_session_ops * 1_000_000 / session_time, 2)

    IO.puts("  Concurrent users: #{concurrency}")
    IO.puts("  Total operations: #{total_session_ops}")
    IO.puts("  Total time:       #{format_time(session_time)}")
    IO.puts("  Avg per operation: #{format_time(avg_time_per_op)}")
    IO.puts("  Throughput:       #{ops_per_sec} ops/sec")
  end

  defp test_feature_flag_concurrency do
    IO.puts("\n🚩 Feature Flag Concurrency Test")
    IO.puts("=================================")

    # Pre-populate feature flags
    feature_flags = [
      {"feature:new_ui", %{enabled: true, rollout: 100}},
      {"feature:dark_mode", %{enabled: true, rollout: 50}},
      {"feature:beta_search", %{enabled: false, rollout: 20}},
      {"feature:advanced_analytics", %{enabled: true, rollout: 75}}
    ]

    for {flag, data} <- feature_flags do
      Concord.put(flag, data)
    end

    concurrency = 25

    {feature_time, feature_results} = :timer.tc(fn ->
      tasks = for i <- 1..concurrency do
        Task.async(fn ->
          user_id = i + 2000

          # Simulate feature flag checks for a user
          for _j <- 1..100 do
            flag_key = Enum.map(feature_flags, fn {key, _} -> key end) |> Enum.random()

            case Concord.get(flag_key) do
              {:ok, flag_data} ->
                # Simulate feature flag evaluation logic
                enabled = flag_data.enabled and
                         (flag_data.rollout >= 50 or
                          rem(user_id, 100) < flag_data.rollout)
                enabled
              _ ->
                false
            end
          end
        end)
      end

      results = for task <- tasks do
        Task.await(task, 15_000)
      end

      results
    end)

    total_flag_checks = concurrency * 100
    avg_time_per_check = feature_time / total_flag_checks
    checks_per_sec = Float.round(total_flag_checks * 1_000_000 / feature_time, 2)

    IO.puts("  Concurrent users: #{concurrency}")
    IO.puts("  Total flag checks: #{total_flag_checks}")
    IO.puts("  Total time:       #{format_time(feature_time)}")
    IO.puts("  Avg per check:    #{format_time(avg_time_per_check)}")
    IO.puts("  Throughput:       #{checks_per_sec} checks/sec")
  end

  defp test_rate_limiting_concurrency do
    IO.puts("\n🚦 Rate Limiting Concurrency Test")
    IO.puts("=================================")

    concurrency = 30

    {rate_limit_time, rate_limit_results} = :timer.tc(fn ->
      tasks = for i <- 1..concurrency do
        Task.async(fn ->
          user_id = i + 3000

          # Simulate rate limiting for a user
          for _j <- 1..50 do
            rate_limit_key = "rate_limit:#{user_id}:#{Date.utc_today()}"

            # Check current count
            current = case Concord.get(rate_limit_key) do
              {:ok, count} -> count
              {:error, :not_found} -> 0
            end

            if current < 1000 do
              # Increment counter
              Concord.put(rate_limit_key, current + 1, [ttl: 86400])
              :allowed
            else
              :rate_limited
            end
          end
        end)
      end

      results = for task <- tasks do
        Task.await(task, 20_000)
      end

      results
    end)

    total_rate_limit_checks = concurrency * 50
    allowed_requests = count_allowed_requests(rate_limit_results)
    rate_limited_requests = total_rate_limit_checks - allowed_requests

    avg_time_per_check = rate_limit_time / total_rate_limit_checks
    checks_per_sec = Float.round(total_rate_limit_checks * 1_000_000 / rate_limit_time, 2)

    IO.puts("  Concurrent users: #{concurrency}")
    IO.puts("  Total checks:     #{total_rate_limit_checks}")
    IO.puts("  Allowed requests: #{allowed_requests}")
    IO.puts("  Rate limited:     #{rate_limited_requests}")
    IO.puts("  Total time:       #{format_time(rate_limit_time)}")
    IO.puts("  Avg per check:    #{format_time(avg_time_per_check)}")
    IO.puts("  Throughput:       #{checks_per_sec} checks/sec")
  end

  # Helper functions

  defp count_successful_reads(results) do
    results
    |> List.flatten()
    |> Enum.count(fn
      {:ok, _} -> true
      _ -> false
    end)
  end

  defp count_successful_writes(results) do
    results
    |> List.flatten()
    |> Enum.count(fn
      :ok -> true
      _ -> false
    end)
  end

  defp count_allowed_requests(results) do
    results
    |> List.flatten()
    |> Enum.count(fn
      :allowed -> true
      _ -> false
    end)
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