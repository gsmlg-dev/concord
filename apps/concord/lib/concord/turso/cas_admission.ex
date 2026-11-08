defmodule Concord.Turso.CasAdmission do
  @moduledoc false

  # Node-local Turso CAS never enters the replicated VSR log, so its value is
  # not bound by the immutable version-one 16 MiB maximum. Every other
  # version-two CAS rule, including the 64 MiB command ceiling, still applies.

  alias Concord.{CommandSchema, Compression, Validation}

  @max_value_bytes 32 * 1_024 * 1_024

  @doc """
  Returns the logical and encoded value limit for Turso CAS.

  `config :concord, turso: [max_cas_value_bytes: bytes]` may lower, but never
  raise, the 32 MiB maximum.
  """
  @spec max_value_bytes() :: non_neg_integer()
  def max_value_bytes do
    case :concord |> Application.get_env(:turso, []) |> Keyword.get(:max_cas_value_bytes) do
      nil -> @max_value_bytes
      bytes when is_integer(bytes) and bytes >= 0 -> min(bytes, @max_value_bytes)
      # Invalid safety configuration fails closed, as with other admission caps.
      _invalid -> 0
    end
  end

  @doc "Validates a logical value before optional compression."
  @spec validate_value(term()) :: :ok | {:error, atom()}
  def validate_value(value) do
    case validate_stored_value(value, max_value_bytes()) do
      {:ok, _logical} -> :ok
      {:error, {:invalid_command, reason}} -> {:error, reason}
    end
  end

  @doc "Validates an emitted CAS command, including its possibly compressed value."
  @spec validate(term()) :: :ok | {:error, :unsupported_command | {:invalid_command, atom()}}
  def validate({:compare_and_swap, key, value, expected, opts} = command) do
    with :ok <- CommandSchema.validate_emission({:compare_and_swap, key, nil, expected, opts}),
         {:ok, logical} <- validate_stored_value(value, max_value_bytes()),
         :ok <- validate_command_size(command, :raw),
         :ok <- validate_command_size({:compare_and_swap, key, logical, expected, opts}, :logical) do
      :ok
    end
  end

  def validate(_command), do: {:error, :unsupported_command}

  defp validate_stored_value(value, max) do
    with {:ok, _size} <- CommandSchema.raw_external_size_v1(value, max),
         {:ok, logical} <- decode(value, max),
         {:ok, _size} <- CommandSchema.logical_external_size_v1(logical, max),
         :ok <- Validation.validate_term(logical) do
      {:ok, logical}
    else
      {:error, reason} when reason in [:size_limit, :value_too_large] ->
        {:error, {:invalid_command, :value_too_large}}

      {:error, reason} ->
        {:error, {:invalid_command, reason}}
    end
  end

  # Only the top-level envelope produced by `:compress` uses the larger bound;
  # nested envelopes keep the version-one expansion limit.
  defp decode(value, max)
       when is_tuple(value) and tuple_size(value) > 0 and elem(value, 0) == :compressed,
       do: Compression.decode_bounded(value, max)

  defp decode(value, _max), do: {:ok, value}

  defp validate_command_size(command, mode) do
    max = Validation.max_command_bytes()

    result =
      case mode do
        :raw -> CommandSchema.raw_external_size_v1(command, max)
        :logical -> CommandSchema.logical_external_size_v1(command, max)
      end

    case result do
      {:ok, _size} -> :ok
      {:error, :size_limit} -> {:error, {:invalid_command, :command_too_large}}
      {:error, reason} -> {:error, {:invalid_command, reason}}
    end
  end
end
