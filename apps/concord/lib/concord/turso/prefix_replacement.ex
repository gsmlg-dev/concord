defmodule Concord.Turso.PrefixReplacement do
  @moduledoc false

  alias Concord.{APIOptions, Deadline, Validation}
  alias Concord.Turso.BulkPut

  @max_puts 501

  @spec prepare(term(), term(), keyword()) :: {:ok, tuple()} | {:error, term()}
  def prepare(prefix, puts, opts) do
    opts = opts |> APIOptions.turso() |> Deadline.start()
    compares = Keyword.get(opts, :compare, [])

    with :ok <- Deadline.check(opts),
         :ok <- BulkPut.validate_compression(Keyword.get(opts, :compress)),
         :ok <- validate(prefix, puts, compares),
         :ok <- Deadline.check(opts),
         {:ok, prepared} <- BulkPut.prepare(puts, opts),
         :ok <- validate(prefix, prepared, compares),
         :ok <- Deadline.check(opts) do
      {:ok, {:replace_prefix, prefix, prepared, compares}}
    end
  end

  @spec validate(term(), term(), term()) :: :ok | {:error, term()}
  def validate(prefix, puts, compares) do
    with :ok <- Validation.validate_key(prefix),
         :ok <- BulkPut.validate(puts, compares, max_puts()) do
      Validation.validate_command_size({:replace_prefix, prefix, puts, compares})
    end
  end

  defp max_puts do
    case Application.get_env(:concord, :max_batch_size, @max_puts) do
      maximum when is_integer(maximum) and maximum >= 0 -> min(maximum, @max_puts)
      _invalid -> 0
    end
  end
end
