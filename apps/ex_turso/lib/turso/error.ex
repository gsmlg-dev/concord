defmodule Turso.Error do
  @moduledoc """
  Exception raised or returned when a turso operation fails.

    * `message` — the reason string produced by the native layer (or by
      `Turso` itself for validation errors)
    * `code` — a coarse error class for programmatic handling:
      * `:busy` — the database is locked; the operation may be retried
      * `:constraint` — a constraint (UNIQUE, NOT NULL, ...) was violated
      * `:io` / `:corrupt` — the connection is unusable; the pool drops and
        replaces it
      * `:misuse` — the API was used incorrectly
      * `:invalid_param` — a bound parameter had an unsupported type
      * `:error` — any other native error
      * `nil` — the error originated in the Elixir layer, not the NIF
  """

  defexception [:message, :code]

  @type code :: :busy | :constraint | :io | :corrupt | :misuse | :invalid_param | :error | nil

  @type t :: %__MODULE__{message: String.t(), code: code()}
end
