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
          algorithm: :zlib,        # :zlib, :gzip, or :none
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

  @type algorithm :: :zlib | :gzip | :none
  @type compressed_value :: {:compressed, algorithm(), binary()}

  # This is a replicated-command admission limit, not an operator setting.
  # Changing it requires a new command-envelope version.
  @max_decompressed_bytes 16 * 1_024 * 1_024

  @doc """
  Compresses a value if it exceeds the configured size threshold.

  ## Options

  - `:algorithm` - Compression algorithm (:zlib, :gzip, or :none)
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
  def decompress({:compressed, _algorithm, _compressed_binary} = compressed) do
    case decode_with_limit(compressed) do
      {:ok, value} -> value
      # Version-zero values were persisted before an expanded-size limit
      # existed. New command admission never reaches this fallback, but reads
      # and exact legacy replay must remain able to decode those durable bytes.
      {:error, :expanded_size_limit} -> legacy_decode(compressed)
      {:error, :invalid_compressed_value} -> legacy_decode(compressed)
    end
  end

  def decompress(value), do: value

  @doc """
  Safely decompresses and decodes a recognized compression envelope.

  Returns `{:error, :invalid_compressed_value}` for unsupported algorithms,
  malformed compressed data, or an external term larger than the immutable
  replicated-command limit. Logical safety is checked recursively by
  `Concord.Validation` after decoding.
  """
  @spec safe_decompress(term()) :: {:ok, term()} | {:error, :invalid_compressed_value}
  def safe_decompress(compressed) do
    case decode_v1(compressed) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, :invalid_compressed_value}
    end
  end

  @doc false
  @spec decode_v1(term()) ::
          {:ok, term()} | {:error, :invalid_compressed_value | :value_too_large}
  def decode_v1({:compressed, algorithm, compressed_binary} = compressed)
      when algorithm in [:zlib, :gzip, :none] and is_binary(compressed_binary) do
    case decode_with_limit(compressed) do
      {:ok, value} -> {:ok, value}
      {:error, :expanded_size_limit} -> {:error, :value_too_large}
      {:error, :invalid_compressed_value} -> {:error, :invalid_compressed_value}
    end
  rescue
    _error -> {:error, :invalid_compressed_value}
  catch
    _kind, _reason -> {:error, :invalid_compressed_value}
  end

  def decode_v1(_value), do: {:error, :invalid_compressed_value}

  @doc false
  @spec max_decompressed_bytes() :: pos_integer()
  def max_decompressed_bytes, do: @max_decompressed_bytes

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

          try do
            :ok = :zlib.deflateInit(z, level, :deflated, 16 + 15, 8, :default)
            compressed_data = :zlib.deflate(z, binary, :finish)
            :ok = :zlib.deflateEnd(z)
            IO.iodata_to_binary(compressed_data)
          after
            :zlib.close(z)
          end

        :none ->
          binary

        _unsupported ->
          binary
      end

    {:compressed, algorithm, compressed}
  end

  defp decode_with_limit({:compressed, algorithm, compressed_binary})
       when algorithm in [:zlib, :gzip, :none] and is_binary(compressed_binary) do
    if byte_size(compressed_binary) > @max_decompressed_bytes do
      {:error, :expanded_size_limit}
    else
      with {:ok, decompressed} <- bounded_decompress(compressed_binary, algorithm) do
        # `[:safe]` makes decoding depend on the receiving VM's current atom
        # table: identical replicated bytes are accepted only after every atom
        # happens to exist locally. Ordinary decoding is deterministic;
        # Validation.validate_term/1 subsequently rejects funs, PIDs, ports,
        # and references before a command is admitted or applied.
        decode_external_term(decompressed)
      end
    end
  rescue
    _error -> {:error, :invalid_compressed_value}
  catch
    _kind, _reason -> {:error, :invalid_compressed_value}
  end

  defp decode_with_limit(_compressed), do: {:error, :invalid_compressed_value}

  # ETF's own COMPRESSED tag would introduce a second, unbounded inflation
  # step inside binary_to_term/2 and bypass the outer streaming limit. Values
  # emitted by this module always use ordinary (uncompressed) ETF here.
  defp decode_external_term(<<131, 80, _rest::binary>>),
    do: {:error, :invalid_compressed_value}

  defp decode_external_term(binary) do
    {value, used} = :erlang.binary_to_term(binary, [:used])

    if used == byte_size(binary) do
      {:ok, value}
    else
      {:error, :invalid_compressed_value}
    end
  end

  defp legacy_decode({:compressed, algorithm, compressed_binary} = compressed) do
    decompressed =
      case algorithm do
        :zlib -> :zlib.uncompress(compressed_binary)
        :gzip -> legacy_gzip_decompress(compressed_binary)
        _uncompressed_or_unknown -> compressed_binary
      end

    :erlang.binary_to_term(decompressed)
  rescue
    _error -> compressed
  catch
    _kind, _reason -> compressed
  end

  defp legacy_gzip_decompress(compressed_binary) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 16 + 15)
      decompressed = z |> :zlib.inflate(compressed_binary) |> IO.iodata_to_binary()
      :ok = :zlib.inflateEnd(z)
      decompressed
    after
      :zlib.close(z)
    end
  end

  defp bounded_decompress(binary, :none), do: {:ok, binary}

  defp bounded_decompress(compressed_binary, algorithm) do
    z = :zlib.open()

    try do
      window_bits = if algorithm == :gzip, do: 16 + 15, else: 15
      :ok = :zlib.inflateInit(z, window_bits)

      case collect_inflated(z, compressed_binary, 0, []) do
        {:ok, chunks} ->
          :ok = :zlib.inflateEnd(z)
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

        {:error, _reason} = error ->
          error
      end
    after
      :zlib.close(z)
    end
  end

  # safeInflate/2 yields bounded output chunks (16 KiB on current OTP) and
  # retains unconsumed compressed input in the zlib state. Draining with an
  # empty input therefore lets us reject at the limit without first allocating
  # the entire expanded value.
  defp collect_inflated(z, input, total_size, chunks) do
    case :zlib.safeInflate(z, input) do
      {:finished, output} ->
        append_inflated(output, total_size, chunks)

      {:continue, output} ->
        output_size = :erlang.iolist_size(output)

        if output_size == 0 do
          {:error, :invalid_compressed_value}
        else
          case append_inflated(output, total_size, chunks) do
            {:ok, next_chunks} ->
              collect_inflated(z, <<>>, total_size + output_size, next_chunks)

            {:error, _reason} = error ->
              error
          end
        end
    end
  end

  defp append_inflated(output, total_size, chunks) do
    output_size = :erlang.iolist_size(output)

    if total_size + output_size <= @max_decompressed_bytes do
      {:ok, [output | chunks]}
    else
      {:error, :expanded_size_limit}
    end
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
