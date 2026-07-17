defmodule Turso.Query do
  @moduledoc """
  A prepared SQL statement passed through the `DBConnection` machinery.

  `command` selects which NIF runs the statement:

    * `:query` — returns rows as maps (via `Turso.Native.query_rows/3`)
    * `:query_rows` — returns ordered columns and row values for Ecto
    * `:execute` — returns the affected-row count (via `Turso.Native.execute/3`)
    * `:sync` — triggers replica sync (via `Turso.Native.sync/1`); the
      statement text is ignored
  """

  @type command :: :query | :query_rows | :execute | :sync

  @type t :: %__MODULE__{
          name: String.t(),
          statement: String.t(),
          command: command()
        }

  defstruct name: "", statement: nil, command: :query
end

defimpl DBConnection.Query, for: Turso.Query do
  # We do not prepare statements server-side, so parse/describe are identities
  # and encode/decode pass params and results through unchanged.
  def parse(query, _opts), do: query
  def describe(query, _opts), do: query
  def encode(_query, params, _opts), do: params
  def decode(_query, result, _opts), do: result
end

defimpl String.Chars, for: Turso.Query do
  def to_string(%Turso.Query{statement: statement}), do: statement
end
