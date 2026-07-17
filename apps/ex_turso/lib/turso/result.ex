defmodule Turso.Result do
  @moduledoc """
  The result of a query or statement.

    * `columns` — ordered column names for result sets
    * `rows` — a list of maps keyed by column name (`nil` for non-`:query` commands)
    * `num_rows` — number of rows returned, or rows affected for writes
  """

  @type t :: %__MODULE__{
          columns: [String.t()] | nil,
          rows: [map()] | [[term()]] | nil,
          num_rows: non_neg_integer()
        }

  defstruct columns: nil, rows: nil, num_rows: 0
end
