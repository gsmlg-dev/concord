# Ensure the test runner node is alive (distributed Erlang)
# This should be handled by the mix alias passing --name flag
case Node.alive?() do
  true ->
    IO.puts("✓ Test runner node is alive: #{Node.self()}")
    IO.puts("✓ Cookie: #{Node.get_cookie()}")

  false ->
    IO.puts("""
    ✗ Error: Test runner node is not alive!

    E2E tests require distributed Erlang to spawn cluster nodes.
    The mix alias should handle this automatically.

    If running manually, use:
      MIX_ENV=e2e_test elixir --name test@127.0.0.1 --cookie test_cookie -S mix test e2e_test/
    """)

    System.halt(1)
end

# Start required applications
{:ok, _} = Application.ensure_all_started(:telemetry)

# Start ExUnit with specific configuration for e2e tests
ExUnit.start(
  exclude: [:skip],
  max_failures: 1,
  trace: true
)

IO.puts("\n=== E2E Test Suite Starting ===\n")
