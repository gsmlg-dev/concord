# Start required applications
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:local_cluster)

# Initialize LocalCluster as a manager node
:ok = LocalCluster.start()

# Start ExUnit with specific configuration for e2e tests
ExUnit.start(
  exclude: [:skip],
  max_failures: 1,
  trace: true
)

IO.puts("\n=== E2E Test Suite Starting ===\n")
