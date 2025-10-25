defmodule Concord.Compression do
  @moduledoc """
  Value compression for Concord KV store.

  Provides transparent compression for large values to reduce memory usage
  and improve performance. Compression is automatically applied based on
  configurable size thresholds.

  ## Configuration

      config :concord,
        compression: [
          enabled: true,
          algorithm: :zlib,        # :zlib or :gzip
          threshold_bytes: 1024,   # Compress values larger than 1KB
          level: 6                 # Compression level 0-9 (0=none, 9=max)
        ]

  ## Compression Format

  Compressed values are stored as tuples: `{:compressed, algorithm, binary}`
  Uncompressed values are stored as-is.

  ## Examples

      # Compress a value
      compressed = Concord.Compression.compress("large data...")
      # {:compressed, :zlib, <<...>>}

      # Decompress automatically
      value = Concord.Compression.decompress(compressed)
      # "large data..."

      # Check if value should be compressed
      Concord.Compression.should_compress?("small")  # false
      Concord.Compression.should_compress?(large_data)  # true
  """

  @type algorithm :: :zlib | :gzip
  @type compressed_value :: {:compressed, algorithm(), binary()}

  @doc """
  Compresses a value if it exceeds the configured size threshold.

  ## Options

  - `:algorithm` - Compression algorithm (:zlib or :gzip)
  - `:level` - Compression level 0-9 (default: 6)
  - `:force` - Force compression regardless of size (default: false)

  ## Examples

      iex> Concord.Compression.compress("small value")
      "small value"

      iex> large_value = String.duplicate("x", 2048)
      iex> Concord.Compression.compress(large_value)
      {:compressed, :zlib, <<...>>}

      iex> Concord.Compression.compress("force compress", force: true)
      {:compressed, :zlib, <<...>>}
  """
  @spec compress(term(), keyword()) :: term() | compressed_value()
  def compress(value, opts \\ []) do
    if compression_enabled?() or Keyword.get(opts, :force, false) do
      if should_compress?(value, opts) do
        do_compress(value, opts)
      else
        value
      end
    else
      value
    end
  end

  @doc """
  Decompresses a value if it was compressed.

  Automatically detects compressed values and decompresses them.
  Non-compressed values are returned as-is.

  ## Examples

      iex> Concord.Compression.decompress("plain value")
      "plain value"

      iex> compressed = {:compressed, :zlib, binary}
      iex> Concord.Compression.decompress(compressed)
      "original value"
  """
  @spec decompress(term() | compressed_value()) :: term()
  def decompress({:compressed, algorithm, compressed_binary}) do
    do_decompress(compressed_binary, algorithm)
  end

  def decompress(value), do: value

  @doc """
  Checks if a value should be compressed based on size threshold.

  ## Examples

      iex> Concord.Compression.should_compress?("small")
      false

      iex> large = String.duplicate("x", 2048)
      iex> Concord.Compression.should_compress?(large)
      true
  """
  @spec should_compress?(term(), keyword()) :: boolean()
  def should_compress?(value, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, threshold_bytes())
    value_size = :erlang.external_size(value)
    value_size >= threshold
  end

  @doc """
  Returns compression statistics for a value.

  ## Examples

      iex> value = String.duplicate("x", 2048)
      iex> Concord.Compression.stats(value)
      %{
        original_size: 2048,
        compressed_size: 45,
        compression_ratio: 45.5,
        savings_bytes: 2003,
        savings_percent: 97.8
      }
  """
  @spec stats(term()) :: map()
  def stats(value) do
    original_size = :erlang.external_size(value)
    compressed = do_compress(value, [])
    compressed_size = :erlang.external_size(compressed)

    savings_bytes = original_size - compressed_size

    savings_percent =
      if original_size > 0 do
        savings_bytes / original_size * 100
      else
        0
      end

    %{
      original_size: original_size,
      compressed_size: compressed_size,
      compression_ratio:
        if(original_size > 0, do: compressed_size / original_size * 100, else: 0),
      savings_bytes: max(0, savings_bytes),
      savings_percent: max(0, savings_percent)
    }
  end

  @doc """
  Returns the compression configuration.
  """
  @spec config() :: keyword()
  def config do
    Application.get_env(:concord, :compression,
      enabled: true,
      algorithm: :zlib,
      threshold_bytes: 1024,
      level: 6
    )
  end

  # Private functions

  defp do_compress(value, opts) do
    algorithm = Keyword.get(opts, :algorithm, compression_algorithm())
    level = Keyword.get(opts, :level, compression_level())

    # Serialize the value first
    binary = :erlang.term_to_binary(value)

    # Compress based on algorithm
    compressed =
      case algorithm do
        :zlib ->
          :zlib.compress(binary)

        :gzip ->
          z = :zlib.open()
          :zlib.deflateInit(z, level, :deflated, 16 + 15, 8, :default)
          compressed_data = :zlib.deflate(z, binary, :finish)
          :zlib.deflateEnd(z)
          :zlib.close(z)
          IO.iodata_to_binary(compressed_data)

        _ ->
          binary
      end

    {:compressed, algorithm, compressed}
  end

  defp do_decompress(compressed_binary, algorithm) do
    # Decompress based on algorithm
    decompressed =
      case algorithm do
        :zlib ->
          :zlib.uncompress(compressed_binary)

        :gzip ->
          z = :zlib.open()
          :zlib.inflateInit(z, 16 + 15)
          decompressed_data = :zlib.inflate(z, compressed_binary)
          :zlib.inflateEnd(z)
          :zlib.close(z)
          IO.iodata_to_binary(decompressed_data)

        _ ->
          compressed_binary
      end

    # Deserialize back to term
    :erlang.binary_to_term(decompressed)
  end

  defp compression_enabled? do
    config() |> Keyword.get(:enabled, true)
  end

  defp compression_algorithm do
    config() |> Keyword.get(:algorithm, :zlib)
  end

  defp compression_level do
    config() |> Keyword.get(:level, 6)
  end

  defp threshold_bytes do
    config() |> Keyword.get(:threshold_bytes, 1024)
  end
end
