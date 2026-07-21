defmodule Concord.StateMachine.Core.Context do
  @moduledoc """
  Deterministic metadata supplied by a replication adapter.

  `timestamp_ms` is captured once before an operation is replicated. Replays
  must use the same value.
  """

  @enforce_keys [:op_number, :timestamp_ms]
  defstruct [:op_number, :timestamp_ms]

  @type t :: %__MODULE__{
          op_number: non_neg_integer(),
          timestamp_ms: non_neg_integer()
        }

  @spec new!(keyword() | map()) :: t()
  def new!(attributes) do
    op_number = fetch!(attributes, :op_number)
    timestamp_ms = fetch!(attributes, :timestamp_ms)

    unless is_integer(op_number) and op_number >= 0 do
      raise ArgumentError, "op_number must be a non-negative integer"
    end

    unless is_integer(timestamp_ms) and timestamp_ms >= 0 do
      raise ArgumentError, "timestamp_ms must be a non-negative integer"
    end

    %__MODULE__{op_number: op_number, timestamp_ms: timestamp_ms}
  end

  defp fetch!(attributes, key) when is_list(attributes), do: Keyword.fetch!(attributes, key)
  defp fetch!(attributes, key) when is_map(attributes), do: Map.fetch!(attributes, key)
end

defmodule Concord.StateMachine.Core.State do
  @moduledoc """
  Complete immutable state of the Concord key-value service.

  The legacy and MVCC representations intentionally coexist while the public
  command formats are supported. Unlike the former protocol adapter, no service data
  is stored outside this value.
  """

  defstruct store: %{},
            current: %{},
            history: %{},
            leases: %{},
            indexes: %{},
            index_entries: %{},
            requests: %{},
            command_count: 0,
            revision: 0,
            compact_revision: 0,
            next_lease_id: 1

  @type t :: %__MODULE__{
          store: map(),
          current: map(),
          history: map(),
          leases: map(),
          indexes: map(),
          index_entries: map(),
          requests: map(),
          command_count: non_neg_integer(),
          revision: non_neg_integer(),
          compact_revision: non_neg_integer(),
          next_lease_id: pos_integer()
        }
end

defmodule Concord.StateMachine.Core do
  @moduledoc """
  Protocol-independent deterministic Concord state machine.

  This module owns all authoritative service data. It does not access ETS,
  clocks, processes, telemetry, storage, or a replication protocol.
  """

  alias Concord.Compression
  alias Concord.Index.Extractor
  alias Concord.KV.Record
  alias Concord.StateMachine.Core.{Context, State}
  alias Concord.Txn.Result

  @snapshot_version 4
  @idempotency_cache_size 100_000
  @idempotency_retention_revisions 10_000

  @type query_context :: %{required(:timestamp_ms) => non_neg_integer()} | Context.t()

  @spec init(keyword()) :: State.t()
  def init(_opts \\ []), do: %State{}

  @spec apply(Context.t(), term(), State.t()) :: {term(), State.t()}
  def apply(%Context{} = context, command, %State{} = state) do
    {result, state} = do_apply(context, command, state)
    {result, %{state | command_count: state.command_count + 1}}
  end

  @doc false
  @spec apply_command(Context.t(), term(), State.t()) :: {term(), State.t()}
  def apply_command(%Context{} = context, command, %State{} = state) do
    do_apply(context, command, state)
  end

  defp do_apply(context, {:put, key, value}, state) do
    do_apply(context, {:put, key, value, nil}, state)
  end

  defp do_apply(context, {:put, key, value, %{} = opts}, state) do
    expires_at =
      case Map.get(opts, :ttl) do
        nil -> nil
        ttl -> now_seconds(context) + ttl
      end

    previous = Map.get(state.current, key)
    old_value = decompress_record(previous)
    revision = state.revision + 1

    record = Record.next(value, revision, previous, expires_at, opts)

    state =
      state
      |> save_previous(key, previous)
      |> put_record(key, record)
      |> update_indexes(key, old_value, Compression.decompress(value))
      |> attach_to_lease(key, record.lease_id)
      |> Map.put(:revision, revision)

    result = %{
      revision: revision,
      prev_kv: if(Map.get(opts, :prev_kv, false), do: previous, else: nil)
    }

    {result, state}
  end

  defp do_apply(_context, {:put, key, value, expires_at}, state) do
    previous = Map.get(state.current, key)
    old_value = legacy_value(state, key)
    revision = state.revision + 1

    record = %Record{
      value: value,
      create_revision:
        if(previous && previous.version > 0, do: previous.create_revision, else: revision),
      mod_revision: revision,
      version: if(previous && previous.version > 0, do: previous.version + 1, else: 1),
      expires_at: expires_at,
      lease_id: nil,
      content_type: nil,
      metadata: %{}
    }

    state =
      state
      |> save_previous(key, previous)
      |> put_record(key, record)
      |> update_indexes(key, old_value, Compression.decompress(value))
      |> Map.put(:revision, revision)

    {:ok, state}
  end

  defp do_apply(_context, {:delete, key, %{} = opts}, state) do
    previous = Map.get(state.current, key)
    old_value = legacy_value(state, key)

    if is_nil(old_value) do
      {%{revision: state.revision, prev_kv: nil}, state}
    else
      revision = state.revision + 1
      tombstone = Record.tombstone(key, revision, previous)

      state =
        state
        |> save_previous(key, previous)
        |> put_history(key, revision, tombstone)
        |> delete_key(key)
        |> update_indexes(key, old_value, nil)
        |> Map.put(:revision, revision)

      result = %{
        revision: revision,
        prev_kv: if(Map.get(opts, :prev_kv, false), do: previous, else: nil)
      }

      {result, state}
    end
  end

  defp do_apply(_context, {:delete, key}, state) do
    previous = Map.get(state.current, key)
    old_value = legacy_value(state, key)

    state =
      if is_nil(old_value) do
        state
      else
        revision = state.revision + 1

        state
        |> save_previous(key, previous)
        |> put_history(key, revision, Record.tombstone(key, revision, previous))
        |> delete_key(key)
        |> update_indexes(key, old_value, nil)
        |> Map.put(:revision, revision)
      end

    {:ok, state}
  end

  defp do_apply(context, {:put_if, key, value, expires_at, expected}, state) do
    with {:ok, current_value, current_expires_at} <- fetch_legacy(state, key),
         false <- expired?(current_expires_at, now_seconds(context)),
         ^expected <- Compression.decompress(current_value) do
      old_value = Compression.decompress(current_value)

      state =
        state
        |> put_legacy(key, value, expires_at)
        |> update_indexes(key, old_value, Compression.decompress(value))

      {:ok, state}
    else
      {:error, reason} -> {{:error, reason}, state}
      true -> {{:error, :not_found}, state}
      _ -> {{:error, :condition_failed}, state}
    end
  end

  defp do_apply(context, {:delete_if, key, expected, _condition_fn}, state) do
    with {:ok, current_value, expires_at} <- fetch_legacy(state, key),
         false <- expired?(expires_at, now_seconds(context)),
         ^expected <- Compression.decompress(current_value) do
      old_value = Compression.decompress(current_value)

      state =
        state
        |> Map.update!(:store, &Map.delete(&1, key))
        |> update_indexes(key, old_value, nil)

      {:ok, state}
    else
      {:error, reason} -> {{:error, reason}, state}
      true -> {{:error, :not_found}, state}
      _ -> {{:error, :condition_failed}, state}
    end
  end

  defp do_apply(context, {:touch, key, ttl_seconds}, state) do
    case fetch_legacy(state, key) do
      {:ok, value, _expires_at} ->
        {:ok, put_legacy(state, key, value, now_seconds(context) + ttl_seconds)}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp do_apply(context, :cleanup_expired, state) do
    now = now_seconds(context)

    {state, count} =
      Enum.reduce(state.store, {state, 0}, fn {key, stored}, {acc, count} ->
        case extract_value(stored) do
          {value, expires_at} when not is_nil(expires_at) ->
            if expired?(expires_at, now) do
              old_value = Compression.decompress(value)

              acc =
                acc
                |> Map.update!(:store, &Map.delete(&1, key))
                |> update_indexes(key, old_value, nil)

              {acc, count + 1}
            else
              {acc, count}
            end

          _ ->
            {acc, count}
        end
      end)

    {{:ok, count}, state}
  end

  defp do_apply(_context, {:put_many, operations}, state) when is_list(operations) do
    case validate_put_many(operations) do
      :ok ->
        {results, state} =
          Enum.map_reduce(operations, state, fn operation, acc ->
            {key, value, expires_at} = normalize_put(operation)
            {{key, :ok}, put_legacy(acc, key, value, expires_at)}
          end)

        {{:ok, results}, rebuild_indexes(state)}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp do_apply(_context, {:delete_many, keys}, state) when is_list(keys) do
    cond do
      length(keys) > 500 ->
        {{:error, :batch_too_large}, state}

      Enum.all?(keys, &(is_binary(&1) and byte_size(&1) > 0)) ->
        {results, state} =
          Enum.map_reduce(keys, state, fn key, acc ->
            {{key, :ok}, Map.update!(acc, :store, &Map.delete(&1, key))}
          end)

        {{:ok, results}, rebuild_indexes(state)}

      true ->
        {{:error, :invalid_key}, state}
    end
  end

  defp do_apply(context, {:touch_many, operations}, state) when is_list(operations) do
    cond do
      length(operations) > 500 ->
        {{:error, :batch_too_large}, state}

      Enum.all?(operations, &valid_touch?/1) ->
        now = now_seconds(context)

        {results, state} =
          Enum.map_reduce(operations, state, fn {key, ttl}, acc ->
            case fetch_legacy(acc, key) do
              {:ok, value, _} ->
                {{key, :ok}, put_legacy(acc, key, value, now + ttl)}

              {:error, _} ->
                {{key, {:error, :not_found}}, acc}
            end
          end)

        {{:ok, results}, state}

      true ->
        {{:error, :invalid_touch_operation}, state}
    end
  end

  defp do_apply(_context, {:create_index, name, extractor}, state) do
    if Map.has_key?(state.indexes, name) do
      {{:error, :index_exists}, state}
    else
      state = %{
        state
        | indexes: Map.put(state.indexes, name, extractor),
          index_entries: Map.put(state.index_entries, name, %{})
      }

      {:ok, state}
    end
  end

  defp do_apply(_context, {:drop_index, name}, state) do
    if Map.has_key?(state.indexes, name) do
      state = %{
        state
        | indexes: Map.delete(state.indexes, name),
          index_entries: Map.delete(state.index_entries, name)
      }

      {:ok, state}
    else
      {{:error, :not_found}, state}
    end
  end

  defp do_apply(_context, {:reindex, name}, state) do
    if Map.has_key?(state.indexes, name) do
      state = %{state | index_entries: Map.put(state.index_entries, name, %{})}

      state =
        Enum.reduce(state.store, state, fn {key, stored}, acc ->
          {value, _expires_at} = extract_value(stored)
          update_one_index(acc, name, key, Compression.decompress(value))
        end)

      {:ok, state}
    else
      {{:error, :not_found}, state}
    end
  end

  defp do_apply(_context, {:restore_backup, %{version: 2} = backup}, state) do
    state = %{
      state
      | store: entries_to_map(Map.get(backup, :kv_data, [])),
        indexes: Map.get(backup, :indexes, %{})
    }

    {:ok, rebuild_indexes(state)}
  end

  defp do_apply(_context, {:restore_backup, entries}, state) when is_list(entries) do
    {:ok, rebuild_indexes(%{state | store: entries_to_map(entries)})}
  end

  defp do_apply(context, {:get_many, keys}, state) when is_list(keys) do
    {{:ok, batch_get(state, keys, now_seconds(context))}, state}
  end

  defp do_apply(context, {:txn, spec}, state) do
    case txn_request_status(spec, state) do
      :disabled ->
        apply_txn(context, spec, state)

      {:hit, result} ->
        {{:ok, result}, state}

      :conflict ->
        {{:error, :idempotency_conflict}, state}

      {:miss, key, request_hash} ->
        {{:ok, %Result{} = result} = response, state} = apply_txn(context, spec, state)
        state = cache_txn_request(state, key, request_hash, result, context)
        {response, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp do_apply(context, {:grant_lease, ttl, _opts}, state) do
    id = state.next_lease_id

    lease = %{
      id: id,
      ttl: ttl,
      expires_at: now_seconds(context) + ttl,
      granted_at: state.revision + 1,
      keys: []
    }

    state = %{
      state
      | leases: Map.put(state.leases, id, lease),
        next_lease_id: id + 1,
        revision: state.revision + 1
    }

    {{:ok, %{lease_id: id, ttl: ttl}}, state}
  end

  defp do_apply(context, {:keep_alive_lease, id, _opts}, state) do
    case Map.fetch(state.leases, id) do
      {:ok, lease} ->
        lease = %{lease | expires_at: now_seconds(context) + lease.ttl}
        {:ok, %{state | leases: Map.put(state.leases, id, lease)}}

      :error ->
        {{:error, :lease_not_found}, state}
    end
  end

  defp do_apply(_context, {:revoke_lease, id, _opts}, state) do
    case Map.fetch(state.leases, id) do
      {:ok, lease} ->
        revision = state.revision + 1

        {deleted, state} =
          Enum.reduce(lease.keys, {0, state}, fn key, {count, acc} ->
            case Map.get(acc.current, key) do
              %Record{version: version} = previous when version > 0 ->
                old_value = Compression.decompress(previous.value)

                acc =
                  acc
                  |> save_previous(key, previous)
                  |> put_history(key, revision, Record.tombstone(key, revision, previous))
                  |> delete_key(key)
                  |> update_indexes(key, old_value, nil)

                {count + 1, acc}

              _ ->
                {count, acc}
            end
          end)

        state = %{
          state
          | leases: Map.delete(state.leases, id),
            revision: revision
        }

        {{:ok, %{deleted_keys: deleted}}, state}

      :error ->
        {{:error, :lease_not_found}, state}
    end
  end

  defp do_apply(context, {:expire_lease, id}, state) do
    do_apply(context, {:revoke_lease, id, %{}}, state)
  end

  defp do_apply(_context, _command, state), do: {:ok, state}

  defp apply_txn(context, spec, state) do
    now = now_seconds(context)
    success? = Enum.all?(Map.get(spec, :compare, []), &eval_compare(&1, state, now))
    operations = if success?, do: Map.get(spec, :success, []), else: Map.get(spec, :failure, [])
    mutating? = Enum.any?(operations, &mutating_op?/1)
    revision = if mutating?, do: state.revision + 1, else: state.revision

    {responses, state} =
      Enum.map_reduce(operations, state, fn operation, acc ->
        execute_txn(operation, acc, revision, context)
      end)

    state = if mutating?, do: %{state | revision: revision}, else: state
    result = %Result{succeeded: success?, revision: revision, responses: responses}
    {{:ok, result}, state}
  end

  @spec query(term(), State.t(), query_context()) :: term()
  def query(query, %State{} = state, context) do
    now = query_now_seconds(context)
    do_query(query, state, now)
  end

  defp do_query({:get, key}, state, now) do
    case fetch_legacy(state, key) do
      {:ok, value, expires_at} ->
        if expired?(expires_at, now), do: {:error, :not_found}, else: {:ok, value}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_query({:get_with_ttl, key}, state, now) do
    case fetch_legacy(state, key) do
      {:ok, value, expires_at} ->
        if expired?(expires_at, now) do
          {:error, :not_found}
        else
          ttl = if expires_at, do: max(0, expires_at - now), else: nil
          {:ok, {value, ttl}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_query(:get_all, state, now) do
    values =
      Enum.reduce(state.store, %{}, fn {key, stored}, acc ->
        {value, expires_at} = extract_value(stored)
        if expired?(expires_at, now), do: acc, else: Map.put(acc, key, value)
      end)

    {:ok, values}
  end

  defp do_query(:get_all_with_ttl, state, now) do
    values =
      Enum.reduce(state.store, %{}, fn {key, stored}, acc ->
        {value, expires_at} = extract_value(stored)

        if expired?(expires_at, now) do
          acc
        else
          ttl = if expires_at, do: max(0, expires_at - now), else: nil
          Map.put(acc, key, %{value: value, ttl: ttl})
        end
      end)

    {:ok, values}
  end

  defp do_query({:ttl, key}, state, now) do
    case fetch_legacy(state, key) do
      {:ok, _value, expires_at} ->
        cond do
          expired?(expires_at, now) -> {:error, :not_found}
          expires_at -> {:ok, max(0, expires_at - now)}
          true -> {:ok, nil}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_query({:get_many, keys}, state, now) when is_list(keys) do
    {:ok, Map.new(batch_get(state, keys, now))}
  end

  defp do_query({:prefix_scan, prefix}, state, now) when is_binary(prefix) do
    values =
      state.store
      |> Enum.filter(fn {key, _} -> String.starts_with?(key, prefix) end)
      |> Enum.reduce([], fn {key, stored}, acc ->
        {value, expires_at} = extract_value(stored)
        if expired?(expires_at, now), do: acc, else: [{key, value} | acc]
      end)

    {:ok, values}
  end

  defp do_query(:stats, state, _now) do
    {:ok,
     %{
       size: map_size(state.store),
       memory: byte_size(:erlang.term_to_binary(state.store))
     }}
  end

  defp do_query(:backup_snapshot, state, _now) do
    {:ok,
     %{
       version: 2,
       kv_data: Map.to_list(state.store),
       indexes: state.indexes
     }}
  end

  defp do_query({:index_lookup, name, value}, state, _now) do
    if Map.has_key?(state.indexes, name) do
      {:ok, get_in(state.index_entries, [name, value]) || []}
    else
      {:ok, {:error, :not_found}}
    end
  end

  defp do_query(:list_indexes, state, _now), do: {:ok, Map.keys(state.indexes)}

  defp do_query({:get_index_extractor, name}, state, _now) do
    case Map.fetch(state.indexes, name) do
      {:ok, extractor} -> {:ok, extractor}
      :error -> {:ok, {:error, :not_found}}
    end
  end

  defp do_query({:get_record, key}, state, now) do
    case Map.get(state.current, key) do
      %Record{} = record ->
        if Record.expired?(record, now), do: {:error, :not_found}, else: {:ok, record}

      _ ->
        {:error, :not_found}
    end
  end

  defp do_query({:get, key, revision: revision}, state, _now) do
    if revision <= state.compact_revision do
      {:error, {:compacted, state.compact_revision}}
    else
      case Map.get(state.current, key) do
        %Record{mod_revision: mod_revision} = record when mod_revision <= revision ->
          if Record.tombstone?(record), do: {:error, :not_found}, else: {:ok, record.value}

        _ ->
          find_record_at_revision(state, key, revision)
      end
    end
  end

  defp do_query(:get_revision, state, _now), do: {:ok, state.revision}

  defp do_query({:txn_result, idempotency_key}, state, _now) do
    case Map.fetch(state.requests, idempotency_key) do
      {:ok, %{result: result}} -> {:ok, result}
      :error -> {:error, :not_found}
    end
  end

  defp do_query({:history, key, opts}, state, _now) do
    from_revision = Keyword.get(opts, :from_revision, 0)
    to_revision = Keyword.get(opts, :to_revision, state.revision)
    limit = Keyword.get(opts, :limit, 100)

    if from_revision <= state.compact_revision do
      {:error, {:compacted, state.compact_revision}}
    else
      history =
        state.history
        |> Enum.filter(fn {{entry_key, revision}, _record} ->
          entry_key == key and revision >= from_revision and revision <= to_revision
        end)
        |> Enum.map(fn {_key, record} -> record end)

      current =
        case Map.get(state.current, key) do
          %Record{mod_revision: revision} = record
          when revision >= from_revision and revision <= to_revision ->
            [record]

          _ ->
            []
        end

      records =
        (history ++ current)
        |> Enum.uniq_by(& &1.mod_revision)
        |> Enum.sort_by(& &1.mod_revision)
        |> Enum.take(limit)

      {:ok, records}
    end
  end

  defp do_query({:list, selector, opts}, state, now) do
    limit = Map.get(opts, :limit, 1000)
    keys_only = Map.get(opts, :keys_only, false)

    entries =
      state.current
      |> Enum.filter(fn {key, record} ->
        selector_match?(selector, key) and not Record.expired?(record, now)
      end)
      |> Enum.sort_by(&elem(&1, 0))

    has_more = length(entries) > limit
    entries = Enum.take(entries, limit)

    records =
      Enum.map(entries, fn {key, record} ->
        record = if keys_only, do: %{record | value: nil}, else: record
        Map.put(record, :key, key)
      end)

    last_key = if entries == [], do: nil, else: entries |> List.last() |> elem(0)
    {:ok, records, %{has_more: has_more, last_key: last_key}}
  end

  defp do_query({:lease_info, id}, state, now) do
    case Map.fetch(state.leases, id) do
      {:ok, lease} -> {:ok, Map.put(lease, :remaining, max(0, lease.expires_at - now))}
      :error -> {:error, :lease_not_found}
    end
  end

  defp do_query(:list_leases, state, now) do
    leases =
      Enum.map(state.leases, fn {_id, lease} ->
        Map.put(lease, :remaining, max(0, lease.expires_at - now))
      end)

    {:ok, leases}
  end

  defp do_query(_query, _state, _now), do: {:error, :unknown_query}

  @spec snapshot(State.t()) :: {:ok, map()}
  def snapshot(%State{} = state) do
    {:ok, %{__concord_snapshot_version__: @snapshot_version, state: state}}
  end

  @spec restore(term()) :: {:ok, State.t()} | {:error, term()}
  def restore(%{__concord_snapshot_version__: @snapshot_version, state: state}) do
    normalize_state(state)
  end

  def restore({:concord_kv, data}) when is_map(data) do
    state =
      data
      |> normalize_state_map()
      |> Map.put(:store, entries_to_map(Map.get(data, :__kv_data__, Map.get(data, :store, %{}))))
      |> Map.put(
        :current,
        entries_to_map(Map.get(data, :__current_data__, Map.get(data, :current, %{})))
      )
      |> Map.put(
        :history,
        entries_to_map(Map.get(data, :__history_data__, Map.get(data, :history, %{})))
      )
      |> Map.put(
        :leases,
        entries_to_map(Map.get(data, :__lease_data__, Map.get(data, :leases, %{})))
      )
      |> Map.put(
        :index_entries,
        normalize_index_entries(Map.get(data, :__index_ets__, Map.get(data, :index_entries, %{})))
      )
      |> then(&struct(State, &1))

    {:ok, state}
  end

  def restore(entries) when is_list(entries) do
    {:ok, %{init() | store: entries_to_map(entries)}}
  end

  def restore(%State{} = state), do: normalize_state(state)
  def restore(data) when is_map(data), do: normalize_state(data)
  def restore(_snapshot), do: {:error, :invalid_snapshot}

  defp normalize_state(%State{} = state) do
    {:ok, struct(State, Map.from_struct(state))}
  end

  defp normalize_state(data) when is_map(data) do
    {:ok, struct(State, normalize_state_map(data))}
  rescue
    KeyError -> {:error, :invalid_snapshot}
  end

  @doc false
  def from_legacy_tables(%State{} = state, tables) when is_map(tables) do
    state = %{
      state
      | store: entries_to_map(Map.get(tables, :store, state.store)),
        current: entries_to_map(Map.get(tables, :current, state.current)),
        history: entries_to_map(Map.get(tables, :history, state.history)),
        leases: entries_to_map(Map.get(tables, :leases, state.leases)),
        index_entries:
          normalize_index_entries(Map.get(tables, :index_entries, state.index_entries))
    }

    state
  end

  defp normalize_state_map(data) do
    defaults = Map.from_struct(%State{})

    data
    |> Map.take(Map.keys(defaults))
    |> then(&Map.merge(defaults, &1))
  end

  defp normalize_index_entries(index_entries) do
    Map.new(index_entries, fn {name, entries} -> {name, entries_to_map(entries)} end)
  end

  defp entries_to_map(entries) when is_map(entries), do: entries
  defp entries_to_map(entries) when is_list(entries), do: Map.new(entries)
  defp entries_to_map(_entries), do: %{}

  defp now_seconds(%Context{timestamp_ms: timestamp_ms}), do: div(timestamp_ms, 1000)
  defp query_now_seconds(%Context{} = context), do: now_seconds(context)

  defp query_now_seconds(%{timestamp_ms: timestamp_ms})
       when is_integer(timestamp_ms) and timestamp_ms >= 0,
       do: div(timestamp_ms, 1000)

  defp query_now_seconds(timestamp_ms) when is_integer(timestamp_ms) and timestamp_ms >= 0,
    do: div(timestamp_ms, 1000)

  defp extract_value(%Record{} = record), do: {record.value, record.expires_at}
  defp extract_value(%{value: value, expires_at: expires_at}), do: {value, expires_at}
  defp extract_value({value, expires_at}) when is_integer(expires_at), do: {value, expires_at}
  defp extract_value(value), do: {value, nil}

  defp expired?(nil, _now), do: false
  defp expired?(expires_at, now), do: now > expires_at

  defp fetch_legacy(state, key) do
    case Map.fetch(state.store, key) do
      {:ok, stored} ->
        {value, expires_at} = extract_value(stored)
        {:ok, value, expires_at}

      :error ->
        {:error, :not_found}
    end
  end

  defp legacy_value(state, key) do
    case fetch_legacy(state, key) do
      {:ok, value, _expires_at} -> Compression.decompress(value)
      _ -> nil
    end
  end

  defp decompress_record(nil), do: nil
  defp decompress_record(%Record{value: value}), do: Compression.decompress(value)

  defp put_legacy(state, key, value, expires_at) do
    %{state | store: Map.put(state.store, key, %{value: value, expires_at: expires_at})}
  end

  defp put_record(state, key, %Record{} = record) do
    %{
      state
      | current: Map.put(state.current, key, record),
        store: Map.put(state.store, key, %{value: record.value, expires_at: record.expires_at})
    }
  end

  defp delete_key(state, key) do
    %{
      state
      | current: Map.delete(state.current, key),
        store: Map.delete(state.store, key)
    }
  end

  defp save_previous(state, _key, nil), do: state

  defp save_previous(state, key, %Record{} = record) do
    put_history(state, key, record.mod_revision, record)
  end

  defp put_history(state, key, revision, record) do
    %{state | history: Map.put(state.history, {key, revision}, record)}
  end

  defp attach_to_lease(state, _key, nil), do: state

  defp attach_to_lease(state, key, id) do
    case Map.fetch(state.leases, id) do
      {:ok, lease} ->
        keys = if key in lease.keys, do: lease.keys, else: [key | lease.keys]
        %{state | leases: Map.put(state.leases, id, %{lease | keys: keys})}

      :error ->
        state
    end
  end

  defp update_indexes(state, key, old_value, new_value) do
    entries =
      Enum.reduce(state.indexes, state.index_entries, fn {name, extractor}, acc ->
        index = Map.get(acc, name, %{})
        index = remove_index_values(index, Extractor.extract(extractor, old_value), key)
        index = add_index_values(index, Extractor.extract(extractor, new_value), key)
        Map.put(acc, name, index)
      end)

    %{state | index_entries: entries}
  end

  defp update_one_index(state, name, key, value) do
    extractor = Map.fetch!(state.indexes, name)
    index = Map.get(state.index_entries, name, %{})
    index = add_index_values(index, Extractor.extract(extractor, value), key)
    %{state | index_entries: Map.put(state.index_entries, name, index)}
  end

  defp remove_index_values(index, nil, _key), do: index

  defp remove_index_values(index, values, key) when is_list(values) do
    Enum.reduce(values, index, &remove_index_value(&2, &1, key))
  end

  defp remove_index_values(index, value, key), do: remove_index_value(index, value, key)

  defp remove_index_value(index, value, key) do
    case Map.get(index, value) do
      nil ->
        index

      keys ->
        case List.delete(keys, key) do
          [] -> Map.delete(index, value)
          remaining -> Map.put(index, value, remaining)
        end
    end
  end

  defp add_index_values(index, nil, _key), do: index

  defp add_index_values(index, values, key) when is_list(values) do
    Enum.reduce(values, index, &add_index_value(&2, &1, key))
  end

  defp add_index_values(index, value, key), do: add_index_value(index, value, key)

  defp add_index_value(index, value, key) do
    Map.update(index, value, [key], fn keys -> if key in keys, do: keys, else: [key | keys] end)
  end

  defp rebuild_indexes(state) do
    entries = Map.new(state.indexes, fn {name, _extractor} -> {name, %{}} end)
    state = %{state | index_entries: entries}

    Enum.reduce(state.store, state, fn {key, stored}, acc ->
      {value, _expires_at} = extract_value(stored)
      update_indexes(acc, key, nil, Compression.decompress(value))
    end)
  end

  defp validate_put_many(operations) do
    if length(operations) > 500 do
      {:error, :batch_too_large}
    else
      Enum.reduce_while(operations, :ok, fn operation, :ok ->
        case validate_put(operation) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_put({key, _value, expires_at}) when is_binary(key) do
    cond do
      byte_size(key) == 0 -> {:error, :invalid_key}
      not is_nil(expires_at) and not is_integer(expires_at) -> {:error, :invalid_expires_at}
      true -> :ok
    end
  end

  defp validate_put({key, _value}) when is_binary(key) do
    if byte_size(key) == 0, do: {:error, :invalid_key}, else: :ok
  end

  defp validate_put(_operation), do: {:error, :invalid_operation_format}

  defp normalize_put({key, value}), do: {key, value, nil}
  defp normalize_put({key, value, expires_at}), do: {key, value, expires_at}

  defp valid_touch?({key, ttl}) when is_binary(key) and is_integer(ttl) and ttl > 0, do: true
  defp valid_touch?(_operation), do: false

  defp batch_get(state, keys, now) do
    Enum.map(keys, fn key ->
      result =
        case fetch_legacy(state, key) do
          {:ok, value, expires_at} ->
            if expired?(expires_at, now), do: {:error, :not_found}, else: {:ok, value}

          {:error, reason} ->
            {:error, reason}
        end

      {key, result}
    end)
  end

  defp selector_match?({:key, expected}, key), do: key == expected
  defp selector_match?({:prefix, prefix}, key), do: String.starts_with?(key, prefix)
  defp selector_match?({:range, start_key, end_key}, key), do: key >= start_key and key < end_key

  defp find_record_at_revision(state, key, target_revision) do
    state.history
    |> Enum.filter(fn
      {{^key, revision}, _record} -> revision <= target_revision
      _ -> false
    end)
    |> Enum.max_by(fn {{_key, revision}, _record} -> revision end, fn -> nil end)
    |> case do
      nil ->
        {:error, :not_found}

      {_key, record} ->
        if Record.tombstone?(record), do: {:error, :not_found}, else: {:ok, record.value}
    end
  end

  defp mutating_op?({:put, _, _, _}), do: true
  defp mutating_op?({:delete, _, _}), do: true
  defp mutating_op?({:touch, _, _, _}), do: true
  defp mutating_op?(_operation), do: false

  defp eval_compare({:exists, key, operation, expected}, state, now) do
    exists =
      case Map.get(state.current, key) do
        %Record{} = record -> not Record.expired?(record, now) and record.version > 0
        _ -> false
      end

    compare(operation, exists, expected)
  end

  defp eval_compare({:value, key, operation, expected}, state, now) do
    compare(operation, record_field(state, key, now, :value, nil), expected)
  end

  defp eval_compare({:field, key, path, operation, expected}, state, now) do
    value = record_field(state, key, now, :value, nil)
    compare(operation, extract_field(value, path), expected)
  end

  defp eval_compare({field, key, operation, expected}, state, now)
       when field in [:version, :create_revision, :mod_revision, :lease] do
    record_field =
      case field do
        :lease -> :lease_id
        other -> other
      end

    compare(operation, record_field(state, key, now, record_field, 0), expected)
  end

  defp eval_compare({:ttl, key, operation, expected}, state, now) do
    ttl =
      case Map.get(state.current, key) do
        %Record{} = record ->
          cond do
            Record.expired?(record, now) -> 0
            record.expires_at -> max(0, record.expires_at - now)
            true -> nil
          end

        _ ->
          0
      end

    compare(operation, ttl, expected)
  end

  defp eval_compare(_compare, _state, _now), do: false

  defp record_field(state, key, now, field, default) do
    case Map.get(state.current, key) do
      %Record{} = record ->
        if Record.expired?(record, now) or record.version == 0,
          do: default,
          else: Map.get(record, field, default)

      _ ->
        default
    end
  end

  defp extract_field(nil, _path), do: nil
  defp extract_field(value, path) when is_list(path), do: get_in(value, path)

  defp compare(:==, left, right), do: left == right
  defp compare(:!=, left, right), do: left != right
  defp compare(:>, left, right) when is_number(left) and is_number(right), do: left > right
  defp compare(:>=, left, right) when is_number(left) and is_number(right), do: left >= right
  defp compare(:<, left, right) when is_number(left) and is_number(right), do: left < right
  defp compare(:<=, left, right) when is_number(left) and is_number(right), do: left <= right
  defp compare(_operation, _left, _right), do: false

  defp execute_txn({:get, {:key, key} = selector, _opts}, state, _revision, context) do
    now = now_seconds(context)

    records =
      case Map.get(state.current, key) do
        %Record{} = record ->
          if Record.expired?(record, now) or record.version == 0, do: [], else: [record]

        _ ->
          []
      end

    {{:get, selector, %{kvs: records, count: length(records)}}, state}
  end

  defp execute_txn({:get, selector, opts}, state, _revision, context) do
    now = now_seconds(context)
    limit = Map.get(opts, :limit, 1000)

    records =
      state.current
      |> Enum.filter(fn {key, record} ->
        selector_match?(selector, key) and not Record.expired?(record, now) and record.version > 0
      end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sort_by(& &1.mod_revision)
      |> Enum.take(limit)

    {{:get, selector, %{kvs: records, count: length(records)}}, state}
  end

  defp execute_txn({:put, key, value, opts}, state, revision, context) do
    previous = Map.get(state.current, key)
    old_value = decompress_record(previous)

    expires_at =
      case Map.get(opts, :ttl) do
        nil -> nil
        ttl -> now_seconds(context) + ttl
      end

    record = Record.next(value, revision, previous, expires_at, opts)

    state =
      state
      |> save_previous(key, previous)
      |> put_record(key, record)
      |> update_indexes(key, old_value, Compression.decompress(value))
      |> attach_to_lease(key, record.lease_id)

    response =
      {:put, key, %{prev_kv: if(Map.get(opts, :prev_kv, false), do: previous, else: nil)}}

    {response, state}
  end

  defp execute_txn({:delete, selector, opts}, state, revision, _context) do
    keys =
      state.current
      |> Map.keys()
      |> Enum.filter(&selector_match?(selector, &1))

    {previous_records, state} =
      Enum.reduce(keys, {[], state}, fn key, {records, acc} ->
        case Map.get(acc.current, key) do
          %Record{version: version} = previous when version > 0 ->
            old_value = Compression.decompress(previous.value)

            acc =
              acc
              |> save_previous(key, previous)
              |> put_history(key, revision, Record.tombstone(key, revision, previous))
              |> delete_key(key)
              |> update_indexes(key, old_value, nil)

            {[previous | records], acc}

          _ ->
            {records, acc}
        end
      end)

    previous_records =
      if Map.get(opts, :prev_kv, false), do: Enum.reverse(previous_records), else: []

    response = {:delete, selector, %{deleted: length(keys), prev_kvs: previous_records}}
    {response, state}
  end

  defp execute_txn({:touch, key, ttl, _opts}, state, revision, context) do
    now = now_seconds(context)

    case Map.get(state.current, key) do
      %Record{} = record ->
        if Record.expired?(record, now) or record.version == 0 do
          {{:touch, key, %{ttl: :not_found}}, state}
        else
          record = %{record | expires_at: now + ttl, mod_revision: revision}
          {{:touch, key, %{ttl: ttl}}, put_record(state, key, record)}
        end

      _ ->
        {{:touch, key, %{ttl: :not_found}}, state}
    end
  end

  defp execute_txn(_operation, state, _revision, _context) do
    {{:error, :unsupported_op}, state}
  end

  defp txn_request_status(spec, state) do
    case Map.get(spec, :idempotency_key) do
      nil ->
        :disabled

      key when is_binary(key) and byte_size(key) > 0 ->
        request_hash = txn_request_hash(spec)

        case Map.fetch(state.requests, key) do
          {:ok, %{request_hash: ^request_hash, result: result}} -> {:hit, result}
          {:ok, _entry} -> :conflict
          :error -> {:miss, key, request_hash}
        end

      _invalid ->
        {:error, :invalid_idempotency_key}
    end
  end

  defp txn_request_hash(spec) do
    spec
    |> Map.delete(:idempotency_key)
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp cache_txn_request(state, key, request_hash, result, context) do
    entry = %{
      request_hash: request_hash,
      revision: result.revision,
      result: result,
      cached_at: context.op_number
    }

    minimum_revision = max(0, state.revision - @idempotency_retention_revisions)

    requests =
      state.requests
      |> Enum.reject(fn {_key, cached} -> cached.revision < minimum_revision end)
      |> Map.new()
      |> Map.put(key, entry)
      |> enforce_idempotency_cache_size()

    %{state | requests: requests}
  end

  defp enforce_idempotency_cache_size(requests)
       when map_size(requests) <= @idempotency_cache_size,
       do: requests

  defp enforce_idempotency_cache_size(requests) do
    overflow = map_size(requests) - @idempotency_cache_size

    oldest_keys =
      requests
      |> Enum.sort_by(fn {key, entry} -> {entry.revision, entry.cached_at, key} end)
      |> Enum.take(overflow)
      |> Enum.map(&elem(&1, 0))

    Map.drop(requests, oldest_keys)
  end
end
