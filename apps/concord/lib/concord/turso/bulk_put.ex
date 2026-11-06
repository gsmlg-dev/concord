defmodule Concord.Turso.BulkPut do
  @moduledoc false

  alias Concord.{Compression, Deadline, Validation}

  @spec validate(term(), term(), non_neg_integer()) :: :ok | {:error, term()}
  def validate(puts, compares, maximum) do
    with :ok <- validate_puts(puts, %{}, 0, maximum),
         :ok <- validate_compare_collections(compares) do
      Validation.validate_txn_spec(%{compare: compares})
    end
  end

  @spec validate_puts(term(), map(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp validate_puts([], _keys, _count, _maximum), do: :ok

  defp validate_puts([_put | _rest], _keys, count, maximum) when count >= maximum,
    do: {:error, :batch_too_large}

  defp validate_puts([{key, value} | rest], keys, count, maximum) do
    with :ok <- Validation.validate_key(key),
         :ok <- unique_key(key, keys),
         :ok <- Validation.validate_value(value, engine: :turso) do
      validate_puts(rest, Map.put(keys, key, true), count + 1, maximum)
    end
  end

  defp validate_puts(_puts, _keys, _count, _maximum),
    do: {:error, :invalid_operation_format}

  @spec unique_key(binary(), map()) :: :ok | {:error, :duplicate_key}
  defp unique_key(key, keys) do
    if Map.has_key?(keys, key), do: {:error, :duplicate_key}, else: :ok
  end

  defp validate_compare_collections([]), do: :ok

  defp validate_compare_collections([{:field, _key, path, _op, _value} | rest])
       when is_list(path) do
    if proper_list?(path),
      do: validate_compare_collections(rest),
      else: {:error, {:invalid_txn, :invalid_field_path}}
  end

  defp validate_compare_collections([_compare | rest]), do: validate_compare_collections(rest)
  defp validate_compare_collections(_compares), do: {:error, {:invalid_txn, :invalid_spec}}

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  @spec prepare([{binary(), term()}], keyword()) :: {:ok, list()} | {:error, term()}
  def prepare(puts, opts) do
    Enum.reduce_while(puts, {:ok, []}, fn {key, value}, {:ok, prepared} ->
      with :ok <- Deadline.check(opts),
           compressed = compress(value, Keyword.get(opts, :compress)),
           :ok <- Deadline.check(opts) do
        {:cont, {:ok, [{key, compressed} | prepared]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      error -> error
    end
  end

  def validate_compression(choice) when choice in [nil, true, false], do: :ok
  def validate_compression(_choice), do: {:error, :invalid_compress}

  defp compress(value, true), do: Compression.compress(value, force: true)
  defp compress(value, false), do: value
  defp compress(value, nil), do: Compression.compress(value)
end
