defmodule Concord.Turso.ConditionalPut do
  @moduledoc false

  alias Concord.{APIOptions, Deadline, Validation}
  alias Concord.Turso.BulkPut

  @spec prepare(term(), keyword()) :: {:ok, tuple()} | {:error, term()}
  def prepare(puts, opts) do
    opts = opts |> APIOptions.turso() |> Deadline.start()
    compares = Keyword.get(opts, :compare, [])

    with :ok <- Deadline.check(opts),
         :ok <- BulkPut.validate_compression(Keyword.get(opts, :compress)),
         :ok <- validate(puts, compares),
         :ok <- Deadline.check(opts),
         {:ok, prepared} <- BulkPut.prepare(puts, opts),
         :ok <- validate(prepared, compares),
         :ok <- Deadline.check(opts) do
      {:ok, {:put_many_if, prepared, compares}}
    end
  end

  @spec validate(term(), term()) :: :ok | {:error, term()}
  def validate(puts, compares) do
    with :ok <- BulkPut.validate(puts, compares, Validation.max_batch_size()) do
      Validation.validate_command_size({:put_many_if, puts, compares})
    end
  end
end
