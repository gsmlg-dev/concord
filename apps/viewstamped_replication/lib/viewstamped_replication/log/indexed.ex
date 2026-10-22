defmodule ViewstampedReplication.Log.Indexed do
  @moduledoc false

  # Only the runtime and storage adapter own this representation. Public,
  # persisted, and transferred logs retain the ordered-list Log representation.
  defstruct base_op_number: 0, last_op_number: 0, entries: %{}

  @type t :: %__MODULE__{
          base_op_number: non_neg_integer(),
          last_op_number: non_neg_integer(),
          entries: %{optional(pos_integer()) => ViewstampedReplication.LogEntry.t()}
        }
end
