defmodule Concord.Turso.Codec do
  @moduledoc false

  alias Concord.KV.Record

  @spec encode_record(Record.t()) :: binary()
  def encode_record(%Record{} = record), do: :erlang.term_to_binary(record)

  @spec decode_record(binary()) :: Record.t()
  def decode_record(binary) when is_binary(binary), do: :erlang.binary_to_term(binary)

  @spec encode_record_metadata(Record.t()) :: binary()
  def encode_record_metadata(%Record{} = record),
    do: :erlang.term_to_binary(%{record | value: nil})

  @spec decode_record_metadata(binary()) :: Record.t()
  def decode_record_metadata(binary) when is_binary(binary), do: :erlang.binary_to_term(binary)
end
