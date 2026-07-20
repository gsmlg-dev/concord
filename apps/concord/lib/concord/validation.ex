defmodule Concord.Validation do
  @moduledoc """
  Recursive validation for replicated command safety.

  Walks any Elixir term to ensure it contains no anonymous functions, PIDs,
  ports, or references — values that break deterministic serialization.
  Also enforces depth and size limits.
  """

  alias Concord.KV.Selector

  @max_depth 100
  @default_max_key_bytes 4_096

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
    {:error, :pid_in_spec}
  end

  # Atoms, numbers, binaries are always safe
  defp walk(term, _depth, _max_depth)
       when is_atom(term) or is_number(term) or is_binary(term) do
    :ok
  end

  defp walk(list, depth, max_depth) when is_list(list) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case walk(item, depth + 1, max_depth) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp walk(tuple, depth, max_depth) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> walk(depth + 1, max_depth)
  end

  defp walk(%{__struct__: _} = struct, depth, max_depth) do
    struct
    |> Map.from_struct()
    |> walk(depth, max_depth)
  end

  defp walk(map, depth, max_depth) when is_map(map) do
    Enum.reduce_while(map, :ok, fn {k, v}, :ok ->
      with :ok <- walk(k, depth + 1, max_depth),
           :ok <- walk(v, depth + 1, max_depth) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  # MapSet, other containers
  defp walk(_term, _depth, _max_depth), do: :ok

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

    with :ok <- check_compare_count(spec, config),
         :ok <- check_success_count(spec, config),
         :ok <- check_failure_count(spec, config),
         :ok <- check_spec_size(spec, config),
         :ok <- validate_compares(Map.get(spec, :compare, [])),
         :ok <- validate_operations(Map.get(spec, :success, []), config),
         :ok <- validate_operations(Map.get(spec, :failure, []), config),
         :ok <- validate_term(spec) do
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
    |> Keyword.get(:max_key_bytes, @default_max_key_bytes)
  end

  defp check_compare_count(spec, config) do
    max = Keyword.get(config, :max_compare_ops, 64)

    if length(Map.get(spec, :compare, [])) > max,
      do: {:error, {:invalid_txn, :too_many_compares}},
      else: :ok
  end

  defp check_success_count(spec, config) do
    max = Keyword.get(config, :max_success_ops, 128)

    if length(Map.get(spec, :success, [])) > max,
      do: {:error, {:invalid_txn, :too_many_success_ops}},
      else: :ok
  end

  defp check_failure_count(spec, config) do
    max = Keyword.get(config, :max_failure_ops, 128)

    if length(Map.get(spec, :failure, [])) > max,
      do: {:error, {:invalid_txn, :too_many_failure_ops}},
      else: :ok
  end

  defp check_spec_size(spec, config) do
    max = Keyword.get(config, :max_txn_bytes, 1_000_000)

    if :erlang.external_size(spec) > max,
      do: {:error, {:invalid_txn, :spec_too_large}},
      else: :ok
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

  defp validate_compare({field, key, op, _value})
       when field in @valid_compare_fields and is_binary(key) and op in @valid_compare_ops,
       do: validate_txn_key(key)

  defp validate_compare({:field, key, path, op, _value})
       when is_binary(key) and is_list(path) and op in @valid_compare_ops,
       do: validate_txn_key(key)

  defp validate_compare({field, _, _, _}) when field not in @valid_compare_fields,
    do: {:error, {:invalid_txn, :unsupported_compare_field}}

  defp validate_compare({_, _, op, _}) when op not in @valid_compare_ops,
    do: {:error, {:invalid_txn, :unsupported_compare_op}}

  defp validate_compare(_), do: {:error, {:invalid_txn, :invalid_compare}}

  defp validate_operations(ops, config) do
    max_range_limit = Keyword.get(config, :max_range_limit, 1_000)

    Enum.reduce_while(ops, :ok, fn op, :ok ->
      case validate_operation(op, max_range_limit) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_operation({:get, {:key, key}, _opts}, _max_range) when is_binary(key),
    do: validate_txn_key(key)

  defp validate_operation({:get, {:prefix, _} = selector, %{limit: limit}}, max_range)
       when is_integer(limit) and limit <= max_range,
       do: validate_txn_selector(selector)

  defp validate_operation({:get, {:range, _, _} = selector, %{limit: limit}}, max_range)
       when is_integer(limit) and limit <= max_range,
       do: validate_txn_selector(selector)

  defp validate_operation({:get, {:prefix, _}, _}, _),
    do: {:error, {:invalid_txn, :missing_range_limit}}

  defp validate_operation({:get, {:range, _, _}, _}, _),
    do: {:error, {:invalid_txn, :missing_range_limit}}

  defp validate_operation({:put, key, _value, opts}, _max_range) when is_binary(key) do
    ttl = Map.get(opts, :ttl)
    lease = Map.get(opts, :lease)

    with :ok <- validate_txn_key(key) do
      if ttl != nil and lease != nil,
        do: {:error, {:invalid_txn, :ttl_and_lease_conflict}},
        else: :ok
    end
  end

  defp validate_operation({:delete, selector, _opts}, _max_range) do
    validate_txn_selector(selector)
  end

  defp validate_operation({:touch, key, ttl, _opts}, _max_range)
       when is_binary(key) and is_integer(ttl) and ttl > 0,
       do: validate_txn_key(key)

  defp validate_operation(_, _), do: {:error, {:invalid_txn, :unsupported_op}}

  defp validate_txn_key(key) do
    case validate_key(key) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_txn, reason}}
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
end
