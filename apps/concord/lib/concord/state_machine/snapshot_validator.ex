defmodule Concord.StateMachine.SnapshotValidator do
  @moduledoc false

  alias Concord.Compression
  alias Concord.Index.Extractor
  alias Concord.KV.Record
  alias Concord.StateMachine.Core.State
  alias Concord.Txn.Result
  alias Concord.Validation

  @state_fields [
    :store,
    :current,
    :history,
    :leases,
    :indexes,
    :index_entries,
    :requests,
    :representation,
    :command_count,
    :revision,
    :compact_revision,
    :next_lease_id
  ]

  @record_fields [
    :value,
    :create_revision,
    :mod_revision,
    :version,
    :expires_at,
    :lease_id,
    :content_type,
    :metadata
  ]

  @lease_fields [:id, :ttl, :expires_at, :granted_at, :keys]
  @request_fields [:request_hash, :revision, :result, :cached_at]
  @result_fields [:succeeded, :revision, :responses]

  @doc """
  Validates the complete, current version-four state representation.

  This is deliberately stricter than legacy snapshot migration. In particular,
  records, leases, indexes, index buckets, and request-cache entries must have
  the shapes produced by the current state machine. Historical version-four
  snapshots may still contain function index extractors and non-binary index
  names, so safe legacy definitions remain valid here.

  The validator is total over Erlang terms and never raises for malformed input.
  """
  @spec validate_v4(term()) :: :ok | {:error, term()}
  def validate_v4(state), do: validate(state, :current)

  @doc false
  @spec validate_legacy_v4(term()) :: :ok | {:error, term()}
  def validate_legacy_v4(state), do: validate(state, :legacy)

  defp validate(%{__struct__: State} = state, mode) do
    with :ok <- require_fields(state, @state_fields, :state),
         :ok <- validate_top_level_fields(state),
         :ok <- validate_store(state.store),
         :ok <- validate_current(state.current, state.revision, mode),
         :ok <- validate_current_store_consistency(state.store, state.current, mode),
         :ok <- validate_history(state.history, state.revision, mode),
         :ok <- validate_leases(state.leases, state.next_lease_id, state.revision, mode),
         :ok <- validate_lease_relations(state.current, state.leases, mode),
         :ok <- validate_indexes(state.indexes, mode),
         :ok <- validate_index_entries(state, mode),
         :ok <- validate_requests(state.requests, state.revision, mode) do
      :ok
    end
  rescue
    _error -> {:error, :invalid_state}
  catch
    _kind, _reason -> {:error, :invalid_state}
  end

  defp validate(_state, _mode), do: {:error, :invalid_state}

  defp validate_top_level_fields(state) do
    map_fields = [
      state.store,
      state.current,
      state.history,
      state.leases,
      state.indexes,
      state.index_entries,
      state.requests
    ]

    cond do
      not Enum.all?(map_fields, &is_map/1) ->
        {:error, :invalid_state_maps}

      state.representation not in [:current, :legacy] ->
        {:error, :invalid_state_representation}

      not non_negative_integer?(state.command_count) ->
        {:error, {:invalid_counter, :command_count}}

      not non_negative_integer?(state.revision) ->
        {:error, {:invalid_counter, :revision}}

      not non_negative_integer?(state.compact_revision) ->
        {:error, {:invalid_counter, :compact_revision}}

      state.compact_revision > state.revision ->
        {:error, :invalid_compact_revision}

      not positive_integer?(state.next_lease_id) ->
        {:error, :invalid_next_lease_id}

      true ->
        :ok
    end
  end

  defp validate_store(store) do
    validate_map_entries(store, fn
      {key, _value} when is_binary(key) and byte_size(key) > 0 -> :ok
      {key, _value} -> {:error, {:invalid_store_key, key}}
    end)
  end

  defp validate_current(current, state_revision, mode) do
    validate_map_entries(current, fn
      {key, record} when is_binary(key) and byte_size(key) > 0 ->
        with :ok <- validate_record(record, :live),
             :ok <- validate_revision_bound(record.mod_revision, state_revision, mode) do
          :ok
        end

      {key, _record} ->
        {:error, {:invalid_current_key, key}}
    end)
  end

  defp validate_current_store_consistency(_store, _current, :legacy), do: :ok

  defp validate_current_store_consistency(store, current, :current) do
    if MapSet.new(Map.keys(store)) == MapSet.new(Map.keys(current)) do
      validate_map_entries(current, fn {key, record} ->
        stored = Map.fetch!(store, key)
        {value, expires_at} = stored_value_and_expiry(stored)

        if value === record.value and expires_at === record.expires_at do
          :ok
        else
          {:error, {:store_current_mismatch, key}}
        end
      end)
    else
      {:error, :store_current_key_mismatch}
    end
  end

  defp stored_value_and_expiry(%{__struct__: Record} = record),
    do: {record.value, record.expires_at}

  defp stored_value_and_expiry(%{value: value, expires_at: expires_at}),
    do: {value, expires_at}

  defp stored_value_and_expiry({value, expires_at}) when is_integer(expires_at),
    do: {value, expires_at}

  defp stored_value_and_expiry(value), do: {value, nil}

  defp validate_history(history, state_revision, mode) do
    validate_map_entries(history, fn
      {{key, revision}, record}
      when is_binary(key) and byte_size(key) > 0 and is_integer(revision) and revision > 0 ->
        with :ok <- validate_record(record, :history),
             true <- record.mod_revision == revision,
             :ok <- validate_revision_bound(revision, state_revision, mode) do
          :ok
        else
          false -> {:error, {:history_revision_mismatch, {key, revision}}}
          {:error, reason} -> {:error, reason}
        end

      {key, _record} ->
        {:error, {:invalid_history_key, key}}
    end)
  end

  defp validate_record(%{__struct__: Record} = record, kind) do
    with :ok <- require_fields(record, @record_fields, :record),
         :ok <- validate_record_fields(record, kind) do
      :ok
    end
  end

  defp validate_record(_record, _kind), do: {:error, :invalid_record}

  defp validate_record_fields(record, kind) do
    valid_version? =
      case kind do
        :live -> positive_integer?(record.version)
        :history -> non_negative_integer?(record.version)
      end

    cond do
      not positive_integer?(record.create_revision) ->
        {:error, :invalid_record_create_revision}

      not positive_integer?(record.mod_revision) ->
        {:error, :invalid_record_mod_revision}

      record.create_revision > record.mod_revision ->
        {:error, :invalid_record_revision_order}

      not valid_version? ->
        {:error, :invalid_record_version}

      record.version == 0 and not is_nil(record.value) ->
        {:error, :invalid_tombstone_value}

      not optional_non_negative_integer?(record.expires_at) ->
        {:error, :invalid_record_expiry}

      not optional_positive_integer?(record.lease_id) ->
        {:error, :invalid_record_lease_id}

      not (is_nil(record.content_type) or is_binary(record.content_type)) ->
        {:error, :invalid_record_content_type}

      not is_map(record.metadata) ->
        {:error, :invalid_record_metadata}

      true ->
        :ok
    end
  end

  defp validate_leases(leases, next_lease_id, state_revision, mode) do
    with :ok <-
           validate_map_entries(leases, fn {lease_id, lease} ->
             with :ok <- validate_lease(lease_id, lease),
                  :ok <- validate_revision_bound(lease.granted_at, state_revision, mode) do
               :ok
             end
           end),
         true <- Enum.all?(Map.keys(leases), &(&1 < next_lease_id)) do
      :ok
    else
      false -> {:error, :invalid_next_lease_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_lease(lease_id, lease)
       when is_integer(lease_id) and lease_id > 0 and is_map(lease) do
    with :ok <- require_fields(lease, @lease_fields, :lease),
         true <- lease.id == lease_id,
         true <- positive_integer?(lease.ttl),
         true <- non_negative_integer?(lease.expires_at),
         true <- non_negative_integer?(lease.granted_at),
         true <- valid_key_list?(lease.keys) do
      :ok
    else
      false -> {:error, {:invalid_lease, lease_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_lease(lease_id, _lease),
    do: {:error, {:invalid_lease, lease_id}}

  defp validate_lease_relations(_current, _leases, :legacy), do: :ok

  defp validate_lease_relations(current, leases, :current) do
    with :ok <-
           validate_map_entries(current, fn {key, record} ->
             validate_record_lease_membership(key, record.lease_id, leases)
           end),
         :ok <-
           validate_map_entries(leases, fn {id, lease} ->
             validate_map_entries(Map.new(lease.keys, &{&1, true}), fn {key, true} ->
               case Map.get(current, key) do
                 %Record{lease_id: ^id} -> :ok
                 _other -> {:error, {:lease_membership_mismatch, key}}
               end
             end)
           end) do
      :ok
    end
  end

  defp validate_record_lease_membership(key, expected_id, leases) do
    memberships =
      leases
      |> Enum.flat_map(fn {id, lease} -> if key in lease.keys, do: [id], else: [] end)
      |> Enum.sort()

    valid? =
      case expected_id do
        nil -> memberships == []
        id -> Map.has_key?(leases, id) and memberships == [id]
      end

    if valid?, do: :ok, else: {:error, {:lease_membership_mismatch, key}}
  end

  defp validate_indexes(indexes, :legacy) do
    validate_map_entries(indexes, fn {name, extractor} ->
      if valid_legacy_index_name?(name) and Extractor.legacy_valid?(extractor) do
        :ok
      else
        {:error, {:invalid_index_definition, name}}
      end
    end)
  end

  defp validate_indexes(indexes, :current) do
    validate_map_entries(indexes, fn {name, extractor} ->
      if valid_current_index_name?(name) and Extractor.valid?(extractor) do
        :ok
      else
        {:error, {:invalid_index_definition, name}}
      end
    end)
  end

  defp validate_index_entries(%{indexes: indexes, index_entries: index_entries} = state, mode) do
    if MapSet.new(Map.keys(indexes)) == MapSet.new(Map.keys(index_entries)) do
      with :ok <- validate_index_entry_shapes(index_entries, mode),
           :ok <- validate_index_entry_semantics(state, mode) do
        :ok
      end
    else
      {:error, :index_definition_entry_mismatch}
    end
  end

  defp validate_index_entry_shapes(index_entries, mode) do
    validate_map_entries(index_entries, fn
      {name, bucket} when is_map(bucket) ->
        valid_name? =
          case mode do
            :current -> valid_current_index_name?(name)
            :legacy -> valid_legacy_index_name?(name)
          end

        with true <- valid_name?,
             :ok <- validate_index_bucket(name, bucket) do
          :ok
        else
          false -> {:error, {:invalid_index_name, name}}
          {:error, reason} -> {:error, reason}
        end

      {name, _bucket} ->
        {:error, {:invalid_index_bucket, name}}
    end)
  end

  defp validate_index_entry_semantics(_state, :legacy), do: :ok

  defp validate_index_entry_semantics(state, :current) do
    expected = state.store |> rebuild_index_entries(state.indexes) |> normalize_index_key_lists()
    actual = normalize_index_key_lists(state.index_entries)

    if index_entries_subset?(actual, expected),
      do: :ok,
      else: {:error, :index_entries_mismatch}
  end

  defp index_entries_subset?(actual, expected) do
    Enum.all?(actual, fn {name, bucket} ->
      expected_bucket = Map.fetch!(expected, name)

      Enum.all?(bucket, fn {value, keys} ->
        expected_keys = Map.get(expected_bucket, value, [])
        Enum.all?(keys, &(&1 in expected_keys))
      end)
    end)
  end

  defp validate_index_bucket(name, bucket) do
    validate_map_entries(bucket, fn
      {_value, keys} when is_list(keys) ->
        if valid_key_list?(keys), do: :ok, else: {:error, {:invalid_index_keys, name}}

      {value, _keys} ->
        {:error, {:invalid_index_keys, name, value}}
    end)
  end

  defp validate_requests(requests, state_revision, mode) do
    validate_map_entries(requests, fn
      {key, entry} when is_binary(key) and byte_size(key) > 0 and is_map(entry) ->
        with :ok <- validate_request(entry),
             :ok <- validate_revision_bound(entry.revision, state_revision, mode) do
          :ok
        end

      {key, _entry} ->
        {:error, {:invalid_request_cache_entry, key}}
    end)
  end

  defp validate_request(entry) do
    with :ok <- require_fields(entry, @request_fields, :request_cache_entry),
         true <- is_binary(entry.request_hash) and byte_size(entry.request_hash) == 32,
         true <- non_negative_integer?(entry.revision),
         true <- non_negative_integer?(entry.cached_at),
         :ok <- validate_result(entry.result, entry.revision) do
      :ok
    else
      false -> {:error, :invalid_request_cache_entry}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_result(%{__struct__: Result} = result, revision) do
    with :ok <- require_fields(result, @result_fields, :transaction_result),
         true <- is_boolean(result.succeeded),
         true <- result.revision == revision,
         true <- is_list(result.responses) do
      :ok
    else
      false -> {:error, :invalid_transaction_result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_result(_result, _revision), do: {:error, :invalid_transaction_result}

  defp rebuild_index_entries(store, indexes) do
    entries = Map.new(indexes, fn {name, _extractor} -> {name, %{}} end)

    store
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(entries, fn {key, stored}, acc ->
      {value, _expires_at} = stored_value_and_expiry(stored)
      value = Compression.decompress(value)

      Enum.reduce(indexes, acc, fn {name, extractor}, index_entries ->
        bucket = Map.fetch!(index_entries, name)
        values = List.wrap(Extractor.extract(extractor, value))

        bucket =
          Enum.reduce(values, bucket, fn
            nil, inner -> inner
            index_value, inner -> Map.update(inner, index_value, [key], &[key | &1])
          end)

        Map.put(index_entries, name, bucket)
      end)
    end)
  end

  defp normalize_index_key_lists(index_entries) do
    Map.new(index_entries, fn {name, bucket} ->
      {name, Map.new(bucket, fn {value, keys} -> {value, Enum.sort(keys)} end)}
    end)
  end

  defp validate_revision_bound(_revision, _state_revision, :legacy), do: :ok

  defp validate_revision_bound(revision, state_revision, :current) do
    if revision <= state_revision, do: :ok, else: {:error, :revision_exceeds_state}
  end

  defp require_fields(map, fields, label) do
    case Enum.find(fields, &(not Map.has_key?(map, &1))) do
      nil -> :ok
      field -> {:error, {:missing_field, label, field}}
    end
  end

  defp validate_map_entries(map, validator) do
    Enum.reduce_while(map, :ok, fn entry, :ok ->
      case validator.(entry) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp valid_key_list?(keys) do
    is_list(keys) and
      Enum.all?(keys, &(is_binary(&1) and byte_size(&1) > 0)) and
      length(keys) == length(Enum.uniq(keys))
  end

  # Historical create-index commands accepted arbitrary index names. Keep
  # names that can be deterministically serialized, while excluding runtime
  # identities such as functions, PIDs, ports, and references.
  defp valid_legacy_index_name?(name) do
    Validation.validate_term(name) == :ok
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_current_index_name?(name) do
    is_binary(name) and byte_size(name) > 0 and byte_size(name) <= 255 and String.valid?(name)
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp optional_non_negative_integer?(nil), do: true
  defp optional_non_negative_integer?(value), do: non_negative_integer?(value)

  defp optional_positive_integer?(nil), do: true
  defp optional_positive_integer?(value), do: positive_integer?(value)
end
