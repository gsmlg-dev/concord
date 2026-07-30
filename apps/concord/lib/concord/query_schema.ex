defmodule Concord.QuerySchema do
  @moduledoc false

  @max_batch_size 500
  @max_index_name_bytes 255
  @max_key_bytes 4_096
  @max_list_limit 10_000

  @simple_queries [
    :get_all,
    :get_all_with_ttl,
    :stats,
    :backup_snapshot,
    :list_indexes,
    :get_revision,
    :list_leases
  ]

  @doc """
  Validates the fixed query language understood by the current state machine.

  Unlike commands, queries are not persisted or replayed, so they do not need
  an on-wire version envelope. This module is nevertheless an immutable
  boundary: changing the meaning of an existing shape is not permitted, and a
  future incompatible query language must use a new envelope version.
  """
  @spec validate(term()) :: :ok | {:error, :unsupported_query}
  def validate(query) do
    if supported?(query), do: :ok, else: {:error, :unsupported_query}
  end

  @spec supported?(term()) :: boolean()
  def supported?(query) when query in @simple_queries, do: true

  def supported?({operation, key}) when operation in [:get, :get_with_ttl, :ttl, :get_record],
    do: valid_key?(key)

  def supported?({:get_many, keys}) when is_list(keys),
    do: length(keys) <= @max_batch_size and Enum.all?(keys, &valid_key?/1)

  def supported?({:prefix_scan, prefix}), do: valid_boundary?(prefix)

  def supported?({:index_lookup, name, _value}), do: valid_index_name?(name)
  def supported?({:get_index_extractor, name}), do: valid_index_name?(name)

  def supported?({:get, key, revision: revision}),
    do: valid_key?(key) and non_negative_integer?(revision)

  def supported?({:txn_result, idempotency_key}), do: valid_key?(idempotency_key)

  def supported?({:history, key, opts}),
    do: valid_key?(key) and valid_history_options?(opts)

  def supported?({:list, selector, opts}),
    do: valid_selector?(selector) and valid_list_options?(opts)

  def supported?({:lease_info, id}), do: positive_integer?(id)
  def supported?(_query), do: false

  @doc """
  Extracts the timestamp and query from the stable Concord read envelope.
  """
  @spec unwrap(term()) ::
          {:ok, non_neg_integer(), term()} | {:error, :invalid_query_envelope}
  def unwrap({:concord_query, timestamp_ms, query})
      when is_integer(timestamp_ms) and timestamp_ms >= 0,
      do: {:ok, timestamp_ms, query}

  def unwrap(_operation), do: {:error, :invalid_query_envelope}

  defp valid_history_options?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and unique_keys?(opts) and
      only_keys?(opts, [:from_revision, :to_revision, :limit]) and
      valid_optional_revision?(opts, :from_revision) and
      valid_optional_revision?(opts, :to_revision) and
      valid_optional_limit?(opts, :limit) and
      valid_revision_range?(opts)
  end

  defp valid_history_options?(_opts), do: false

  defp valid_list_options?(opts) when is_map(opts) do
    only_keys?(opts, [:limit, :keys_only, :revision]) and
      positive_integer?(Map.get(opts, :limit, 1_000)) and
      Map.get(opts, :limit, 1_000) <= @max_list_limit and
      is_boolean(Map.get(opts, :keys_only, false)) and
      valid_optional_non_negative_integer?(Map.get(opts, :revision))
  end

  defp valid_list_options?(_opts), do: false

  defp valid_selector?({:key, key}), do: valid_key?(key)
  defp valid_selector?({:prefix, prefix}), do: valid_boundary?(prefix)

  defp valid_selector?({:range, start_key, end_key}),
    do: valid_boundary?(start_key) and valid_boundary?(end_key) and start_key < end_key

  defp valid_selector?(_selector), do: false

  defp valid_optional_revision?(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, revision} -> non_negative_integer?(revision)
      :error -> true
    end
  end

  defp valid_optional_limit?(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, limit} -> positive_integer?(limit)
      :error -> true
    end
  end

  defp valid_revision_range?(opts) do
    from_revision = Keyword.get(opts, :from_revision, 0)

    case Keyword.fetch(opts, :to_revision) do
      {:ok, to_revision} -> from_revision <= to_revision
      :error -> true
    end
  end

  defp valid_key?(key),
    do: is_binary(key) and byte_size(key) > 0 and byte_size(key) <= @max_key_bytes

  defp valid_boundary?(boundary),
    do: is_binary(boundary) and byte_size(boundary) <= @max_key_bytes

  defp valid_index_name?(name) do
    is_binary(name) and byte_size(name) > 0 and byte_size(name) <= @max_index_name_bytes and
      String.valid?(name)
  end

  defp valid_optional_non_negative_integer?(nil), do: true
  defp valid_optional_non_negative_integer?(value), do: non_negative_integer?(value)
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp unique_keys?(keyword) do
    keys = Keyword.keys(keyword)
    length(keys) == length(Enum.uniq(keys))
  end

  defp only_keys?(map_or_keyword, allowed) do
    map_or_keyword
    |> keys()
    |> Enum.all?(&(&1 in allowed))
  end

  defp keys(map) when is_map(map), do: Map.keys(map)
  defp keys(keyword) when is_list(keyword), do: Keyword.keys(keyword)
end
