#!/usr/bin/env elixir

# Simple concurrent access benchmark runner for Concord
# Run with: mix run run_concurrent_benchmarks.exs

defmodule ConcurrentBenchmarkRunner do
  def run do
    IO.puts("🚀 Concord Concurrent Access Performance Benchmark")
    IO.puts("===============================================")
    IO.puts("")

    # Start Concord
    start_concord()

    # Test concurrent patterns
    test_concurrent_reads()
    test_concurrent_writes()
    test_mixed_workload()

    IO.puts("\n✅ Concurrent access benchmarks completed!")
  end

  defp start_concord do
    IO.puts("🔧 Starting Concord...")
    Application.ensure_all_started(:concord)
    :timer.sleep(2000)
    :ets.delete_all_objects(:concord_store)
    IO.puts("✅ Concord ready")
  end

  defp test_concurrent_reads do
    IO.puts("\n📖 Concurrent Read Performance")
    IO.puts("=============================")

    # Pre-populate test data
    IO.puts("Preparing test data...")
    keys = for i <- 1..500 do
      key = "concurrent_read:#{i}"
      Concord.put(key, "value_#{i}")
      key
    end

    # Test different concurrency levels
    concurrency_levels = [1, 5, 10, 20]

    for concurrency <- concurrency_levels do
      IO.puts("\nTesting #{concurrency} concurrent readers:")

      {read_time, results} = :timer.tc(fn ->
        tasks = for _i <- 1..concurrency do
          Task.async(fn ->
            # Each reader performs 50 reads
            reads = for _j <- 1..50 do
              key = Enum.random(keys)
              Concord.get(key)
            end
            length(reads)
          end)
        end

        # Wait for all tasks and collect results
        successful_reads = tasks
        |> Enum.map(&Task.await(&1, 10_000))
        |> Enum.sum()

        successful_reads
      end)

      total_reads = concurrency * 50
      success_rate = (results / total_reads) * 100
      avg_time_per_read = read_time / total_reads
      reads_per_sec = Float.round(total_reads * 1_000_000 / read_time, 2)

      IO.puts("  Total reads:       #{total_reads}")
      IO.puts("  Successful:        #{results} (#{Float.round(success_rate, 1)}%)")
      IO.puts("  Total time:        #{format_time(read_time)}")
      IO.puts("  Avg per read:      #{format_time(avg_time_per_read)}")
      IO.puts("  Throughput:        #{reads_per_sec} reads/sec")
    end
  end

  defp test_concurrent_writes do
    IO.puts("\n✍️  Concurrent Write Performance")
    IO.puts("===============================")

    # Test different concurrency levels
    concurrency_levels = [1, 5, 10]

    for concurrency <- concurrency_levels do
      IO.puts("\nTesting #{concurrency} concurrent writers:")

      {write_time, results} = :timer.tc(fn ->
        tasks = for i <- 1..concurrency do
          Task.async(fn ->
            # Each writer performs 25 writes
            writes = for j <- 1..25 do
              key = "concurrent_write:#{i}:#{j}:#{System.unique_integer()}"
              value = "data_#{i}_#{j}"
              Concord.put(key, value)
            end
            Enum.count(writes, fn
              :ok -> true
              _ -> false
            end)
          end)
        end

        # Wait for all tasks and collect results
        successful_writes = tasks
        |> Enum.map(&Task.await(&1, 15_000))
        |> Enum.sum()

        successful_writes
      end)

      total_writes = concurrency * 25
      success_rate = (results / total_writes) * 100
      avg_time_per_write = write_time / total_writes
      writes_per_sec = Float.round(total_writes * 1_000_000 / write_time, 2)

      IO.puts("  Total writes:      #{total_writes}")
      IO.puts("  Successful:        #{results} (#{Float.round(success_rate, 1)}%)")
      IO.puts("  Total time:        #{format_time(write_time)}")
      IO.puts("  Avg per write:     #{format_time(avg_time_per_write)}")
      IO.puts("  Throughput:        #{writes_per_sec} writes/sec")
    end
  end

  defp test_mixed_workload do
    IO.puts("\n🔄 Mixed Read/Write Workload")
    IO.puts("===========================")

    # Pre-populate some data for reading
    for i <- 1..200 do
      Concord.put("mixed_test:#{i}", "initial_value_#{i}")
    end

    concurrency = 10
    total_operations_per_worker = 60

    IO.puts("Testing #{concurrency} concurrent workers with mixed operations:")

    {mixed_time, results} = :timer.tc(fn ->
      tasks = for i <- 1..concurrency do
        Task.async(fn ->
          # Each worker performs mixed operations
          operations = for j <- 1..total_operations_per_worker do
            if :rand.uniform(100) <= 70 do
              # 70% reads
              key = "mixed_test:#{:rand.uniform(200)}"
              case Concord.get(key) do
                {:ok, _} -> :read_success
                _ -> :read_failed
              end
            else
              # 30% writes
              key = "mixed_write:#{i}:#{j}:#{System.unique_integer()}"
              value = "mixed_data_#{i}_#{j}"
              case Concord.put(key, value) do
                :ok -> :write_success
                _ -> :write_failed
              end
            end
          end

          # Count successful operations
          {read_success, read_failed, write_success, write_failed} =
            Enum.reduce(operations, {0, 0, 0, 0}, fn
              :read_success, {r, rf, w, wf} -> {r + 1, rf, w, wf}
              :read_failed, {r, rf, w, wf} -> {r, rf + 1, w, wf}
              :write_success, {r, rf, w, wf} -> {r, rf, w + 1, wf}
              :write_failed, {r, rf, w, wf} -> {r, rf, w, wf + 1}
            end)

          {read_success, read_failed, write_success, write_failed}
        end)
      end

      # Wait for all tasks and aggregate results
      results_list = Enum.map(tasks, &Task.await(&1, 20_000))

      total_reads_success = Enum.sum(Enum.map(results_list, fn {r, _, _, _} -> r end))
      total_reads_failed = Enum.sum(Enum.map(results_list, fn {_, rf, _, _} -> rf end))
      total_writes_success = Enum.sum(Enum.map(results_list, fn {_, _, w, _} -> w end))
      total_writes_failed = Enum.sum(Enum.map(results_list, fn {_, _, _, wf} -> wf end))

      {
        total_reads_success + total_reads_failed + total_writes_success + total_writes_failed,
        {total_reads_success, total_reads_failed, total_writes_success, total_writes_failed}
      }
    end)

    {total_ops, {read_success, read_failed, write_success, write_failed}} = results
    total_reads = read_success + read_failed
    total_writes = write_success + write_failed

    overall_success_rate = ((read_success + write_success) / total_ops) * 100
    read_success_rate = if total_reads > 0, do: (read_success / total_reads) * 100, else: 0
    write_success_rate = if total_writes > 0, do: (write_success / total_writes) * 100, else: 0

    avg_time_per_op = mixed_time / total_ops
    ops_per_sec = Float.round(total_ops * 1_000_000 / mixed_time, 2)

    IO.puts("  Total operations:   #{total_ops}")
    IO.puts("    Reads:           #{total_reads} (#{read_success} success, #{read_success_rate}%)")
    IO.puts("    Writes:          #{total_writes} (#{write_success} success, #{write_success_rate}%)")
    IO.puts("  Overall success:   #{overall_success_rate}%")
    IO.puts("  Total time:        #{format_time(mixed_time)}")
    IO.puts("  Avg per operation: #{format_time(avg_time_per_op)}")
    IO.puts("  Throughput:        #{ops_per_sec} ops/sec")
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
ConcurrentBenchmarkRunner.run()