[
  # Ra library and application initialization - no_return warnings are false positives
  ~r/lib\/concord\/application.ex.*no_return/,
  ~r/lib\/concord\/application.ex:137.*:call/,

  # State machine pattern matches are defensive programming for backward compatibility
  ~r/lib\/concord\/state_machine.ex.*pattern_match/,
  ~r/lib\/concord\/state_machine.ex.*callback_arg_type_mismatch/,

  # OpenTelemetry tracing - opaque type and API contract mismatches
  ~r/lib\/concord\/tracing\/telemetry_bridge.ex:90.*:call/,

  # Web API and supervisor init functions
  ~r/lib\/concord\/web\/api_controller.ex.*pattern_match/,
  ~r/lib\/concord\/web\/supervisor.ex.*no_return/
]