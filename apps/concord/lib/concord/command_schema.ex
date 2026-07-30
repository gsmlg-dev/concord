defmodule Concord.CommandSchema do
  @moduledoc false

  alias Concord.Compression

  @type version :: 0 | 1

  @max_batch_size 500
  @max_index_name_bytes 255
  @max_key_bytes 4_096
  @max_value_bytes 16 * 1_024 * 1_024
  @max_command_bytes 64 * 1_024 * 1_024
  @max_term_depth 100
  @max_txn_bytes 1_000_000
  @max_txn_compares 64
  @max_txn_operations 128
  @max_txn_range_limit 1_000

  @doc false
  def max_batch_size, do: @max_batch_size

  @doc false
  def max_key_bytes, do: @max_key_bytes

  @doc false
  def max_value_bytes, do: @max_value_bytes

  @doc false
  def max_command_bytes, do: @max_command_bytes

  @doc false
  def max_txn_bytes, do: @max_txn_bytes

  @doc false
  def max_txn_compares, do: @max_txn_compares

  @doc false
  def max_txn_operations, do: @max_txn_operations

  @doc false
  def max_txn_range_limit, do: @max_txn_range_limit

  @doc """
  Canonicalizes commands emitted by this release before they are enveloped.

  This normalization is part of the writer contract rather than version-zero
  replay semantics. In particular, historical version-zero commands remain
  byte-for-byte compatible while new writers never append `:infinity` TTLs
  that the legacy apply path cannot evaluate arithmetically.
  """
  @spec normalize_emission(term()) :: term()
  def normalize_emission({:put, key, value, %{} = opts}) do
    {:put, key, value, normalize_ttl_option(opts)}
  end

  def normalize_emission({:txn, %{} = spec}) do
    spec =
      spec
      |> normalize_txn_branch(:success)
      |> normalize_txn_branch(:failure)

    {:txn, spec}
  end

  def normalize_emission(command), do: command

  @doc """
  Validates commands emitted by this release.

  New writers use the strict version-one schema even while emitting the legacy
  envelope shape during a compatibility rollout.
  """
  @spec validate_emission(term()) ::
          :ok | {:error, :unsupported_command | {:invalid_command, atom()}}
  def validate_emission(command), do: validate_replay(1, command)

  @doc """
  Validates a command using the immutable safety contract of its envelope.

  Version zero deliberately performs no validation because its historical
  replay language accepted every Erlang term. Version one freezes recursive
  term safety, compression decoding, and logical value-size enforcement here;
  it must not delegate replay decisions to mutable public API validation.
  """
  @spec validate_replay(version(), term()) ::
          :ok | {:error, :unsupported_command | {:invalid_command, atom()}}
  def validate_replay(0, _command), do: :ok

  def validate_replay(1, command) do
    with :ok <- validate_v1_command_size(command),
         :ok <- validate_v1_term(command, 0),
         :ok <- validate(1, command),
         :ok <- validate_v1_transaction_size(command) do
      validate_v1_value_sizes(command)
    end
  end

  @doc false
  @spec logical_external_size_v1(term(), non_neg_integer()) ::
          {:ok, non_neg_integer()}
          | {:error,
             :depth_exceeded
             | :invalid_compressed_value
             | :size_limit
             | :value_too_large}
  def logical_external_size_v1(term, limit) when is_integer(limit) and limit >= 0 do
    bounded_external_size(term, limit, :logical)
  end

  @doc false
  @spec raw_external_size_v1(term(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :depth_exceeded | :size_limit}
  def raw_external_size_v1(term, limit) when is_integer(limit) and limit >= 0 do
    bounded_external_size(term, limit, :raw)
  end

  defp bounded_external_size(_term, 0, _mode), do: {:error, :size_limit}

  defp bounded_external_size(term, limit, mode) do
    with {:ok, payload_size} <- bounded_payload_size(term, limit - 1, 0, mode) do
      {:ok, payload_size + 1}
    end
  rescue
    _error -> {:error, :invalid_compressed_value}
  catch
    _kind, _reason -> {:error, :invalid_compressed_value}
  end

  @doc """
  Validates the immutable command schema associated with an envelope version.

  These clauses and constants are consensus data. They must not depend on
  application configuration or be extended for an existing version. New
  command shapes require a new envelope version so replay cannot reinterpret
  bytes that an earlier release handled differently.
  """
  @spec validate(version(), term()) :: :ok | {:error, :unsupported_command}
  def validate(version, command) when version in [0, 1] do
    if supported?(version, command), do: :ok, else: {:error, :unsupported_command}
  end

  @spec supported?(version(), term()) :: boolean()
  # The pre-versioning state machine accepted every unmatched term as a
  # successful no-op. Consequently the immutable version-zero language is all
  # Erlang terms, not just the command shapes known at the time.
  def supported?(0, _command), do: true
  def supported?(1, command), do: current_command?(command)

  defp current_command?({:put, key, _value}), do: valid_key?(key)

  defp current_command?({:put, key, _value, %{} = opts}) do
    valid_key?(key) and valid_put_options?(opts)
  end

  defp current_command?({:put, key, _value, expires_at}) do
    valid_key?(key) and valid_expiry?(expires_at)
  end

  defp current_command?({:delete, key}), do: valid_key?(key)

  defp current_command?({:delete, key, %{} = opts}) do
    valid_key?(key) and valid_delete_options?(opts)
  end

  defp current_command?({:put_if, key, _value, expires_at, _expected}) do
    valid_key?(key) and valid_expiry?(expires_at)
  end

  defp current_command?({:delete_if, key, _expected, nil}), do: valid_key?(key)

  defp current_command?({:touch, key, ttl}),
    do: valid_key?(key) and positive_integer?(ttl)

  defp current_command?(:cleanup_expired), do: true

  defp current_command?({:put_many, operations}) when is_list(operations) do
    length(operations) <= @max_batch_size and Enum.all?(operations, &valid_batch_put?/1)
  end

  defp current_command?({:delete_many, keys}) when is_list(keys) do
    length(keys) <= @max_batch_size and Enum.all?(keys, &valid_key?/1)
  end

  defp current_command?({:touch_many, operations}) when is_list(operations) do
    length(operations) <= @max_batch_size and Enum.all?(operations, &valid_batch_touch?/1)
  end

  defp current_command?({:create_index, name, extractor}),
    do: valid_name?(name) and valid_extractor?(extractor)

  # A version-zero create command accepted arbitrary map keys as names. Drop is
  # intentionally wider than create/reindex so an operator can remove the
  # exact legacy name reported by :stats during migration. Replication safety
  # validation still rejects executable/process-local terms before emission.
  defp current_command?({:drop_index, _legacy_name}), do: true
  defp current_command?({:reindex, name}), do: valid_name?(name)

  defp current_command?({:restore_backup, %{version: 2} = backup}),
    do: valid_backup?(backup)

  defp current_command?({:restore_backup, entries}) when is_list(entries),
    do: valid_entries?(entries)

  defp current_command?(:reconcile_legacy_state), do: true

  defp current_command?({:get_many, keys}) when is_list(keys) do
    length(keys) <= @max_batch_size and Enum.all?(keys, &valid_key?/1)
  end

  defp current_command?({:txn, spec}), do: valid_txn?(spec)

  defp current_command?({:grant_lease, ttl, %{} = opts}),
    do: positive_integer?(ttl) and map_size(opts) == 0

  defp current_command?({operation, id, %{} = opts})
       when operation in [:keep_alive_lease, :revoke_lease],
       do: positive_integer?(id) and map_size(opts) == 0

  defp current_command?({:expire_lease, id}), do: positive_integer?(id)
  defp current_command?(_command), do: false

  defp valid_put_options?(opts) do
    only_keys?(opts, [:ttl, :lease, :content_type, :metadata, :prev_kv]) and
      valid_ttl_option?(Map.get(opts, :ttl)) and
      valid_optional_positive_integer?(Map.get(opts, :lease)) and
      valid_optional_binary?(Map.get(opts, :content_type)) and
      is_map(Map.get(opts, :metadata, %{})) and
      is_boolean(Map.get(opts, :prev_kv, false))
  end

  defp valid_txn_put_options?(opts) do
    ttl = Map.get(opts, :ttl)
    lease = Map.get(opts, :lease)

    only_keys?(opts, [:ttl, :lease, :content_type, :metadata, :prev_kv]) and
      valid_ttl_option?(ttl) and
      valid_optional_positive_integer?(lease) and
      not (not is_nil(ttl) and positive_integer?(lease)) and
      valid_optional_binary?(Map.get(opts, :content_type)) and
      is_map(Map.get(opts, :metadata, %{})) and
      is_boolean(Map.get(opts, :prev_kv, false))
  end

  defp valid_delete_options?(opts) do
    only_keys?(opts, [:prev_kv]) and is_boolean(Map.get(opts, :prev_kv, false))
  end

  defp valid_get_options?(opts, selector) do
    only_keys?(opts, [:limit]) and
      case selector do
        {:key, _key} ->
          not Map.has_key?(opts, :limit) or positive_integer?(Map.get(opts, :limit))

        _range_selector ->
          limit = Map.get(opts, :limit)
          positive_integer?(limit) and limit <= @max_txn_range_limit
      end
  end

  defp valid_batch_put?({key, _value}), do: valid_key?(key)

  defp valid_batch_put?({key, _value, expires_at}),
    do: valid_key?(key) and valid_expiry?(expires_at)

  defp valid_batch_put?(_operation), do: false

  defp valid_batch_touch?({key, ttl}), do: valid_key?(key) and positive_integer?(ttl)
  defp valid_batch_touch?(_operation), do: false

  defp valid_backup?(backup) do
    only_keys?(backup, [:version, :kv_data, :indexes]) and
      valid_entry_collection?(Map.get(backup, :kv_data)) and
      valid_index_definitions?(Map.get(backup, :indexes))
  end

  defp valid_entry_collection?(entries) when is_list(entries), do: valid_entries?(entries)

  defp valid_entry_collection?(entries) when is_map(entries) do
    Enum.all?(entries, fn {key, _value} -> valid_key?(key) end)
  end

  defp valid_entry_collection?(_entries), do: false

  defp valid_entries?(entries) do
    Enum.all?(entries, fn
      {key, _value} -> valid_key?(key)
      _entry -> false
    end)
  end

  defp valid_index_definitions?(indexes) when is_map(indexes) do
    Enum.all?(indexes, fn {name, extractor} ->
      valid_name?(name) and valid_extractor?(extractor)
    end)
  end

  defp valid_index_definitions?(_indexes), do: false

  defp valid_txn?(spec) when is_map(spec) do
    compares = Map.get(spec, :compare, [])
    success = Map.get(spec, :success, [])
    failure = Map.get(spec, :failure, [])

    only_keys?(spec, [:compare, :success, :failure, :idempotency_key]) and
      valid_idempotency_key?(Map.get(spec, :idempotency_key)) and
      is_list(compares) and length(compares) <= @max_txn_compares and
      is_list(success) and length(success) <= @max_txn_operations and
      is_list(failure) and length(failure) <= @max_txn_operations and
      Enum.all?(compares, &valid_compare?/1) and
      Enum.all?(success, &valid_txn_operation?/1) and
      Enum.all?(failure, &valid_txn_operation?/1)
  end

  defp valid_txn?(_spec), do: false

  defp valid_compare?({field, key, operation, _expected})
       when field in [:exists, :value, :version, :create_revision, :mod_revision, :lease, :ttl] and
              operation in [:==, :!=, :>, :>=, :<, :<=],
       do: valid_key?(key)

  defp valid_compare?({:field, key, path, operation, _expected})
       when is_list(path) and operation in [:==, :!=, :>, :>=, :<, :<=],
       do: valid_key?(key) and Enum.all?(path, &valid_path_key?/1)

  defp valid_compare?(_compare), do: false

  defp valid_txn_operation?({:get, selector, %{} = opts}),
    do: valid_selector?(selector) and valid_get_options?(opts, selector)

  defp valid_txn_operation?({:put, key, _value, %{} = opts}),
    do: valid_key?(key) and valid_txn_put_options?(opts)

  defp valid_txn_operation?({:delete, selector, %{} = opts}),
    do: valid_selector?(selector) and valid_delete_options?(opts)

  defp valid_txn_operation?({:touch, key, ttl, %{} = opts}),
    do: valid_key?(key) and positive_integer?(ttl) and map_size(opts) == 0

  defp valid_txn_operation?(_operation), do: false

  defp valid_selector?({:key, key}), do: valid_key?(key)
  defp valid_selector?({:prefix, prefix}), do: valid_key?(prefix)

  defp valid_selector?({:range, start_key, end_key}),
    do: valid_boundary?(start_key) and valid_boundary?(end_key) and start_key < end_key

  defp valid_selector?(_selector), do: false

  defp valid_key?(key),
    do: is_binary(key) and byte_size(key) > 0 and byte_size(key) <= @max_key_bytes

  defp valid_boundary?(boundary),
    do: is_binary(boundary) and byte_size(boundary) <= @max_key_bytes

  defp valid_name?(name) do
    is_binary(name) and byte_size(name) > 0 and byte_size(name) <= @max_index_name_bytes and
      String.valid?(name)
  end

  # Keep the version-one extractor grammar here rather than delegating to the
  # runtime extractor module. Extending that module must not reinterpret an
  # already-versioned command language during replay.
  defp valid_extractor?({:map_get, key}), do: is_atom(key) or is_binary(key)

  defp valid_extractor?({:nested, [_ | _] = keys}) when is_list(keys),
    do: Enum.all?(keys, &valid_path_key?/1)

  defp valid_extractor?({:identity}), do: true
  defp valid_extractor?({:element, index}), do: is_integer(index) and index >= 0
  defp valid_extractor?(_extractor), do: false

  defp valid_path_key?(key), do: is_atom(key) or is_binary(key)
  defp valid_expiry?(expiry), do: is_nil(expiry) or (is_integer(expiry) and expiry >= 0)

  defp valid_ttl_option?(:infinity), do: true
  defp valid_ttl_option?(ttl), do: valid_optional_positive_integer?(ttl)

  defp valid_optional_positive_integer?(nil), do: true
  defp valid_optional_positive_integer?(value), do: positive_integer?(value)

  defp valid_optional_binary?(nil), do: true
  defp valid_optional_binary?(value), do: is_binary(value)

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp valid_idempotency_key?(nil), do: true
  defp valid_idempotency_key?(key), do: valid_key?(key)

  defp validate_v1_value_sizes(command) do
    command
    |> command_values()
    |> Enum.reduce_while(:ok, fn value, :ok ->
      with {:ok, _size} <- raw_external_size_v1(value, @max_value_bytes),
           {:ok, _size} <- logical_external_size_v1(value, @max_value_bytes) do
        {:cont, :ok}
      else
        {:error, :size_limit} ->
          {:halt, {:error, {:invalid_command, :value_too_large}}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_command, reason}}}
      end
    end)
  end

  defp validate_v1_command_size(command) do
    with {:ok, _size} <- raw_external_size_v1(command, @max_command_bytes),
         {:ok, _size} <- logical_external_size_v1(command, @max_command_bytes) do
      :ok
    else
      {:error, :size_limit} -> command_size_error(command)
      {:error, :value_too_large} -> {:error, {:invalid_command, :value_too_large}}
      {:error, reason} -> {:error, {:invalid_command, reason}}
    end
  end

  defp validate_v1_transaction_size({:txn, spec}) do
    with {:ok, _size} <- raw_external_size_v1(spec, @max_txn_bytes),
         {:ok, _size} <- logical_external_size_v1(spec, @max_txn_bytes) do
      :ok
    else
      {:error, reason} when reason in [:size_limit, :value_too_large] ->
        {:error, {:invalid_command, :transaction_too_large}}

      {:error, reason} ->
        {:error, {:invalid_command, reason}}
    end
  end

  defp validate_v1_transaction_size(_command), do: :ok

  defp command_size_error(command) do
    if direct_value_too_large?(command) do
      {:error, {:invalid_command, :value_too_large}}
    else
      {:error, {:invalid_command, :command_too_large}}
    end
  end

  defp direct_value_too_large?({:put, _key, value}), do: raw_value_too_large?(value)
  defp direct_value_too_large?({:put, _key, value, _opts}), do: raw_value_too_large?(value)

  defp direct_value_too_large?({:put_if, _key, value, _expires_at, expected}),
    do: raw_value_too_large?(value) or raw_value_too_large?(expected)

  defp direct_value_too_large?({:delete_if, _key, expected, _condition}),
    do: raw_value_too_large?(expected)

  defp direct_value_too_large?(_command), do: false

  defp raw_value_too_large?(value) do
    match?({:error, :size_limit}, raw_external_size_v1(value, @max_value_bytes))
  end

  defp command_values({:put, _key, value}), do: [value]
  defp command_values({:put, _key, value, _opts_or_expiry}), do: [value]

  defp command_values({:put_if, _key, value, _expires_at, expected}),
    do: [value, expected]

  defp command_values({:delete_if, _key, expected, _condition}), do: [expected]

  defp command_values({:put_many, operations}) do
    Enum.map(operations, fn
      {_key, value} -> value
      {_key, value, _expires_at} -> value
    end)
  end

  defp command_values({:txn, spec}) do
    compare_values =
      spec
      |> Map.get(:compare, [])
      |> Enum.map(fn
        {:field, _key, _path, _operation, expected} -> expected
        {_field, _key, _operation, expected} -> expected
      end)

    operation_values =
      [:success, :failure]
      |> Enum.flat_map(&Map.get(spec, &1, []))
      |> Enum.flat_map(fn
        {:put, _key, value, _opts} -> [value]
        _operation -> []
      end)

    compare_values ++ operation_values
  end

  defp command_values({:restore_backup, %{version: 2, kv_data: entries}}),
    do: backup_values(entries)

  defp command_values({:restore_backup, entries}) when is_list(entries),
    do: backup_values(entries)

  defp command_values(_command), do: []

  defp backup_values(entries) when is_map(entries) do
    Enum.flat_map(entries, fn {_key, stored} -> stored_values(stored) end)
  end

  defp backup_values(entries) when is_list(entries) do
    Enum.flat_map(entries, fn {_key, stored} -> stored_values(stored) end)
  end

  defp stored_values(%{value: value}), do: [value]

  defp stored_values({value, expires_at}) when is_nil(expires_at) or is_integer(expires_at),
    do: [value]

  defp stored_values(value), do: [value]

  defp validate_v1_term(_term, depth) when depth > @max_term_depth,
    do: {:error, {:invalid_command, :depth_exceeded}}

  defp validate_v1_term(term, _depth) when is_function(term),
    do: {:error, {:invalid_command, :function_in_spec}}

  defp validate_v1_term(term, _depth) when is_pid(term),
    do: {:error, {:invalid_command, :pid_in_spec}}

  defp validate_v1_term(term, _depth) when is_reference(term),
    do: {:error, {:invalid_command, :ref_in_spec}}

  defp validate_v1_term(term, _depth) when is_port(term),
    do: {:error, {:invalid_command, :port_in_spec}}

  defp validate_v1_term(term, _depth)
       when is_atom(term) or is_number(term) or is_bitstring(term),
       do: :ok

  defp validate_v1_term([], _depth), do: :ok

  defp validate_v1_term([head | tail], depth) do
    with :ok <- validate_v1_term(head, depth + 1) do
      validate_v1_list_tail(tail, depth)
    end
  end

  defp validate_v1_term({:compressed, algorithm, compressed_binary} = compressed, depth)
       when algorithm in [:zlib, :gzip, :none] and is_binary(compressed_binary) do
    case Compression.decode_v1(compressed) do
      {:ok, value} -> validate_v1_term(value, depth + 1)
      {:error, reason} -> {:error, {:invalid_command, reason}}
    end
  end

  defp validate_v1_term(tuple, _depth)
       when is_tuple(tuple) and tuple_size(tuple) > 0 and elem(tuple, 0) == :compressed,
       do: {:error, {:invalid_command, :invalid_compressed_value}}

  defp validate_v1_term(tuple, depth) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> validate_v1_term(depth + 1)
  end

  defp validate_v1_term(map, depth) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
      with :ok <- validate_v1_term(key, depth + 1),
           :ok <- validate_v1_term(value, depth + 1) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp validate_v1_term(_term, _depth),
    do: {:error, {:invalid_command, :unsupported_term}}

  defp validate_v1_list_tail([], _depth), do: :ok
  defp validate_v1_list_tail([_head | _tail] = tail, depth), do: validate_v1_term(tail, depth)
  defp validate_v1_list_tail(tail, depth), do: validate_v1_term(tail, depth + 1)

  defp bounded_payload_size(_term, budget, _depth, _mode) when budget < 0,
    do: {:error, :size_limit}

  defp bounded_payload_size(_term, _budget, depth, _mode) when depth > @max_term_depth,
    do: {:error, :depth_exceeded}

  defp bounded_payload_size(
         {:compressed, algorithm, compressed_binary} = compressed,
         budget,
         depth,
         :logical
       )
       when algorithm in [:zlib, :gzip, :none] and is_binary(compressed_binary) do
    case Compression.decode_v1(compressed) do
      {:ok, value} -> bounded_payload_size(value, budget, depth, :logical)
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounded_payload_size(tuple, _budget, _depth, :logical)
       when is_tuple(tuple) and tuple_size(tuple) > 0 and elem(tuple, 0) == :compressed,
       do: {:error, :invalid_compressed_value}

  defp bounded_payload_size([], budget, _depth, _mode), do: bounded_leaf_size([], budget)

  defp bounded_payload_size([_head | _tail] = list, budget, depth, mode) do
    case byte_list_length(list, 0) do
      {:ok, length} -> bounded_size(3 + length, budget)
      :not_string -> bounded_list_size(list, budget, depth, mode)
    end
  end

  defp bounded_payload_size(tuple, budget, depth, mode) when is_tuple(tuple) do
    arity = tuple_size(tuple)
    header_size = if arity < 256, do: 2, else: 5

    with {:ok, _header_size} <- bounded_size(header_size, budget) do
      bounded_tuple_size(tuple, 0, budget - header_size, depth + 1, mode, header_size)
    end
  end

  defp bounded_payload_size(map, budget, depth, mode) when is_map(map) do
    with {:ok, _header_size} <- bounded_size(5, budget) do
      map
      |> Map.to_list()
      |> bounded_map_size(budget - 5, depth + 1, mode, 5)
    end
  end

  defp bounded_payload_size(term, budget, _depth, _mode), do: bounded_leaf_size(term, budget)

  defp bounded_tuple_size(tuple, index, _budget, _depth, _mode, total)
       when index == tuple_size(tuple),
       do: {:ok, total}

  defp bounded_tuple_size(tuple, index, budget, depth, mode, total) do
    with {:ok, size} <- bounded_payload_size(elem(tuple, index), budget, depth, mode) do
      bounded_tuple_size(tuple, index + 1, budget - size, depth, mode, total + size)
    end
  end

  defp bounded_list_size(list, budget, depth, mode) do
    with {:ok, _header_size} <- bounded_size(5, budget) do
      bounded_list_elements(list, budget - 5, depth + 1, mode, 5)
    end
  end

  defp bounded_list_elements([], budget, _depth, _mode, total) do
    with {:ok, nil_size} <- bounded_leaf_size([], budget), do: {:ok, total + nil_size}
  end

  defp bounded_list_elements([head | tail], budget, depth, mode, total) do
    with {:ok, size} <- bounded_payload_size(head, budget, depth, mode) do
      bounded_list_elements(tail, budget - size, depth, mode, total + size)
    end
  end

  defp bounded_list_elements(tail, budget, depth, mode, total) do
    with {:ok, size} <- bounded_payload_size(tail, budget, depth, mode),
         do: {:ok, total + size}
  end

  defp bounded_map_size([], _budget, _depth, _mode, total), do: {:ok, total}

  defp bounded_map_size([{key, value} | entries], budget, depth, :logical, total) do
    if contains_compressed_envelope?(key) do
      {:error, :invalid_compressed_value}
    else
      with {:ok, key_size} <- bounded_payload_size(key, budget, depth, :logical),
           {:ok, value_size} <-
             bounded_payload_size(value, budget - key_size, depth, :logical) do
        used = key_size + value_size
        bounded_map_size(entries, budget - used, depth, :logical, total + used)
      end
    end
  end

  defp bounded_map_size([{key, value} | entries], budget, depth, mode, total) do
    with {:ok, key_size} <- bounded_payload_size(key, budget, depth, mode),
         {:ok, value_size} <- bounded_payload_size(value, budget - key_size, depth, mode) do
      used = key_size + value_size
      bounded_map_size(entries, budget - used, depth, mode, total + used)
    end
  end

  defp bounded_leaf_size(term, budget) do
    term
    |> :erlang.external_size()
    |> Kernel.-(1)
    |> bounded_size(budget)
  end

  defp bounded_size(size, budget) when size <= budget, do: {:ok, size}
  defp bounded_size(_size, _budget), do: {:error, :size_limit}

  defp byte_list_length([], length), do: {:ok, length}

  defp byte_list_length([byte | tail], length)
       when is_integer(byte) and byte >= 0 and byte <= 255 and length < 65_535,
       do: byte_list_length(tail, length + 1)

  defp byte_list_length(_list, _length), do: :not_string

  defp contains_compressed_envelope?(tuple)
       when is_tuple(tuple) and tuple_size(tuple) > 0 and elem(tuple, 0) == :compressed,
       do: true

  defp contains_compressed_envelope?(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.any?(&contains_compressed_envelope?/1)
  end

  defp contains_compressed_envelope?([head | tail]),
    do: contains_compressed_envelope?(head) or contains_compressed_envelope?(tail)

  defp contains_compressed_envelope?(map) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.any?(fn {key, value} ->
      contains_compressed_envelope?(key) or contains_compressed_envelope?(value)
    end)
  end

  defp contains_compressed_envelope?(_term), do: false

  defp only_keys?(map, allowed) do
    map
    |> Map.keys()
    |> Enum.all?(&(&1 in allowed))
  end

  defp normalize_txn_branch(spec, branch) do
    case Map.fetch(spec, branch) do
      {:ok, operations} when is_list(operations) ->
        Map.put(spec, branch, Enum.map(operations, &normalize_txn_operation/1))

      _other ->
        spec
    end
  end

  defp normalize_txn_operation({:put, key, value, %{} = opts}) do
    {:put, key, value, normalize_ttl_option(opts)}
  end

  defp normalize_txn_operation(operation), do: operation

  defp normalize_ttl_option(%{ttl: :infinity} = opts), do: %{opts | ttl: nil}
  defp normalize_ttl_option(opts), do: opts
end
