defmodule Concord.KV.Selector do
  @moduledoc """
  Unified selector type for addressing keys in Concord.

  Selectors are used across the KV, Transaction, and Sync APIs to specify
  which keys an operation targets. Three forms are supported:

  - `{:key, binary()}` — Exactly one key
  - `{:prefix, binary()}` — All keys starting with the given prefix
  - `{:range, start :: binary(), end_exclusive :: binary()}` — All keys
    in the half-open interval `[start, end)`

  `{:prefix, p}` is sugar for `{:range, p, p <> <<0xFF, 0xFF, ...>>}`.
  """

  @type t ::
          {:key, binary()}
          | {:prefix, binary()}
          | {:range, start :: binary(), end_exclusive :: binary()}

  @doc """
  Validates a selector value.

  Returns `:ok` if valid, `{:error, reason}` otherwise.
  """
  @spec validate(term()) :: :ok | {:error, atom()}
  def validate({:key, key}) when is_binary(key) and byte_size(key) > 0, do: :ok
  def validate({:key, _}), do: {:error, :empty_key}

  def validate({:prefix, prefix}) when is_binary(prefix) and byte_size(prefix) > 0, do: :ok
  def validate({:prefix, _}), do: {:error, :prefix_too_short}

  def validate({:range, start, end_exclusive})
      when is_binary(start) and is_binary(end_exclusive) and start < end_exclusive,
      do: :ok

  def validate({:range, _, _}), do: {:error, :invalid_range}
  def validate(_), do: {:error, :invalid_selector}

  @doc """
  Returns the upper bound binary for a prefix scan.

  For a prefix `p`, the upper bound is `p` with each trailing byte incremented,
  effectively matching all keys that start with `p`.
  """
  @spec prefix_end(binary()) :: binary()
  def prefix_end(prefix) when is_binary(prefix) do
    prefix <> <<0xFF>>
  end

  @doc """
  Checks if a key matches the given selector.
  """
  @spec matches?(t(), binary()) :: boolean()
  def matches?({:key, k}, key), do: k == key

  def matches?({:prefix, p}, key) do
    byte_size(key) >= byte_size(p) and binary_part(key, 0, byte_size(p)) == p
  end

  def matches?({:range, s, e}, key), do: key >= s and key < e
end
