[
  # Ra library and application initialization - type contract mismatches with Ra Erlang types
  ~r/lib\/concord\/application.ex.*no_return/,
  ~r/lib\/concord\/application.ex:137.*:call/,
  ~r/lib\/concord\/application.ex:147.*:call/,
  ~r/lib\/concord\/application.ex:160.*:call/,

  # State machine pattern matches are defensive programming for backward compatibility
  ~r/lib\/concord\/state_machine.ex.*pattern_match/,
  ~r/lib\/concord\/state_machine.ex.*callback_arg_type_mismatch/,

  # OpenTelemetry tracing - opaque type and API contract mismatches
  ~r/lib\/concord\/tracing\/telemetry_bridge.ex:90.*:call/,

  # Web API and supervisor init functions
  ~r/lib\/concord\/web\/api_controller.ex.*pattern_match/,
  ~r/lib\/concord\/web\/supervisor.ex.*no_return/,

  # Mix tasks - defensive error handling for unreachable branches
  ~r/lib\/mix\/tasks\/concord.ex:12[78].*pattern_match/,
  ~r/lib\/mix\/tasks\/concord.ex:17[14].*pattern_match/,

  # Multi-tenancy default values - defensive clause for invalid arguments
  ~r/lib\/concord\/multi_tenancy.ex:159.*multiple clauses/
]