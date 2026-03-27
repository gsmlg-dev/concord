[
  # Ra library and application initialization - type contract mismatches with Ra Erlang types
  ~r/lib\/concord\/application.ex.*no_return/,
  ~r/lib\/concord\/application.ex.*:call/,

  # State machine pattern matches are defensive programming for backward compatibility
  ~r/lib\/concord\/state_machine.ex.*pattern_match/,
  ~r/lib\/concord\/state_machine.ex.*callback_arg_type_mismatch/
]
