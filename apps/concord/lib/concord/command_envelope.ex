defmodule Concord.CommandEnvelope do
  @moduledoc false

  @legacy_version 0
  @current_version 1

  @type version :: 0 | 1
  @type t ::
          {:concord_command, non_neg_integer(), term()}
          | {:concord_command, pos_integer(), non_neg_integer(), term()}

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @spec wrap(non_neg_integer(), term()) :: t()
  def wrap(timestamp_ms, command) when is_integer(timestamp_ms) and timestamp_ms >= 0 do
    wrap(timestamp_ms, command, @current_version)
  end

  @spec wrap(non_neg_integer(), term(), version()) :: t()
  def wrap(timestamp_ms, command, @legacy_version)
      when is_integer(timestamp_ms) and timestamp_ms >= 0 do
    {:concord_command, timestamp_ms, command}
  end

  def wrap(timestamp_ms, command, @current_version)
      when is_integer(timestamp_ms) and timestamp_ms >= 0 do
    {:concord_command, @current_version, timestamp_ms, command}
  end

  @spec supported_version?(term()) :: boolean()
  def supported_version?(version), do: version in [@legacy_version, @current_version]

  @spec unwrap(term()) ::
          {:ok, version(), non_neg_integer(), term()}
          | {:error, :invalid_command_envelope | {:unsupported_command_version, term()}}
  def unwrap({:concord_command, @current_version, timestamp_ms, command})
      when is_integer(timestamp_ms) and timestamp_ms >= 0 do
    {:ok, @current_version, timestamp_ms, command}
  end

  # Version 0 was emitted without an explicit version. Keeping this exact shape
  # readable is required to replay WAL entries written before command versioning.
  def unwrap({:concord_command, timestamp_ms, command})
      when is_integer(timestamp_ms) and timestamp_ms >= 0 do
    {:ok, @legacy_version, timestamp_ms, command}
  end

  def unwrap({:concord_command, @current_version, _timestamp_ms, _command}) do
    {:error, :invalid_command_envelope}
  end

  def unwrap({:concord_command, version, _timestamp_ms, _command}) do
    {:error, {:unsupported_command_version, version}}
  end

  def unwrap(_operation), do: {:error, :invalid_command_envelope}
end
