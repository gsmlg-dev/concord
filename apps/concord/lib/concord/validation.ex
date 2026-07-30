defmodule Concord.Validation do
  @moduledoc """
  Recursive validation for replicated command safety.

  Walks any Elixir term to ensure it contains no anonymous functions, PIDs,
  ports, or references — values that break deterministic serialization.
  Also enforces depth and size limits.
  """

  alias Concord.CommandSchema
  alias Concord.Compression
  alias Concord.KV.Selector

  @max_depth 100

  @doc """
  Validates a Concord key against the configured byte-size limit.

  The default maximum is 4096 bytes and can be changed with
  `config :concord, kv: [max_key_bytes: bytes]`.
  """
  @spec validate_key(term()) :: :ok | {:error, :empty_key | :key_too_large | :invalid_key}
  def validate_key(key) when is_binary(key) do
    cond do
      byte_size(key) == 0 -> {:error, :empty_key}
      byte_size(key) > max_key_bytes() -> {:error, :key_too_large}
      true -> :ok
    end
  end

  def validate_key(_), do: {:error, :invalid_key}

  @doc """
  Validates a logical value before optional compression.

  The configured `:max_value_bytes` is a local admission cap. It may lower,
  but never raise, the immutable version-one protocol maximum. Size is
  measured from the logical Erlang term, so compression settings cannot alter
  whether the value is admitted.
  """
  @spec validate_value(term()) :: :ok | {:error, atom()}
  def validate_value(value) do
    max = max_value_bytes()

    with {:ok, _size} <- CommandSchema.raw_external_size_v1(value, max),
         {:ok, _size} <- CommandSchema.logical_external_size_v1(value, max),
         :ok <- validate_term(value) do
      :ok
    else
      {:error, reason} when reason in [:size_limit, :value_too_large] ->
        {:error, :value_too_large}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec max_batch_size() :: non_neg_integer()
  def max_batch_size do
    :concord
    |> Application.get_env(:max_batch_size, CommandSchema.max_batch_size())
    |> effective_limit(CommandSchema.max_batch_size())
  end

  @doc false
  @spec validate_command_size(term()) :: :ok | {:error, {:invalid_command, atom()}}
  def validate_command_size(command) do
    max = max_command_bytes()

    with {:ok, _size} <- CommandSchema.raw_external_size_v1(command, max),
         {:ok, _size} <- CommandSchema.logical_external_size_v1(command, max) do
      :ok
    else
      {:error, :size_limit} -> {:error, {:invalid_command, :command_too_large}}
      {:error, reason} -> {:error, {:invalid_command, reason}}
    end
  end

  @doc false
  @spec max_command_bytes() :: non_neg_integer()
  def max_command_bytes do
    :concord
    |> Application.get_env(:max_command_bytes, CommandSchema.max_command_bytes())
    |> effective_limit(CommandSchema.max_command_bytes())
  end

  @doc """
  Walks a term recursively, rejecting non-serializable values.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_term(term(), non_neg_integer()) :: :ok | {:error, atom()}
  def validate_term(term, max_depth \\ @max_depth) do
    walk(term, 0, max_depth)
  end

  defp walk(_term, depth, max_depth) when depth > max_depth do
    {:error, :depth_exceeded}
  end

  defp walk(term, _depth, _max_depth) when is_function(term) do
    {:error, :function_in_spec}
  end

  defp walk(term, _depth, _max_depth) when is_pid(term) do
    {:error, :pid_in_spec}
  end

  defp walk(term, _depth, _max_depth) when is_reference(term) do
    {:error, :ref_in_spec}
  end

  defp walk(term, _depth, _max_depth) when is_port(term) do
    {:error, :port_in_spec}
  end

  # Atoms, numbers, and bitstrings are always safe. The bitstring guard keeps
  # non-byte-aligned bitstrings valid as well as ordinary binaries.
  defp walk(term, _depth, _max_depth)
       when is_atom(term) or is_number(term) or is_bitstring(term) do
    :ok
  end

  defp walk([], _depth, _max_depth), do: :ok

  # Match cons cells instead of guarding with is_list/1 so improper-list tails
  # cannot bypass validation. List length does not count as nesting depth.
  defp walk([head | tail], depth, max_depth) do
    with :ok <- walk(head, depth + 1, max_depth) do
      walk_list_tail(tail, depth, max_depth)
    end
  end

  defp walk({:compressed, algorithm, compressed_binary} = compressed, depth, max_depth)
       when algorithm in [:zlib, :gzip, :none] and is_binary(compressed_binary) do
    with {:ok, value} <- Compression.safe_decompress(compressed) do
      walk(value, depth + 1, max_depth)
    end
  end

  defp walk(tuple, _depth, _max_depth)
       when is_tuple(tuple) and tuple_size(tuple) > 0 and elem(tuple, 0) == :compressed do
    {:error, :invalid_compressed_value}
  end

  defp walk(tuple, depth, max_depth) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> walk(depth + 1, max_depth)
  end

  defp walk(map, depth, max_depth) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
      with :ok <- walk(key, depth + 1, max_depth),
           :ok <- walk(value, depth + 1, max_depth) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  # Every Erlang term type is handled above. Fail closed if a future runtime
  # introduces another type instead of silently accepting it for replication.
  defp walk(_term, _depth, _max_depth), do: {:error, :unsupported_term}

  defp walk_list_tail([], _depth, _max_depth), do: :ok

  defp walk_list_tail([_head | _tail] = tail, depth, max_depth) do
    walk(tail, depth, max_depth)
  end

  defp walk_list_tail(tail, depth, max_depth) do
    walk(tail, depth + 1, max_depth)
  end

  # ──────────────────────────────────────────────
  # Transaction spec validation
  # ──────────────────────────────────────────────

  @doc """
  Validates a transaction spec before replicated submission.

  Checks structural correctness, limit compliance, and recursive safety.
  """
  @spec validate_txn_spec(map()) :: :ok | {:error, {:invalid_txn, atom()}}
  def validate_txn_spec(spec) when is_map(spec) do
    config = txn_config()

    with :ok <- validate_txn_collections(spec),
         :ok <- validate_idempotency_key(spec),
         :ok <- check_compare_count(spec, config),
         :ok <- check_success_count(spec, config),
         :ok <- check_failure_count(spec, config),
         :ok <- validate_compares(Map.get(spec, :compare, [])),
         :ok <- validate_operations(Map.get(spec, :success, []), config),
         :ok <- validate_operations(Map.get(spec, :failure, []), config),
         :ok <- validate_term(spec),
         :ok <- check_spec_size(spec, config) do
      :ok
    end
  end

  def validate_txn_spec(_), do: {:error, {:invalid_txn, :invalid_spec}}

  defp txn_config do
    Application.get_env(:concord, :txn, [])
  end

  defp max_key_bytes do
    :concord
    |> Application.get_env(:kv, [])
    |> Keyword.get(:max_key_bytes, CommandSchema.max_key_bytes())
    |> effective_limit(CommandSchema.max_key_bytes())
  end

  defp max_value_bytes do
    :concord
    |> Application.get_env(:kv, [])
    |> Keyword.get(:max_value_bytes, CommandSchema.max_value_bytes())
    |> effective_limit(CommandSchema.max_value_bytes())
  end

  defp check_compare_count(spec, config) do
    max =
      config
      |> Keyword.get(:max_compare_ops, CommandSchema.max_txn_compares())
      |> effective_limit(CommandSchema.max_txn_compares())

    if length(Map.get(spec, :compare, [])) > max,
      do: {:error, {:invalid_txn, :too_many_compares}},
      else: :ok
  end

  defp check_success_count(spec, config) do
    max =
      config
      |> Keyword.get(:max_success_ops, CommandSchema.max_txn_operations())
      |> effective_limit(CommandSchema.max_txn_operations())

    if length(Map.get(spec, :success, [])) > max,
      do: {:error, {:invalid_txn, :too_many_success_ops}},
      else: :ok
  end

  defp check_failure_count(spec, config) do
    max =
      config
      |> Keyword.get(:max_failure_ops, CommandSchema.max_txn_operations())
      |> effective_limit(CommandSchema.max_txn_operations())

    if length(Map.get(spec, :failure, [])) > max,
      do: {:error, {:invalid_txn, :too_many_failure_ops}},
      else: :ok
  end

  defp check_spec_size(spec, config) do
    max =
      config
      |> Keyword.get(:max_txn_bytes, CommandSchema.max_txn_bytes())
      |> effective_limit(CommandSchema.max_txn_bytes())

    with {:ok, _size} <- CommandSchema.raw_external_size_v1(spec, max),
         {:ok, _size} <- CommandSchema.logical_external_size_v1(spec, max) do
      :ok
    else
      {:error, reason} when reason in [:size_limit, :value_too_large] ->
        {:error, {:invalid_txn, :spec_too_large}}

      {:error, _reason} ->
        {:error, {:invalid_txn, :invalid_spec}}
    end
  end

  defp validate_txn_collections(spec) do
    valid_keys? = only_keys?(spec, [:compare, :success, :failure, :idempotency_key])

    valid_collections? =
      Enum.all?([:compare, :success, :failure], fn key ->
        spec |> Map.get(key, []) |> is_list()
      end)

    if valid_keys? and valid_collections? do
      :ok
    else
      {:error, {:invalid_txn, :invalid_spec}}
    end
  end

  defp validate_idempotency_key(spec) do
    case Map.get(spec, :idempotency_key) do
      nil -> :ok
      key when is_binary(key) and byte_size(key) > 0 -> validate_txn_key(key)
      _invalid -> {:error, {:invalid_txn, :invalid_idempotency_key}}
    end
  end

  @valid_compare_fields [
    :exists,
    :value,
    :field,
    :version,
    :create_revision,
    :mod_revision,
    :lease,
    :ttl
  ]
  @valid_compare_ops [:==, :!=, :>, :>=, :<, :<=]

  defp validate_compares(compares) do
    Enum.reduce_while(compares, :ok, fn compare, :ok ->
      case validate_compare(compare) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_compare({field, key, op, value})
       when field in @valid_compare_fields and field != :field and is_binary(key) and
              op in @valid_compare_ops,
       do: validate_txn_key_and_value(key, value)

  defp validate_compare({:field, key, path, op, value})
       when is_binary(key) and is_list(path) and op in @valid_compare_ops,
       do: validate_field_compare(key, path, value)

  defp validate_compare({field, _, _, _}) when field not in @valid_compare_fields,
    do: {:error, {:invalid_txn, :unsupported_compare_field}}

  defp validate_compare({_, _, op, _}) when op not in @valid_compare_ops,
    do: {:error, {:invalid_txn, :unsupported_compare_op}}

  defp validate_compare(_), do: {:error, {:invalid_txn, :invalid_compare}}

  defp validate_operations(ops, config) do
    max_range_limit =
      config
      |> Keyword.get(:max_range_limit, CommandSchema.max_txn_range_limit())
      |> effective_limit(CommandSchema.max_txn_range_limit())

    Enum.reduce_while(ops, :ok, fn op, :ok ->
      case validate_operation(op, max_range_limit) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_operation({:get, selector, %{} = opts}, max_range),
    do: validate_get_operation(selector, opts, max_range)

  defp validate_operation({:put, key, value, %{} = opts}, _max_range) when is_binary(key) do
    ttl = Map.get(opts, :ttl)
    lease = Map.get(opts, :lease)

    with :ok <- validate_txn_key(key),
         :ok <- validate_txn_value(value),
         :ok <- validate_txn_ttl(ttl),
         :ok <- validate_txn_lease(lease),
         :ok <- validate_txn_put_metadata(opts) do
      if ttl != nil and lease != nil do
        {:error, {:invalid_txn, :ttl_and_lease_conflict}}
      else
        :ok
      end
    end
  end

  defp validate_operation({:delete, selector, %{} = opts}, _max_range) do
    with :ok <- validate_delete_options(opts) do
      validate_txn_selector(selector)
    end
  end

  defp validate_operation({:touch, key, ttl, %{} = opts}, _max_range)
       when is_binary(key) and is_integer(ttl) and ttl > 0 and map_size(opts) == 0,
       do: validate_txn_key(key)

  defp validate_operation(_, _), do: {:error, {:invalid_txn, :unsupported_op}}

  defp validate_field_compare(key, path, value) do
    with :ok <- validate_txn_key(key) do
      if Enum.all?(path, &(is_atom(&1) or is_binary(&1))) do
        validate_txn_value(value)
      else
        {:error, {:invalid_txn, :invalid_field_path}}
      end
    end
  end

  defp validate_get_operation({:key, key}, opts, _max_range) do
    limit = Map.get(opts, :limit)

    cond do
      not only_keys?(opts, [:limit]) ->
        {:error, {:invalid_txn, :invalid_get_options}}

      not is_nil(limit) and (not is_integer(limit) or limit <= 0) ->
        {:error, {:invalid_txn, :invalid_range_limit}}

      true ->
        validate_txn_key(key)
    end
  end

  defp validate_get_operation(selector, opts, max_range)
       when elem(selector, 0) in [:prefix, :range] do
    limit = Map.get(opts, :limit)

    cond do
      not only_keys?(opts, [:limit]) ->
        {:error, {:invalid_txn, :invalid_get_options}}

      is_nil(limit) ->
        {:error, {:invalid_txn, :missing_range_limit}}

      not is_integer(limit) or limit <= 0 ->
        {:error, {:invalid_txn, :invalid_range_limit}}

      limit > max_range ->
        {:error, {:invalid_txn, :range_limit_too_high}}

      true ->
        validate_txn_selector(selector)
    end
  end

  defp validate_get_operation(_selector, _opts, _max_range),
    do: {:error, {:invalid_txn, :invalid_selector}}

  defp validate_txn_ttl(nil), do: :ok
  defp validate_txn_ttl(:infinity), do: :ok
  defp validate_txn_ttl(ttl) when is_integer(ttl) and ttl > 0, do: :ok
  defp validate_txn_ttl(_ttl), do: {:error, {:invalid_txn, :invalid_ttl}}

  defp validate_txn_lease(nil), do: :ok
  defp validate_txn_lease(lease) when is_integer(lease) and lease > 0, do: :ok
  defp validate_txn_lease(_lease), do: {:error, {:invalid_txn, :invalid_lease}}

  defp validate_txn_put_metadata(opts) do
    content_type = Map.get(opts, :content_type)
    metadata = Map.get(opts, :metadata, %{})
    prev_kv = Map.get(opts, :prev_kv, false)

    cond do
      not only_keys?(opts, [:ttl, :lease, :content_type, :metadata, :prev_kv]) ->
        {:error, {:invalid_txn, :invalid_put_options}}

      not is_nil(content_type) and not is_binary(content_type) ->
        {:error, {:invalid_txn, :invalid_content_type}}

      not is_map(metadata) ->
        {:error, {:invalid_txn, :invalid_metadata}}

      not is_boolean(prev_kv) ->
        {:error, {:invalid_txn, :invalid_prev_kv}}

      true ->
        :ok
    end
  end

  defp validate_delete_options(opts) do
    if only_keys?(opts, [:prev_kv]) and is_boolean(Map.get(opts, :prev_kv, false)) do
      :ok
    else
      {:error, {:invalid_txn, :invalid_prev_kv}}
    end
  end

  defp validate_txn_key(key) do
    case validate_key(key) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_txn, reason}}
    end
  end

  defp validate_txn_key_and_value(key, value) do
    with :ok <- validate_txn_key(key) do
      validate_txn_value(value)
    end
  end

  defp validate_txn_value(value) do
    case validate_value(value) do
      :ok -> :ok
      {:error, :value_too_large} -> {:error, {:invalid_txn, :value_too_large}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_txn_selector(selector) do
    case Selector.validate(selector) do
      :ok -> validate_txn_selector_boundaries(selector)
      {:error, _} -> {:error, {:invalid_txn, :invalid_selector}}
    end
  end

  defp validate_txn_selector_boundaries({:key, key}), do: validate_txn_key(key)

  defp validate_txn_selector_boundaries({:prefix, prefix}),
    do: validate_txn_boundary(prefix)

  defp validate_txn_selector_boundaries({:range, start_key, end_key}) do
    with :ok <- validate_txn_boundary(start_key) do
      validate_txn_boundary(end_key)
    end
  end

  defp validate_txn_boundary(boundary) do
    if byte_size(boundary) > max_key_bytes(),
      do: {:error, {:invalid_txn, :key_too_large}},
      else: :ok
  end

  defp effective_limit(configured, protocol_max)
       when is_integer(configured) and configured >= 0,
       do: min(configured, protocol_max)

  # Invalid safety configuration fails closed instead of silently widening to
  # the protocol maximum. A zero effective cap makes the mistake immediately
  # visible through ordinary validation errors without admitting data.
  defp effective_limit(_configured, _protocol_max), do: 0

  defp only_keys?(map, allowed) do
    map
    |> Map.keys()
    |> Enum.all?(&(&1 in allowed))
  end
end
