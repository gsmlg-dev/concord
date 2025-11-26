# Clean up orphan processes from previous runs
# Only kill node processes, not the test runner
defmodule Concord.E2E.Cleanup do
  def kill_orphans do
    IO.puts("Cleaning up orphan e2e processes...")
    # Use more specific pattern to only kill node processes (concord_e2e\d+@)
    System.cmd("pkill", ["-9", "-f", "concord_e2e[0-9]+@"], stderr_to_stdout: true)
    Process.sleep(500)
  end
end

Concord.E2E.Cleanup.kill_orphans()

# Ensure the test runner node is alive (distributed Erlang)
# This should be handled by the mix alias passing --name flag
case Node.alive?() do
  true ->
    IO.puts("✓ Test runner node: #{Node.self()}")
    IO.puts("✓ Cookie: #{Node.get_cookie()}")

  false ->
    IO.puts("""
    ╔════════════════════════════════════════════════════════════════════════════╗
    ║                    ERROR: Test runner node is not distributed!             ║
    ╠════════════════════════════════════════════════════════════════════════════╣
    ║                                                                            ║
    ║  E2E tests require distributed Erlang to spawn cluster nodes.              ║
    ║                                                                            ║
    ║  Use one of these methods:                                                 ║
    ║                                                                            ║
    ║    1. mix test.e2e (recommended)                                           ║
    ║    2. ./scripts/run_e2e_tests.sh e2e_test/                                 ║
    ║                                                                            ║
    ║  Manual invocation:                                                        ║
    ║    MIX_ENV=e2e_test elixir --name test@127.0.0.1 --cookie test_cookie \\   ║
    ║      -S mix test e2e_test/                                                 ║
    ║                                                                            ║
    ╚════════════════════════════════════════════════════════════════════════════╝
    """)

    System.halt(1)
end

# Start required applications
{:ok, _} = Application.ensure_all_started(:telemetry)

# Register cleanup on exit
System.at_exit(fn _ ->
  IO.puts("\nCleaning up e2e processes on exit...")
  # Use specific pattern to only kill node processes
  System.cmd("pkill", ["-9", "-f", "concord_e2e[0-9]+@"], stderr_to_stdout: true)
end)

# Start ExUnit with specific configuration for e2e tests
ExUnit.start(
  exclude: [:skip],
  max_failures: 1,
  trace: true
)

IO.puts("\n=== E2E Test Suite Starting ===\n")
