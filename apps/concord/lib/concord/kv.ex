defmodule Concord.KV do
  @moduledoc """
  Public API for Concord's revisioned key-value store.

  `Concord.KV` provides the canonical interface for reading and writing keys.
  Every mutation produces a `%Concord.KV.Record{}` with MVCC metadata
  (revision, version, content_type, etc.).

  ## Basic Usage

      # Simple get/put (backward-compatible)
      :ok = Concord.KV.put("key", "value")
      {:ok, "value"} = Concord.KV.get("key")

      # With full record metadata
      {:ok, %Concord.KV.Record{}} = Concord.KV.get("key", metadata: true)

      # With content type and metadata
      Concord.KV.put("notes/001", body, content_type: "text/markdown", metadata: %{author: "ci"})

  ## Range and Prefix Queries

      {:ok, records, %{has_more: false}} = Concord.KV.list(prefix: "/notes/", limit: 100)
      {:ok, records, cursor} = Concord.KV.list(range: {"a", "z"}, limit: 50, keys_only: true)

  ## Cluster Revision

      {:ok, 1843} = Concord.KV.revision()

  ## Read consistency

  The `:eventual`, `:leader`, and `:strong` consistency names are retained for
  API compatibility. The VSR engine currently routes all three through the
  same quorum-confirmed, linearizable read barrier.
  """

  require Logger

  alias Concord.{Compression, Engine, Validation}
  alias Concord.KV.Record

  @timeout 5_000
  @default_list_limit 1_000
  @max_list_limit 10_000

  # ──────────────────────────────────────────────
  # Reads
  # ──────────────────────────────────────────────

  @doc """
  Retrieves a value by key.

  ## Options

  - `:metadata` — if `true`, returns `{:ok, %Record{}}` instead of `{:ok, value}`
  - `:revision` — read the value as of a specific cluster revision (time-travel)
  - `:consistency` — compatibility name for the shared linearizable read path:
    `:eventual`, `:leader` (default), or `:strong`
  - `:timeout` — operation timeout in ms (default: 5000)
  """
  @spec get(binary(), keyword()) :: {:ok, term()} | {:ok, Record.t()} | {:error, term()}
  def get(key, opts \\ []) do
    with :ok <- validate_key(key) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      consistency = Keyword.get(opts, :consistency, default_consistency())
      with_metadata = Keyword.get(opts, :metadata, false)
      revision = Keyword.get(opts, :revision)

      query_cmd =
        cond do
          revision != nil -> {:get, key, revision: revision}
          with_metadata -> {:get_record, key}
          true -> {:get, key}
        end

      case do_query(query_cmd, timeout, consistency, opts) do
        {:ok, %Record{} = record} when not with_metadata ->
          {:ok, Compression.decompress(record.value)}

        {:ok, %Record{} = record} ->
          {:ok, %{record | value: Compression.decompress(record.value)}}

        {:ok, value} when not is_struct(value, Record) ->
          {:ok, Compression.decompress(value)}

        other ->
          other
      end
    end
  end

  @doc """
  Returns the current cluster revision.
  """
  @spec revision(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revision(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    consistency = Keyword.get(opts, :consistency, default_consistency())
    do_query(:get_revision, timeout, consistency, opts)
  end

  @doc """
  Returns the revision history of a single key.

  ## Options

  - `:from_revision` — start of revision range (inclusive)
  - `:to_revision` — end of revision range (inclusive)
  - `:limit` — max records to return (default: 100)
  """
  @spec history(binary(), keyword()) :: {:ok, [Record.t()]} | {:error, term()}
  def history(key, opts \\ []) do
    with :ok <- validate_key(key) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      consistency = Keyword.get(opts, :consistency, default_consistency())

      query_cmd = {:history, key, Keyword.drop(opts, [:engine])}
      do_query(query_cmd, timeout, consistency, opts)
    end
  end

  @doc """
  Lists keys matching a prefix or range selector.

  ## Options

  - `:prefix` — prefix to match (mutually exclusive with `:range`)
  - `:range` — `{start, end_exclusive}` tuple (mutually exclusive with `:prefix`)
  - `:limit` — max results (default: 1000, max: 10000)
  - `:keys_only` — omit values (default: false)
  - `:revision` — snapshot read at a specific revision
  - `:timeout` — operation timeout in ms (default: 5000)
  - `:consistency` — compatibility name for the shared linearizable read path
    (default: `:leader`)

  ## Returns

  `{:ok, [Record.t()], %{has_more: boolean, last_key: binary | nil}}`
  """
  @spec list(keyword()) :: {:ok, [Record.t()], map()} | {:error, term()}
  def list(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    consistency = Keyword.get(opts, :consistency, default_consistency())
    limit = opts |> Keyword.get(:limit, @default_list_limit) |> min(@max_list_limit) |> max(1)

    query_cmd =
      cond do
        Keyword.has_key?(opts, :prefix) ->
          {:list, {:prefix, Keyword.fetch!(opts, :prefix)},
           %{
             limit: limit,
             keys_only: Keyword.get(opts, :keys_only, false),
             revision: Keyword.get(opts, :revision)
           }}

        Keyword.has_key?(opts, :range) ->
          {start_key, end_key} = Keyword.fetch!(opts, :range)

          {:list, {:range, start_key, end_key},
           %{
             limit: limit,
             keys_only: Keyword.get(opts, :keys_only, false),
             revision: Keyword.get(opts, :revision)
           }}

        true ->
          {:error, :missing_selector}
      end

    case query_cmd do
      {:error, reason} -> {:error, reason}
      _ -> do_query(query_cmd, timeout, consistency, opts)
    end
  end

  # ──────────────────────────────────────────────
  # Writes
  # ──────────────────────────────────────────────

  @doc """
  Stores a key-value pair.

  ## Options

  - `:ttl` — time-to-live in seconds
  - `:lease` — attach to an existing lease ID
  - `:content_type` — MIME-ish content type hint
  - `:metadata` — application-level metadata map
  - `:compress` — override automatic compression
  - `:timeout` — operation timeout in ms (default: 5000)

  ## Returns

  `{:ok, %{revision: integer, prev_kv: Record.t() | nil}}`
  """
  @spec put(binary(), term(), keyword()) ::
          {:ok, map()} | :ok | {:error, term()}
  def put(key, value, opts \\ []) do
    with :ok <- validate_key(key),
         :ok <- validate_ttl_option(opts) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      compressed_value = maybe_compress(value, opts)

      cmd =
        {:put, key, compressed_value,
         %{
           ttl: Keyword.get(opts, :ttl),
           lease: Keyword.get(opts, :lease),
           content_type: Keyword.get(opts, :content_type),
           metadata: Keyword.get(opts, :metadata, %{}),
           prev_kv: Keyword.get(opts, :prev_kv, false)
         }}

      case do_command(cmd, timeout, opts) do
        {:ok, result, _} -> {:ok, result}
        {:timeout, _} -> {:error, :timeout}
        {:error, :noproc} -> {:error, :cluster_not_ready}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Deletes a key.

  Returns `{:ok, %{revision: integer, prev_kv: Record.t() | nil}}`.
  """
  @spec delete(binary(), keyword()) :: {:ok, map()} | :ok | {:error, term()}
  def delete(key, opts \\ []) do
    with :ok <- validate_key(key) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      prev_kv = Keyword.get(opts, :prev_kv, false)

      cmd = {:delete, key, %{prev_kv: prev_kv}}

      case do_command(cmd, timeout, opts) do
        {:ok, result, _} -> {:ok, result}
        {:timeout, _} -> {:error, :timeout}
        {:error, :noproc} -> {:error, :cluster_not_ready}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Creates a key only if it does not already exist.

  Implemented as a transaction wrapper.
  """
  @spec create(binary(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(key, value, opts \\ []) do
    with :ok <- validate_key(key) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      compressed_value = maybe_compress(value, opts)

      cmd =
        {:txn,
         %{
           compare: [{:exists, key, :==, false}],
           success: [{:put, key, compressed_value, %{}}],
           failure: [{:get, {:key, key}, %{}}]
         }}

      case do_command(cmd, timeout, opts) do
        {:ok, {:ok, %{succeeded: true} = result}, _} -> {:ok, result}
        {:ok, {:ok, %{succeeded: false} = result}, _} -> {:ok, result}
        {:ok, %{succeeded: true} = result, _} -> {:ok, result}
        {:ok, %{succeeded: false} = result, _} -> {:ok, result}
        {:timeout, _} -> {:error, :timeout}
        {:error, :noproc} -> {:error, :cluster_not_ready}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Replaces a key only if it already exists.

  Implemented as a transaction wrapper.
  """
  @spec replace(binary(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def replace(key, value, opts \\ []) do
    with :ok <- validate_key(key) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      compressed_value = maybe_compress(value, opts)

      cmd =
        {:txn,
         %{
           compare: [{:exists, key, :==, true}],
           success: [{:put, key, compressed_value, %{prev_kv: true}}],
           failure: []
         }}

      case do_command(cmd, timeout, opts) do
        {:ok, {:ok, result}, _} -> {:ok, result}
        {:ok, result, _} -> {:ok, result}
        {:timeout, _} -> {:error, :timeout}
        {:error, :noproc} -> {:error, :cluster_not_ready}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Updates a key only if its `mod_revision` matches the expected value.

  Implemented as a transaction wrapper.
  """
  @spec update_if(binary(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_if(key, value, opts \\ []) do
    with :ok <- validate_key(key) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      mod_revision = Keyword.fetch!(opts, :mod_revision)
      compressed_value = maybe_compress(value, opts)

      cmd =
        {:txn,
         %{
           compare: [{:mod_revision, key, :==, mod_revision}],
           success: [{:put, key, compressed_value, %{prev_kv: true}}],
           failure: [{:get, {:key, key}, %{}}]
         }}

      case do_command(cmd, timeout, opts) do
        {:ok, {:ok, result}, _} -> {:ok, result}
        {:ok, result, _} -> {:ok, result}
        {:timeout, _} -> {:error, :timeout}
        {:error, :noproc} -> {:error, :cluster_not_ready}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Deletes a key only if its `mod_revision` matches the expected value.

  Implemented as a transaction wrapper.
  """
  @spec delete_if(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete_if(key, opts \\ []) do
    with :ok <- validate_key(key) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      mod_revision = Keyword.fetch!(opts, :mod_revision)

      cmd =
        {:txn,
         %{
           compare: [{:mod_revision, key, :==, mod_revision}],
           success: [{:delete, {:key, key}, %{prev_kv: true}}],
           failure: [{:get, {:key, key}, %{}}]
         }}

      case do_command(cmd, timeout, opts) do
        {:ok, {:ok, result}, _} -> {:ok, result}
        {:ok, result, _} -> {:ok, result}
        {:timeout, _} -> {:error, :timeout}
        {:error, :noproc} -> {:error, :cluster_not_ready}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ──────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────

  defp do_command(cmd, timeout, opts) do
    engine_opts = Keyword.take(opts, [:engine])

    case Engine.command(cmd, Keyword.put(engine_opts, :timeout, timeout)) do
      {:ok, result} -> {:ok, result, Engine.engine(engine_opts)}
      {:error, :timeout} -> {:timeout, nil}
      {:error, :cluster_not_ready} -> {:error, :noproc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_query(query_cmd, timeout, consistency, opts) do
    engine_opts = Keyword.take(opts, [:engine])

    case Engine.query(
           query_cmd,
           Keyword.merge(engine_opts, timeout: timeout, consistency: consistency)
         ) do
      {:ok, query_result} -> query_result
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_consistency do
    Application.get_env(:concord, :default_read_consistency, :leader)
  end

  defp maybe_compress(value, opts) do
    case Keyword.get(opts, :compress) do
      true -> Compression.compress(value, force: true)
      false -> value
      nil -> Compression.compress(value)
    end
  end

  defp validate_key(key) do
    case Validation.validate_key(key) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_key}
    end
  end

  defp validate_ttl_option(opts) do
    case Keyword.get(opts, :ttl) do
      nil -> :ok
      ttl when is_integer(ttl) and ttl > 0 -> :ok
      :infinity -> :ok
      _ -> {:error, :invalid_ttl}
    end
  end
end
