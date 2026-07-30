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
            representation: :current,
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
          representation: :current | :legacy,
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

  alias Concord.CommandSchema
  alias Concord.Compression
  alias Concord.Index.Extractor
  alias Concord.KV.Record
  alias Concord.StateMachine.Core.{Context, State}
  alias Concord.StateMachine.SnapshotValidator
  alias Concord.Txn.Result

  @snapshot_version 4
  @idempotency_cache_size 100_000
  @idempotency_retention_revisions 10_000
  @representation_conflict_sample_size 100

  @type query_context :: %{required(:timestamp_ms) => non_neg_integer()} | Context.t()

  @spec init(keyword()) :: State.t()
  def init(_opts \\ []), do: %State{}

  @spec apply(Context.t(), term(), State.t()) :: {term(), State.t()}
  def apply(%Context{} = context, command, %State{} = state) do
    case CommandSchema.validate(1, command) do
      :ok ->
        command = normalize_current_command(command)

        case ensure_current_representation(command, state) do
          :ok -> finalize_apply(do_apply(context, command, state), state)
          {:error, reason} -> {{:error, reason}, state}
        end

      {:error, :unsupported_command} ->
        {invalid_command_result(command), state}
    end
  end

  @doc false
  @spec apply_legacy(Context.t(), term(), State.t()) :: {term(), State.t()}
  def apply_legacy(%Context{} = context, command, %State{} = state) do
    {result, state} = finalize_apply(do_apply_legacy(context, command, state), state)
    {result, %{state | representation: :legacy}}
  end

  defp finalize_apply(result, original_state) do
    case result do
      {{:error, :unsupported_command} = result, _next_state} ->
        {result, original_state}

      {result, next_state} ->
        {result, %{next_state | command_count: next_state.command_count + 1}}
    end
  end

  @doc false
  @spec apply_command(Context.t(), term(), State.t()) :: {term(), State.t()}
  def apply_command(%Context{} = context, command, %State{} = state) do
    case CommandSchema.validate(1, command) do
      :ok -> do_apply(context, normalize_current_command(command), state)
      {:error, :unsupported_command} -> {invalid_command_result(command), state}
    end
  end

  @doc false
  @spec apply_compatibility(Context.t(), term(), State.t()) :: {term(), State.t()}
  def apply_compatibility(%Context{} = context, command, %State{} = state) do
    case CommandSchema.validate(1, command) do
      :ok ->
        command = normalize_current_command(command)
        finalize_apply(do_apply(context, command, state), state)

      {:error, :unsupported_command} ->
        {invalid_command_result(command), state}
    end
  end

  defp do_apply_legacy(_context, {:create_index, name, extractor}, state) do
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

  defp do_apply_legacy(_context, {:restore_backup, %{version: 2} = backup}, state) do
    state = %{
      state
      | store: entries_to_map(Map.get(backup, :kv_data, [])),
        indexes: Map.get(backup, :indexes, %{})
    }

    {:ok, rebuild_indexes(state)}
  end

  defp do_apply_legacy(_context, {:restore_backup, entries}, state) when is_list(entries) do
    {:ok, rebuild_indexes(%{state | store: entries_to_map(entries)})}
  end

  defp do_apply_legacy(context, {:put, key, value}, state) do
    do_apply_legacy(context, {:put, key, value, nil}, state)
  end

  defp do_apply_legacy(context, {:put, key, value, %{} = opts}, state) do
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

  defp do_apply_legacy(_context, {:put, key, value, expires_at}, state) do
    previous = Map.get(state.current, key)
    old_value = legacy_value(state, key)
    revision = state.revision + 1

    record = Record.next(value, revision, previous, expires_at)

    state =
      state
      |> save_previous(key, previous)
      |> put_record(key, record)
      |> update_indexes(key, old_value, Compression.decompress(value))
      |> Map.put(:revision, revision)

    {:ok, state}
  end

  defp do_apply_legacy(_context, {:delete, key, %{} = opts}, state) do
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

  defp do_apply_legacy(_context, {:delete, key}, state) do
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

  # Version zero replay must retain the exact pre-versioning behavior of these
  # commands. They intentionally mutate only the legacy store representation;
  # version one uses the coherent handlers below.
  defp do_apply_legacy(context, {:put_if, key, value, expires_at, expected}, state) do
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

  defp do_apply_legacy(context, {:delete_if, key, expected, _condition_fn}, state) do
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

  defp do_apply_legacy(context, {:touch, key, ttl_seconds}, state) do
    case fetch_legacy(state, key) do
      {:ok, value, _expires_at} ->
        {:ok, put_legacy(state, key, value, now_seconds(context) + ttl_seconds)}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp do_apply_legacy(context, :cleanup_expired, state) do
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

  defp do_apply_legacy(_context, {:put_many, operations}, state) when is_list(operations) do
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

  defp do_apply_legacy(_context, {:delete_many, keys}, state) when is_list(keys) do
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

  defp do_apply_legacy(context, {:touch_many, operations}, state) when is_list(operations) do
    cond do
      length(operations) > 500 ->
        {{:error, :batch_too_large}, state}

      Enum.all?(operations, &valid_touch?/1) ->
        now = now_seconds(context)

        {results, state} =
          Enum.map_reduce(operations, state, fn {key, ttl}, acc ->
            case fetch_legacy(acc, key) do
              {:ok, value, _expires_at} ->
                {{key, :ok}, put_legacy(acc, key, value, now + ttl)}

              {:error, _reason} ->
                {{key, {:error, :not_found}}, acc}
            end
          end)

        {{:ok, results}, state}

      true ->
        {{:error, :invalid_touch_operation}, state}
    end
  end

  defp do_apply_legacy(context, {:txn, spec}, state) when is_map(spec) do
    case txn_request_status(spec, state) do
      :disabled ->
        apply_txn_legacy(context, spec, state)

      {:hit, result} ->
        {{:ok, result}, state}

      :conflict ->
        {{:error, :idempotency_conflict}, state}

      {:miss, key, request_hash} ->
        {{:ok, %Result{} = result} = response, state} =
          apply_txn_legacy(context, spec, state)

        state = cache_txn_request(state, key, request_hash, result, context)
        {response, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp do_apply_legacy(_context, {:reindex, name}, state) do
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

  defp do_apply_legacy(context, command, state) do
    if legacy_dispatched_command?(command) do
      do_apply(context, command, state)
    else
      {:ok, state}
    end
  end

  defp do_apply(context, {:put, key, value}, state) do
    do_apply(context, {:put, key, value, nil}, state)
  end

  defp do_apply(context, {:put, key, value, %{} = opts}, state) do
    case Map.get(opts, :lease) do
      nil ->
        do_apply_current_put(context, key, value, opts, state)

      id ->
        if Map.has_key?(state.leases, id),
          do: do_apply_current_put(context, key, value, opts, state),
          else: {{:error, :lease_not_found}, state}
    end
  end

  defp do_apply(_context, {:put, key, value, expires_at}, state) do
    previous = Map.get(state.current, key)
    old_value = legacy_value(state, key)
    revision = state.revision + 1

    record = Record.next(value, revision, previous, expires_at)

    state =
      state
      |> save_previous(key, previous)
      |> detach_from_all_leases(key)
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
        |> detach_from_all_leases(key)
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
        |> detach_from_all_leases(key)
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
      {_result, state} = do_apply(context, {:put, key, value, expires_at}, state)
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
      state = delete_current_at_revision(state, key, state.revision + 1)
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
        revision = state.revision + 1
        expires_at = now_seconds(context) + ttl_seconds
        {:ok, touch_current_at_revision(state, key, value, expires_at, revision)}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp do_apply(context, :cleanup_expired, state) do
    now = now_seconds(context)

    expired_keys =
      Enum.flat_map(state.store, fn {key, stored} ->
        case extract_value(stored) do
          {_value, expires_at} when not is_nil(expires_at) ->
            if expired?(expires_at, now), do: [key], else: []

          _other ->
            []
        end
      end)

    revision = if expired_keys == [], do: state.revision, else: state.revision + 1

    state =
      Enum.reduce(expired_keys, state, fn key, acc ->
        delete_current_at_revision(acc, key, revision)
      end)

    {{:ok, length(expired_keys)}, state}
  end

  defp do_apply(_context, {:put_many, operations}, state) when is_list(operations) do
    case validate_put_many(operations) do
      :ok ->
        revision = if operations == [], do: state.revision, else: state.revision + 1

        {results, state} =
          Enum.map_reduce(operations, state, fn operation, acc ->
            {key, value, expires_at} = normalize_put(operation)
            state = put_current_at_revision(acc, key, value, expires_at, revision)
            {{key, :ok}, state}
          end)

        {{:ok, results}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp do_apply(_context, {:delete_many, keys}, state) when is_list(keys) do
    cond do
      length(keys) > 500 ->
        {{:error, :batch_too_large}, state}

      Enum.all?(keys, &(is_binary(&1) and byte_size(&1) > 0)) ->
        mutating? = Enum.any?(keys, &Map.has_key?(state.store, &1))
        revision = if mutating?, do: state.revision + 1, else: state.revision

        {results, state} =
          Enum.map_reduce(keys, state, fn key, acc ->
            {{key, :ok}, delete_current_at_revision(acc, key, revision)}
          end)

        {{:ok, results}, state}

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
        mutating? = Enum.any?(operations, fn {key, _ttl} -> Map.has_key?(state.store, key) end)
        revision = if mutating?, do: state.revision + 1, else: state.revision

        {results, state} =
          Enum.map_reduce(operations, state, fn {key, ttl}, acc ->
            case fetch_legacy(acc, key) do
              {:ok, value, _} ->
                state = touch_current_at_revision(acc, key, value, now + ttl, revision)
                {{key, :ok}, state}

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
    create_index(state, name, extractor, &Extractor.valid?/1)
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
        state.store
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce(state, fn {key, stored}, acc ->
          {value, _expires_at} = extract_value(stored)
          update_one_index(acc, name, key, Compression.decompress(value))
        end)

      bucket =
        state.index_entries
        |> Map.fetch!(name)
        |> Map.new(fn {value, keys} -> {value, Enum.sort(keys)} end)

      state = %{state | index_entries: Map.put(state.index_entries, name, bucket)}

      {:ok, state}
    else
      {{:error, :not_found}, state}
    end
  end

  defp do_apply(_context, {:restore_backup, %{version: 2} = backup}, state) do
    restore_current_backup(state, backup)
  end

  defp do_apply(_context, {:restore_backup, entries}, state) when is_list(entries) do
    restore_current_entries(state, entries)
  end

  defp do_apply(_context, :reconcile_legacy_state, state) do
    reconcile_legacy_state(state)
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
        case apply_txn(context, spec, state) do
          {{:ok, %Result{} = result} = response, state} ->
            state = cache_txn_request(state, key, request_hash, result, context)
            {response, state}

          {error, state} ->
            {error, state}
        end

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

  defp do_apply(_context, _command, state), do: {{:error, :unsupported_command}, state}

  defp do_apply_current_put(context, key, value, opts, state) do
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
      |> detach_from_all_leases(key)
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

  defp create_index(state, name, extractor, validator) do
    cond do
      not valid_index_name?(name) ->
        {{:error, :invalid_name}, state}

      not validator.(extractor) ->
        {{:error, :invalid_extractor}, state}

      Map.has_key?(state.indexes, name) ->
        {{:error, :index_exists}, state}

      true ->
        state = %{
          state
          | indexes: Map.put(state.indexes, name, extractor),
            index_entries: Map.put(state.index_entries, name, %{})
        }

        {:ok, state}
    end
  end

  defp restore_current_backup(state, backup) do
    restore_current_state(
      state,
      entries_to_map(Map.fetch!(backup, :kv_data)),
      Map.fetch!(backup, :indexes)
    )
  end

  defp restore_current_entries(state, entries) do
    restore_current_state(state, entries_to_map(entries), state.indexes)
  end

  defp restore_current_state(state, store, indexes) do
    revision = state.revision + 1

    current =
      Map.new(store, fn {key, stored} ->
        {value, expires_at} = extract_value(stored)
        {key, Record.next(value, revision, nil, expires_at)}
      end)

    state = %{
      state
      | store: store,
        current: current,
        history: %{},
        leases: %{},
        indexes: indexes,
        index_entries: %{},
        requests: %{},
        revision: revision,
        compact_revision: revision - 1,
        next_lease_id: 1
    }

    {:ok, rebuild_indexes_deterministic(state)}
  end

  defp ensure_current_representation({:drop_index, name}, state) do
    if name in legacy_indexes(state),
      do: :ok,
      else: ensure_current_representation(:ordinary_command, state)
  end

  defp ensure_current_representation(:reconcile_legacy_state, state) do
    case legacy_indexes(state) do
      [] -> :ok
      indexes -> {:error, {:legacy_indexes_require_migration, indexes}}
    end
  end

  defp ensure_current_representation(_command, state) do
    case legacy_indexes(state) do
      [] ->
        status = representation_conflict_status(state)

        if state.representation == :current and status.count == 0 do
          :ok
        else
          {:error, {:legacy_state_requires_reconciliation, status}}
        end

      indexes ->
        {:error, {:legacy_indexes_require_migration, indexes}}
    end
  end

  defp reconcile_legacy_state(state) do
    %{count: count} = representation_conflict_status(state)
    revision = if count == 0, do: state.revision, else: state.revision + 1

    state =
      state.store
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(state, fn {key, stored}, acc ->
        {value, expires_at} = extract_value(stored)
        previous = Map.get(acc.current, key)

        record =
          cond do
            not current_projection_matches?(previous, value, expires_at) ->
              Record.next(value, revision, previous, expires_at)

            valid_record_lease?(previous, state.leases) ->
              previous

            true ->
              %{previous | lease_id: nil, mod_revision: revision}
          end

        if record == previous do
          acc
        else
          acc
          |> save_previous_before_revision(key, previous, revision)
          |> put_record(key, record)
        end
      end)

    state =
      state.current
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(state, fn {key, previous}, acc ->
        if Map.has_key?(state.store, key) do
          acc
        else
          acc
          |> save_previous_before_revision(key, previous, revision)
          |> put_history(key, revision, Record.tombstone(key, revision, previous))
          |> delete_key(key)
        end
      end)

    state =
      state
      |> Map.put(:revision, revision)
      |> Map.put(:representation, :current)
      |> rebuild_lease_memberships()
      |> rebuild_indexes_deterministic()

    {{:ok, %{reconciled: count, revision: revision}}, state}
  end

  defp representation_conflict_status(state) do
    keys =
      state.leases
      |> Enum.flat_map(fn {_id, lease} -> lease.keys end)
      |> Kernel.++(Map.keys(state.store))
      |> Kernel.++(Map.keys(state.current))
      |> MapSet.new()

    {count, sample} =
      Enum.reduce(keys, {0, []}, fn key, acc ->
        if representation_key_consistent?(state, key),
          do: acc,
          else: add_representation_conflict(acc, key)
      end)

    %{
      count: count,
      sample: Enum.sort(sample),
      representation: state.representation,
      required: state.representation != :current or count > 0
    }
  end

  defp current_projection_matches?(%Record{} = record, value, expires_at) do
    record.value === value and record.expires_at === expires_at
  end

  defp current_projection_matches?(_record, _value, _expires_at), do: false

  defp representation_key_consistent?(state, key) do
    with {:ok, stored} <- Map.fetch(state.store, key),
         {:ok, %Record{} = record} <- Map.fetch(state.current, key),
         {value, expires_at} = extract_value(stored),
         true <- current_projection_matches?(record, value, expires_at),
         true <- lease_membership_consistent?(state.leases, key, record.lease_id) do
      true
    else
      _other -> false
    end
  end

  defp lease_membership_consistent?(leases, key, expected_lease_id) do
    memberships =
      leases
      |> Enum.flat_map(fn {id, lease} -> if key in lease.keys, do: [id], else: [] end)
      |> Enum.sort()

    case expected_lease_id do
      nil -> memberships == []
      id -> Map.has_key?(leases, id) and memberships == [id]
    end
  end

  defp valid_record_lease?(%Record{lease_id: nil}, _leases), do: true

  defp valid_record_lease?(%Record{lease_id: id}, leases), do: Map.has_key?(leases, id)

  defp add_representation_conflict({count, sample}, key) do
    sample =
      if length(sample) < @representation_conflict_sample_size do
        [key | sample]
      else
        largest = Enum.max(sample)
        if key < largest, do: [key | List.delete(sample, largest)], else: sample
      end

    {count + 1, sample}
  end

  defp normalize_current_command({:put, key, value, %{ttl: :infinity} = opts}) do
    {:put, key, value, %{opts | ttl: nil}}
  end

  defp normalize_current_command({:txn, spec}) do
    spec =
      spec
      |> normalize_txn_branch(:success)
      |> normalize_txn_branch(:failure)

    {:txn, spec}
  end

  defp normalize_current_command(command), do: command

  defp normalize_txn_branch(spec, branch) do
    if Map.has_key?(spec, branch) do
      Map.update!(
        spec,
        branch,
        &Enum.map(&1, fn operation -> normalize_txn_operation(operation) end)
      )
    else
      spec
    end
  end

  defp normalize_txn_operation({:put, key, value, %{ttl: :infinity} = opts}),
    do: {:put, key, value, %{opts | ttl: nil}}

  defp normalize_txn_operation(operation), do: operation

  defp invalid_command_result({:create_index, name, _extractor})
       when not is_binary(name) or byte_size(name) == 0,
       do: {:error, :invalid_name}

  defp invalid_command_result({:create_index, _name, _extractor}),
    do: {:error, :invalid_extractor}

  defp invalid_command_result({:restore_backup, %{version: 2, indexes: indexes}})
       when is_map(indexes) do
    case Enum.find(indexes, fn {name, extractor} ->
           not valid_index_name?(name) or not Extractor.valid?(extractor)
         end) do
      {name, _extractor} -> {:error, {:invalid_index_extractor, name}}
      nil -> {:error, :unsupported_command}
    end
  end

  defp invalid_command_result({:put_many, operations}) when is_list(operations) do
    case validate_put_many(operations) do
      {:error, reason} -> {:error, reason}
      :ok -> {:error, :unsupported_command}
    end
  end

  defp invalid_command_result({:delete_many, keys}) when is_list(keys) do
    cond do
      length(keys) > 500 -> {:error, :batch_too_large}
      not Enum.all?(keys, &(is_binary(&1) and byte_size(&1) > 0)) -> {:error, :invalid_key}
      true -> {:error, :unsupported_command}
    end
  end

  defp invalid_command_result({:touch_many, operations}) when is_list(operations) do
    cond do
      length(operations) > 500 -> {:error, :batch_too_large}
      not Enum.all?(operations, &valid_touch?/1) -> {:error, :invalid_touch_operation}
      true -> {:error, :unsupported_command}
    end
  end

  defp invalid_command_result(_command), do: {:error, :unsupported_command}

  defp legacy_dispatched_command?({:put, _key, _value}), do: true
  defp legacy_dispatched_command?({:put, _key, _value, _opts_or_expiry}), do: true
  defp legacy_dispatched_command?({:delete, _key}), do: true
  defp legacy_dispatched_command?({:delete, _key, opts}) when is_map(opts), do: true
  defp legacy_dispatched_command?({:put_if, _key, _value, _expiry, _expected}), do: true
  defp legacy_dispatched_command?({:delete_if, _key, _expected, _condition}), do: true
  defp legacy_dispatched_command?({:touch, _key, _ttl}), do: true
  defp legacy_dispatched_command?(:cleanup_expired), do: true
  defp legacy_dispatched_command?({:put_many, operations}) when is_list(operations), do: true
  defp legacy_dispatched_command?({:delete_many, keys}) when is_list(keys), do: true
  defp legacy_dispatched_command?({:touch_many, operations}) when is_list(operations), do: true
  defp legacy_dispatched_command?({:drop_index, _name}), do: true
  defp legacy_dispatched_command?({:reindex, _name}), do: true
  defp legacy_dispatched_command?({:get_many, keys}) when is_list(keys), do: true
  defp legacy_dispatched_command?({:txn, spec}) when is_map(spec), do: true
  defp legacy_dispatched_command?({:grant_lease, _ttl, _opts}), do: true
  defp legacy_dispatched_command?({:keep_alive_lease, _id, _opts}), do: true
  defp legacy_dispatched_command?({:revoke_lease, _id, _opts}), do: true
  defp legacy_dispatched_command?({:expire_lease, _id}), do: true
  defp legacy_dispatched_command?(_command), do: false

  defp apply_txn(context, spec, state) do
    now = now_seconds(context)
    success? = Enum.all?(Map.get(spec, :compare, []), &eval_compare(&1, state, now))
    operations = if success?, do: Map.get(spec, :success, []), else: Map.get(spec, :failure, [])

    case validate_txn_leases(operations, state.leases) do
      :ok ->
        mutating? = Enum.any?(operations, &mutating_op?/1)
        revision = if mutating?, do: state.revision + 1, else: state.revision

        {responses, state} =
          Enum.map_reduce(operations, state, fn operation, acc ->
            execute_txn(operation, acc, revision, context)
          end)

        state = if mutating?, do: %{state | revision: revision}, else: state
        result = %Result{succeeded: success?, revision: revision, responses: responses}
        {{:ok, result}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp validate_txn_leases(operations, leases) do
    case Enum.find_value(operations, fn
           {:put, _key, _value, %{lease: id}} when not is_nil(id) ->
             if Map.has_key?(leases, id), do: nil, else: id

           _operation ->
             nil
         end) do
      nil -> :ok
      _missing_id -> {:error, :lease_not_found}
    end
  end

  defp apply_txn_legacy(context, spec, state) do
    now = now_seconds(context)
    success? = Enum.all?(Map.get(spec, :compare, []), &eval_compare(&1, state, now))
    operations = if success?, do: Map.get(spec, :success, []), else: Map.get(spec, :failure, [])
    mutating? = Enum.any?(operations, &mutating_op?/1)
    revision = if mutating?, do: state.revision + 1, else: state.revision

    {responses, state} =
      Enum.map_reduce(operations, state, fn operation, acc ->
        execute_txn_legacy(operation, acc, revision, context)
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
    legacy_indexes = legacy_indexes(state)

    %{
      count: conflict_count,
      sample: conflict_sample,
      representation: representation,
      required: reconciliation_required
    } = representation_conflict_status(state)

    {:ok,
     %{
       size: map_size(state.store),
       memory: byte_size(:erlang.term_to_binary(state.store)),
       legacy_indexes: legacy_indexes,
       legacy_state_conflict_count: conflict_count,
       legacy_state_conflicts: conflict_sample,
       legacy_state_representation: representation,
       legacy_state_reconciliation_required: reconciliation_required
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
      {:ok, Enum.sort(get_in(state.index_entries, [name, value]) || [])}
    else
      {:ok, {:error, :not_found}}
    end
  end

  defp do_query(:list_indexes, state, _now), do: {:ok, state.indexes |> Map.keys() |> Enum.sort()}

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
    revision = Map.get(opts, :revision)

    if revision != nil and revision <= state.compact_revision do
      {:error, {:compacted, state.compact_revision}}
    else
      entries =
        state
        |> records_at_revision(revision)
        |> Enum.filter(fn {key, record} ->
          selector_match?(selector, key) and not Record.tombstone?(record) and
            not Record.expired?(record, now)
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

  @spec snapshot(State.t()) :: {:ok, map()} | {:error, term()}
  def snapshot(%State{} = state) do
    with :ok <- validate_snapshot_state(state) do
      {:ok, %{__concord_snapshot_version__: @snapshot_version, state: state}}
    end
  end

  @spec restore(term()) :: {:ok, State.t()} | {:error, term()}
  def restore(%{__concord_snapshot_version__: @snapshot_version, state: %State{} = state}) do
    state = normalize_restored_state(state)
    with :ok <- validate_snapshot_state(state), do: {:ok, state}
  end

  def restore(%{__concord_snapshot_version__: @snapshot_version}),
    do: {:error, :invalid_snapshot}

  def restore(%{__concord_snapshot_version__: version}),
    do: {:error, {:unsupported_snapshot_version, version}}

  def restore({:concord_kv, data}) when is_map(data) do
    restore_legacy_state(data)
  end

  def restore(entries) when is_list(entries) do
    with {:ok, store} <- entries_to_map_checked(entries),
         state = %{init() | store: store, representation: :legacy},
         :ok <- validate_legacy_v4_state(state) do
      {:ok, state}
    else
      {:error, {:invalid_snapshot, _reason}} = error -> error
      {:error, reason} -> {:error, {:invalid_snapshot, reason}}
    end
  end

  def restore(%State{} = state) do
    state = normalize_restored_state(state)
    with :ok <- validate_snapshot_state(state), do: {:ok, state}
  end

  def restore(data) when is_map(data) do
    if complete_plain_state_map?(data) do
      representation = Map.get(data, :representation, :legacy)
      state = struct(State, Map.put(data, :representation, representation))
      with :ok <- validate_snapshot_state(state), do: {:ok, state}
    else
      {:error, :invalid_snapshot}
    end
  rescue
    _error -> {:error, :invalid_snapshot}
  end

  def restore(_snapshot), do: {:error, :invalid_snapshot}

  defp validate_v4_state(state) do
    case SnapshotValidator.validate_v4(state) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_snapshot, reason}}
    end
  end

  defp validate_snapshot_state(%State{representation: :current} = state),
    do: validate_v4_state(state)

  defp validate_snapshot_state(%State{representation: :legacy} = state),
    do: validate_legacy_v4_state(state)

  defp validate_snapshot_state(_state),
    do: {:error, {:invalid_snapshot, :invalid_state_representation}}

  defp normalize_restored_state(state) do
    state
    |> Map.from_struct()
    |> Map.put_new(:representation, :legacy)
    |> then(&struct(State, &1))
  end

  defp validate_legacy_v4_state(state) do
    case SnapshotValidator.validate_legacy_v4(state) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_snapshot, reason}}
    end
  end

  defp restore_legacy_state(data) do
    with :ok <- validate_legacy_snapshot_identity(data),
         {:ok, store} <-
           entries_to_map_checked(Map.get(data, :__kv_data__, Map.get(data, :store, %{}))),
         {:ok, current} <-
           entries_to_map_checked(Map.get(data, :__current_data__, Map.get(data, :current, %{}))),
         {:ok, history} <-
           entries_to_map_checked(Map.get(data, :__history_data__, Map.get(data, :history, %{}))),
         {:ok, leases} <-
           entries_to_map_checked(Map.get(data, :__lease_data__, Map.get(data, :leases, %{}))),
         {:ok, index_entries} <-
           normalize_index_entries_checked(
             Map.get(data, :__index_ets__, Map.get(data, :index_entries, %{}))
           ),
         {:ok, indexes} <- ensure_map(Map.get(data, :indexes, %{}), :invalid_indexes),
         {:ok, requests} <-
           entries_to_map_checked(Map.get(data, :requests, %{})),
         state <-
           data
           |> normalize_state_map()
           |> Map.merge(%{
             store: store,
             current: current,
             history: history,
             leases: normalize_legacy_leases(leases, Map.get(data, :revision, 0)),
             indexes: indexes,
             index_entries: index_entries,
             requests: requests,
             representation: Map.get(data, :representation, :legacy)
           })
           |> then(&struct(State, &1)),
         :ok <- validate_legacy_v4_state(state) do
      {:ok, state}
    else
      {:error, {:invalid_snapshot, _reason}} = error -> error
      {:error, reason} -> {:error, {:invalid_snapshot, reason}}
    end
  rescue
    _error -> {:error, :invalid_snapshot}
  catch
    _kind, _reason -> {:error, :invalid_snapshot}
  end

  defp validate_legacy_snapshot_identity(%{__snapshot_version__: 3}), do: :ok

  defp validate_legacy_snapshot_identity(%{__snapshot_version__: _version}),
    do: {:error, :unsupported_legacy_snapshot_version}

  defp validate_legacy_snapshot_identity(data) do
    recognizable_keys = [
      :store,
      :current,
      :history,
      :leases,
      :indexes,
      :index_entries,
      :requests,
      :command_count,
      :revision,
      :compact_revision,
      :next_lease_id,
      :__kv_data__,
      :__current_data__,
      :__history_data__,
      :__lease_data__,
      :__index_ets__
    ]

    if Enum.any?(recognizable_keys, &Map.has_key?(data, &1)) do
      :ok
    else
      {:error, :unrecognized_legacy_snapshot}
    end
  end

  defp complete_plain_state_map?(data) do
    fields = Map.keys(Map.from_struct(%State{}))
    keys = Map.keys(data)
    legacy_fields = List.delete(fields, :representation)

    (length(keys) == length(fields) and Enum.all?(fields, &Map.has_key?(data, &1))) or
      (length(keys) == length(legacy_fields) and
         Enum.all?(legacy_fields, &Map.has_key?(data, &1)))
  end

  defp normalize_legacy_leases(leases, revision) do
    granted_at = if is_integer(revision) and revision > 0, do: 1, else: 0

    Map.new(leases, fn
      {id, lease} when is_map(lease) -> {id, Map.put_new(lease, :granted_at, granted_at)}
      entry -> entry
    end)
  end

  defp ensure_map(value, _reason) when is_map(value), do: {:ok, value}
  defp ensure_map(_value, reason), do: {:error, reason}

  defp entries_to_map_checked(entries) when is_map(entries), do: {:ok, entries}

  defp entries_to_map_checked(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      {key, value}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, key, value)}}
      _entry, _acc -> {:halt, {:error, :invalid_entries}}
    end)
  end

  defp entries_to_map_checked(_entries), do: {:error, :invalid_entries}

  defp normalize_index_entries_checked(entries) do
    with {:ok, entries} <- entries_to_map_checked(entries) do
      Enum.reduce_while(entries, {:ok, %{}}, fn {name, bucket}, {:ok, acc} ->
        case entries_to_map_checked(bucket) do
          {:ok, bucket} -> {:cont, {:ok, Map.put(acc, name, bucket)}}
          {:error, _reason} -> {:halt, {:error, :invalid_index_entries}}
        end
      end)
    end
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
          normalize_index_entries(Map.get(tables, :index_entries, state.index_entries)),
        representation: :legacy
    }

    state
  end

  defp normalize_state_map(data) do
    defaults = Map.from_struct(%State{})

    data
    |> Map.take(Map.keys(defaults))
    |> then(&Map.merge(defaults, &1))
  end

  defp normalize_index_entries(index_entries) when is_map(index_entries) do
    Enum.reduce_while(index_entries, %{}, fn
      {name, entries}, acc when is_map(entries) ->
        {:cont, Map.put(acc, name, entries)}

      {name, entries}, acc when is_list(entries) ->
        try do
          {:cont, Map.put(acc, name, Map.new(entries))}
        rescue
          _error -> {:halt, :invalid_index_entries}
        end

      _entry, _acc ->
        {:halt, :invalid_index_entries}
    end)
  end

  defp normalize_index_entries(index_entries) when is_list(index_entries) do
    index_entries |> Map.new() |> normalize_index_entries()
  rescue
    _error -> :invalid_index_entries
  end

  defp normalize_index_entries(_index_entries), do: :invalid_index_entries

  defp valid_index_name?(name) do
    is_binary(name) and byte_size(name) > 0 and byte_size(name) <= 255 and String.valid?(name)
  end

  defp legacy_indexes(state) do
    state.indexes
    |> Enum.reject(fn {name, extractor} ->
      valid_index_name?(name) and Extractor.valid?(extractor)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
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

  defp put_current_at_revision(state, key, value, expires_at, revision) do
    previous = Map.get(state.current, key)
    old_value = legacy_value(state, key)
    record = Record.next(value, revision, previous, expires_at)

    state
    |> save_previous_before_revision(key, previous, revision)
    |> detach_from_all_leases(key)
    |> put_record(key, record)
    |> update_indexes(key, old_value, Compression.decompress(value))
    |> Map.put(:revision, revision)
  end

  defp touch_current_at_revision(state, key, value, expires_at, revision) do
    previous = Map.get(state.current, key)

    record =
      case previous do
        %Record{} -> %{previous | expires_at: expires_at, mod_revision: revision}
        nil -> Record.next(value, revision, nil, expires_at)
      end

    state
    |> save_previous_before_revision(key, previous, revision)
    |> put_record(key, record)
    |> Map.put(:revision, revision)
  end

  defp delete_current_at_revision(state, key, revision) do
    case fetch_legacy(state, key) do
      {:ok, value, _expires_at} ->
        previous = Map.get(state.current, key)

        state
        |> save_previous_before_revision(key, previous, revision)
        |> put_history(key, revision, Record.tombstone(key, revision, previous))
        |> detach_from_all_leases(key)
        |> delete_key(key)
        |> update_indexes(key, Compression.decompress(value), nil)
        |> Map.put(:revision, revision)

      {:error, :not_found} ->
        state
    end
  end

  defp save_previous_before_revision(state, _key, nil, _revision), do: state

  defp save_previous_before_revision(state, key, %Record{} = record, revision) do
    if record.mod_revision < revision, do: save_previous(state, key, record), else: state
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

  defp delete_history(state, key, revision) do
    %{state | history: Map.delete(state.history, {key, revision})}
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

  defp detach_from_all_leases(state, key) do
    leases =
      Map.new(state.leases, fn {id, lease} ->
        {id, %{lease | keys: List.delete(lease.keys, key)}}
      end)

    %{state | leases: leases}
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

  defp rebuild_indexes_deterministic(state) do
    entries = Map.new(state.indexes, fn {name, _extractor} -> {name, %{}} end)
    state = %{state | index_entries: entries}

    state =
      state.store
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(state, fn {key, stored}, acc ->
        {value, _expires_at} = extract_value(stored)
        update_indexes(acc, key, nil, Compression.decompress(value))
      end)

    index_entries =
      Map.new(state.index_entries, fn {name, bucket} ->
        {name, Map.new(bucket, fn {value, keys} -> {value, Enum.sort(keys)} end)}
      end)

    %{state | index_entries: index_entries}
  end

  defp rebuild_lease_memberships(state) do
    leases = Map.new(state.leases, fn {id, lease} -> {id, %{lease | keys: []}} end)

    leases =
      state.current
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(leases, fn
        {_key, %Record{lease_id: nil}}, acc ->
          acc

        {key, %Record{lease_id: id}}, acc ->
          Map.update!(acc, id, fn lease -> %{lease | keys: [key | lease.keys]} end)
      end)

    leases = Map.new(leases, fn {id, lease} -> {id, %{lease | keys: Enum.sort(lease.keys)}} end)
    %{state | leases: leases}
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

  defp records_at_revision(state, nil), do: state.current

  defp records_at_revision(state, target_revision) do
    (Map.to_list(state.current) ++
       Enum.map(state.history, fn {{key, _revision}, record} -> {key, record} end))
    |> Enum.filter(fn {_key, record} -> record.mod_revision <= target_revision end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {key, records} -> {key, Enum.max_by(records, & &1.mod_revision)} end)
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

  defp extract_field(value, path) when is_list(path) do
    get_in(value, path)
  rescue
    _error -> nil
  end

  defp compare(:==, left, right), do: left == right
  defp compare(:!=, left, right), do: left != right
  defp compare(:>, left, right) when is_number(left) and is_number(right), do: left > right
  defp compare(:>=, left, right) when is_number(left) and is_number(right), do: left >= right
  defp compare(:<, left, right) when is_number(left) and is_number(right), do: left < right
  defp compare(:<=, left, right) when is_number(left) and is_number(right), do: left <= right
  defp compare(_operation, _left, _right), do: false

  defp execute_txn_legacy({:get, selector, opts}, state, _revision, context) do
    execute_txn_get(selector, opts, state, context, :legacy)
  end

  defp execute_txn_legacy({:put, key, value, opts}, state, revision, context) do
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

  defp execute_txn_legacy({:delete, selector, opts}, state, revision, _context) do
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

          _other ->
            {records, acc}
        end
      end)

    previous_records =
      if Map.get(opts, :prev_kv, false), do: Enum.reverse(previous_records), else: []

    response = {:delete, selector, %{deleted: length(keys), prev_kvs: previous_records}}
    {response, state}
  end

  defp execute_txn_legacy({:touch, key, ttl, _opts}, state, revision, context) do
    execute_txn_touch_legacy(key, ttl, state, revision, context)
  end

  defp execute_txn_legacy(_operation, state, _revision, _context) do
    {{:error, :unsupported_op}, state}
  end

  defp execute_txn({:get, selector, opts}, state, _revision, context) do
    execute_txn_get(selector, opts, state, context, :current)
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
      |> save_previous_before_revision(key, previous, revision)
      |> delete_history(key, revision)
      |> detach_from_all_leases(key)
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
      |> Enum.sort()

    {previous_records, state} =
      Enum.reduce(keys, {[], state}, fn key, {records, acc} ->
        case Map.get(acc.current, key) do
          %Record{version: version} = previous when version > 0 ->
            old_value = Compression.decompress(previous.value)

            acc =
              acc
              |> save_previous_before_revision(key, previous, revision)
              |> put_history(key, revision, Record.tombstone(key, revision, previous))
              |> detach_from_all_leases(key)
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
    execute_txn_touch(key, ttl, state, revision, context)
  end

  defp execute_txn(_operation, state, _revision, _context) do
    {{:error, :unsupported_op}, state}
  end

  defp execute_txn_get({:key, key} = selector, _opts, state, context, _representation) do
    now = now_seconds(context)

    records =
      case Map.get(state.current, key) do
        %Record{} = record ->
          if Record.expired?(record, now) or record.version == 0, do: [], else: [record]

        _other ->
          []
      end

    {{:get, selector, %{kvs: records, count: length(records)}}, state}
  end

  defp execute_txn_get(selector, opts, state, context, representation) do
    now = now_seconds(context)
    limit = Map.get(opts, :limit, 1000)

    records =
      state.current
      |> Enum.filter(fn {key, record} ->
        selector_match?(selector, key) and not Record.expired?(record, now) and record.version > 0
      end)
      |> sort_txn_get_entries(representation)
      |> Enum.map(&elem(&1, 1))
      |> Enum.take(limit)

    {{:get, selector, %{kvs: records, count: length(records)}}, state}
  end

  defp sort_txn_get_entries(entries, :legacy) do
    Enum.sort_by(entries, fn {_key, record} -> record.mod_revision end)
  end

  defp sort_txn_get_entries(entries, :current) do
    Enum.sort_by(entries, fn {key, record} -> {record.mod_revision, key} end)
  end

  defp execute_txn_touch(key, ttl, state, revision, context) do
    now = now_seconds(context)

    case Map.get(state.current, key) do
      %Record{} = record ->
        if Record.expired?(record, now) or record.version == 0 do
          {{:touch, key, %{ttl: :not_found}}, state}
        else
          next_record = %{record | expires_at: now + ttl, mod_revision: revision}

          state =
            state
            |> save_previous_before_revision(key, record, revision)
            |> put_record(key, next_record)

          {{:touch, key, %{ttl: ttl}}, state}
        end

      _other ->
        {{:touch, key, %{ttl: :not_found}}, state}
    end
  end

  defp execute_txn_touch_legacy(key, ttl, state, revision, context) do
    now = now_seconds(context)

    case Map.get(state.current, key) do
      %Record{} = record ->
        if Record.expired?(record, now) or record.version == 0 do
          {{:touch, key, %{ttl: :not_found}}, state}
        else
          record = %{record | expires_at: now + ttl, mod_revision: revision}
          {{:touch, key, %{ttl: ttl}}, put_record(state, key, record)}
        end

      _other ->
        {{:touch, key, %{ttl: :not_found}}, state}
    end
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
