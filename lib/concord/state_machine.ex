defmodule Concord.StateMachine do
  @moduledoc """
  The Raft state machine for Concord (Version 3).

  Implements the `:ra_machine` behavior to provide a replicated key-value store
  with TTL support and secondary indexes.

  ## Correctness Guarantees

  All state mutations go through `apply/3` which is a **pure function** of
  (meta, command, state) → (new_state, result, effects). Time is derived from
  `meta.system_time` (leader-assigned, replicated in the log), ensuring
  deterministic replay across all nodes.

  ## State Shape

      {:concord_kv, %{
        indexes: %{name => extractor_spec},
        command_count: non_neg_integer()
      }}

  ETS tables are **materialized views** rebuilt from the authoritative state
  on snapshot install. They are never the source of truth.
  """

  @behaviour :ra_machine

  alias Concord.Compression
  alias Concord.Index
  alias Concord.Index.Extractor
  alias Concord.KV.Record
  alias Concord.StorageScope

  # Emit release_cursor every N commands to allow log compaction
  @snapshot_interval 1000

  # ──────────────────────────────────────────────
  # Deterministic Time Helpers
  # ──────────────────────────────────────────────

  # Extract deterministic timestamp in seconds from Ra metadata.
  # Ra's system_time is milliseconds set by the leader at proposal time.
  defp meta_time(meta) do
    ms = Map.get(meta, :system_time, 0)
    div(ms, 1000)
  end

  # ──────────────────────────────────────────────
  # Value Format Helpers
  # ──────────────────────────────────────────────

  # v2: create a Record struct from stored data
  defp format_value(value, expires_at) do
    %{value: value, expires_at: expires_at}
  end

  defp extract_value(%Record{} = rec), do: {rec.value, rec.expires_at}
  defp extract_value(%{value: value, expires_at: expires_at}), do: {value, expires_at}
  defp extract_value({value, expires_at}) when is_integer(expires_at), do: {value, expires_at}
  defp extract_value(value), do: {value, nil}

  defp expired?(nil, _now), do: false
  defp expired?(expires_at, now), do: now > expires_at

  defp store_table, do: StorageScope.table(:store)
  defp current_table, do: StorageScope.table(:current)
  defp history_table, do: StorageScope.table(:history)
  defp leases_table, do: StorageScope.table(:leases)

  # ──────────────────────────────────────────────
  # Default State Fields
  # ──────────────────────────────────────────────

  defp default_state_fields do
    %{
      indexes: %{},
      command_count: 0,
      revision: 0,
      compact_revision: 0,
      next_lease_id: 1
    }
  end

  defp ensure_state_fields(data) when is_map(data) do
    Map.merge(default_state_fields(), data)
  end

  # ──────────────────────────────────────────────
  # init/1 — Create ETS tables, return initial state
  # ──────────────────────────────────────────────

  @impl :ra_machine
  def init(_config) do
    ensure_ets_table(store_table(), [:ordered_set, :named_table])
    ensure_ets_table(current_table(), [:ordered_set, :named_table])
    ensure_ets_table(history_table(), [:ordered_set, :named_table])
    ensure_ets_table(leases_table(), [:set, :named_table])

    {:concord_kv, default_state_fields()}
  end

  defp ets_access_mode do
    Application.get_env(:concord, :ets_access_mode, :protected)
  end

  defp ensure_ets_table(name, opts \\ [:set, :named_table]) do
    opts = [ets_access_mode() | opts]

    case :ets.whereis(name) do
      :undefined -> :ets.new(name, opts)
      _table -> :ok
    end
  end

  # ──────────────────────────────────────────────
  # apply/3 — Ra callback wrapper
  # Normalizes state, delegates to apply_command,
  # increments command_count, emits release_cursor.
  # ──────────────────────────────────────────────

  @impl :ra_machine
  def apply(meta, command, state) do
    normalized = normalize_state(state)

    {new_state, result, effects} = apply_command(meta, command, normalized)

    # Track command count for log compaction
    {:concord_kv, data} = new_state
    count = Map.get(data, :command_count, 0) + 1
    final_data = Map.put(data, :command_count, count)
    final_state = {:concord_kv, final_data}

    final_effects =
      if rem(count, @snapshot_interval) == 0 do
        # Build comprehensive snapshot state including ETS data for log compaction.
        # Ra uses this state as the snapshot — after restore, snapshot_installed/4
        # rebuilds ETS tables from the embedded data.
        snapshot_state = build_release_cursor_state(final_state)
        [{:release_cursor, Map.get(meta, :index), snapshot_state} | effects]
      else
        effects
      end

    {final_state, result, final_effects}
  end

  # Normalize state from various formats (snapshot migration, legacy)
  defp normalize_state({:concord_kv, data}) when is_map(data) do
    clean =
      data
      |> Map.delete(:__snapshot_version__)
      |> Map.delete(:__kv_data__)
      |> Map.delete(:__current_data__)
      |> Map.delete(:__history_data__)
      |> Map.delete(:__lease_data__)
      |> Map.delete(:__index_ets__)

    {:concord_kv, ensure_state_fields(clean)}
  end

  # V1/V2 legacy: bare list from old snapshot
  defp normalize_state(data) when is_list(data) do
    {:concord_kv, default_state_fields()}
  end

  defp normalize_state(_other) do
    {:concord_kv, default_state_fields()}
  end

  # ══════════════════════════════════════════════
  # KV COMMANDS
  # ══════════════════════════════════════════════

  def apply_command(meta, {:put, key, value}, {:concord_kv, data}) do
    apply_command(meta, {:put, key, value, nil}, {:concord_kv, data})
  end

  # v2 put with map opts: {:put, key, value, %{ttl: _, content_type: _, ...}}
  def apply_command(meta, {:put, key, value, %{} = opts}, {:concord_kv, data}) do
    ttl = Map.get(opts, :ttl)
    expires_at = if ttl, do: meta_time(meta) + ttl, else: nil
    content_type = Map.get(opts, :content_type)
    kv_metadata = Map.get(opts, :metadata, %{})
    lease_id = Map.get(opts, :lease)
    return_prev = Map.get(opts, :prev_kv, false)

    start_time = System.monotonic_time()
    commit_rev = Map.get(data, :revision, 0) + 1

    # Look up current record
    prev_record = get_current_record(key)
    old_value = if prev_record, do: Compression.decompress(prev_record.value), else: nil

    # Copy previous to history if exists
    if prev_record do
      :ets.insert(history_table(), {{key, prev_record.mod_revision}, prev_record})
    end

    # Build new record
    new_record = %Record{
      value: value,
      create_revision:
        if(prev_record && prev_record.version > 0,
          do: prev_record.create_revision,
          else: commit_rev
        ),
      mod_revision: commit_rev,
      version: if(prev_record && prev_record.version > 0, do: prev_record.version + 1, else: 1),
      expires_at: expires_at,
      lease_id: lease_id,
      content_type: content_type,
      metadata: kv_metadata
    }

    :ets.insert(current_table(), {key, new_record})

    # Legacy table compat
    :ets.insert(store_table(), {key, format_value(value, expires_at)})

    update_indexes_on_put(data, key, old_value, Compression.decompress(value))

    # Track key in lease if attached
    if lease_id do
      ensure_ets_table(leases_table(), [:set, :named_table])

      case :ets.lookup(leases_table(), lease_id) do
        [{^lease_id, lease}] ->
          unless key in lease.keys do
            :ets.insert(leases_table(), {lease_id, %{lease | keys: [key | lease.keys]}})
          end

        _ ->
          :ok
      end
    end

    new_data = Map.put(data, :revision, commit_rev)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :put, key: key, index: Map.get(meta, :index), has_ttl: expires_at != nil}
    )

    result = %{revision: commit_rev, prev_kv: if(return_prev, do: prev_record, else: nil)}
    {{:concord_kv, new_data}, result, []}
  end

  # Legacy put with bare expires_at
  def apply_command(meta, {:put, key, value, expires_at}, {:concord_kv, data}) do
    start_time = System.monotonic_time()
    commit_rev = Map.get(data, :revision, 0) + 1

    old_value = get_decompressed_value(key)
    prev_record = get_current_record(key)

    # Copy previous to history if exists
    if prev_record do
      :ets.insert(history_table(), {{key, prev_record.mod_revision}, prev_record})
    end

    # Build new record
    new_record = %Record{
      value: value,
      create_revision:
        if(prev_record && prev_record.version > 0,
          do: prev_record.create_revision,
          else: commit_rev
        ),
      mod_revision: commit_rev,
      version: if(prev_record && prev_record.version > 0, do: prev_record.version + 1, else: 1),
      expires_at: expires_at,
      lease_id: nil,
      content_type: nil,
      metadata: %{}
    }

    :ets.insert(current_table(), {key, new_record})

    formatted_value = format_value(value, expires_at)
    :ets.insert(store_table(), {key, formatted_value})

    update_indexes_on_put(data, key, old_value, Compression.decompress(value))
    new_data = Map.put(data, :revision, commit_rev)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :put, key: key, index: Map.get(meta, :index), has_ttl: expires_at != nil}
    )

    {{:concord_kv, new_data}, :ok, []}
  end

  # v2 delete with map opts: {:delete, key, %{prev_kv: bool}}
  def apply_command(meta, {:delete, key, %{} = opts}, {:concord_kv, data}) do
    start_time = System.monotonic_time()
    return_prev = Map.get(opts, :prev_kv, false)

    prev_record = get_current_record(key)
    old_value = get_decompressed_value(key)

    # Only advance revision if key actually exists
    if old_value != nil do
      commit_rev = Map.get(data, :revision, 0) + 1

      # Copy current to history
      if prev_record do
        :ets.insert(history_table(), {{key, prev_record.mod_revision}, prev_record})
      end

      # Create tombstone in history
      tombstone = Record.tombstone(key, commit_rev, prev_record)
      :ets.insert(history_table(), {{key, commit_rev}, tombstone})

      # Remove from current
      :ets.delete(current_table(), key)
      :ets.delete(store_table(), key)

      if old_value != nil do
        remove_from_all_indexes(data, key, old_value)
      end

      new_data = Map.put(data, :revision, commit_rev)

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:concord, :operation, :apply],
        %{duration: duration},
        %{operation: :delete, key: key, index: Map.get(meta, :index)}
      )

      result = %{revision: commit_rev, prev_kv: if(return_prev, do: prev_record, else: nil)}
      {{:concord_kv, new_data}, result, []}
    else
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:concord, :operation, :apply],
        %{duration: duration},
        %{operation: :delete, key: key, index: Map.get(meta, :index)}
      )

      result = %{revision: Map.get(data, :revision, 0), prev_kv: nil}
      {{:concord_kv, data}, result, []}
    end
  end

  # Legacy delete (bare key, no opts)
  def apply_command(meta, {:delete, key}, {:concord_kv, data}) do
    start_time = System.monotonic_time()

    prev_record = get_current_record(key)
    old_value = get_decompressed_value(key)
    has_key = old_value != nil

    new_data =
      if has_key do
        commit_rev = Map.get(data, :revision, 0) + 1

        if prev_record do
          :ets.insert(history_table(), {{key, prev_record.mod_revision}, prev_record})
        end

        tombstone = Record.tombstone(key, commit_rev, prev_record)
        :ets.insert(history_table(), {{key, commit_rev}, tombstone})

        :ets.delete(current_table(), key)
        :ets.delete(store_table(), key)

        if old_value != nil do
          remove_from_all_indexes(data, key, old_value)
        end

        Map.put(data, :revision, commit_rev)
      else
        :ets.delete(store_table(), key)
        data
      end

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :delete, key: key, index: Map.get(meta, :index)}
    )

    {{:concord_kv, new_data}, :ok, []}
  end

  # put_if — Compare-and-swap (no anonymous functions in command)
  def apply_command(meta, {:put_if, key, value, expires_at, expected}, {:concord_kv, data}) do
    start_time = System.monotonic_time()
    now = meta_time(meta)

    result =
      case :ets.lookup(store_table(), key) do
        [{^key, stored_data}] ->
          case extract_value(stored_data) do
            {current_value, current_expires_at} ->
              if expired?(current_expires_at, now) do
                {:error, :not_found}
              else
                old_decompressed = Compression.decompress(current_value)

                if old_decompressed == expected do
                  formatted_value = format_value(value, expires_at)
                  :ets.insert(store_table(), {key, formatted_value})

                  update_indexes_on_put(
                    data,
                    key,
                    old_decompressed,
                    Compression.decompress(value)
                  )

                  :ok
                else
                  {:error, :condition_failed}
                end
              end

            _ ->
              {:error, :invalid_stored_format}
          end

        [] ->
          {:error, :not_found}
      end

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :put_if, key: key, index: Map.get(meta, :index), result: result}
    )

    {{:concord_kv, data}, result, []}
  end

  def apply_command(meta, {:delete_if, key, expected, _condition_fn}, {:concord_kv, data}) do
    start_time = System.monotonic_time()
    now = meta_time(meta)

    result =
      check_conditional_operation(key, expected, now, fn ->
        old_value = get_decompressed_value(key)
        :ets.delete(store_table(), key)

        if old_value != nil do
          remove_from_all_indexes(data, key, old_value)
        end

        :ok
      end)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :delete_if, key: key, index: Map.get(meta, :index), result: result}
    )

    {{:concord_kv, data}, result, []}
  end

  def apply_command(meta, {:touch, key, additional_ttl_seconds}, {:concord_kv, data}) do
    start_time = System.monotonic_time()
    now = meta_time(meta)

    result =
      case :ets.lookup(store_table(), key) do
        [{^key, stored_data}] ->
          case extract_value(stored_data) do
            {value, _current_expires_at} ->
              new_expires_at = now + additional_ttl_seconds
              new_stored_data = format_value(value, new_expires_at)
              :ets.insert(store_table(), {key, new_stored_data})
              :ok

            _ ->
              {:error, :invalid_stored_format}
          end

        [] ->
          {:error, :not_found}
      end

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :touch, key: key, index: Map.get(meta, :index), result: result}
    )

    {{:concord_kv, data}, result, []}
  end

  def apply_command(meta, :cleanup_expired, {:concord_kv, data}) do
    start_time = System.monotonic_time()
    now = meta_time(meta)

    # Single-pass: fetch all entries as {key, stored_data} tuples at once,
    # then filter and delete expired ones — O(N) instead of O(3N).
    all_entries = :ets.tab2list(store_table())

    {deleted_count, scanned_count} =
      Enum.reduce(all_entries, {0, 0}, fn {key, stored_data}, {deleted, scanned} ->
        case extract_value(stored_data) do
          {value, expires_at} when expires_at != nil ->
            if expired?(expires_at, now) do
              decompressed = Compression.decompress(value)

              if decompressed != nil do
                remove_from_all_indexes(data, key, decompressed)
              end

              :ets.delete(store_table(), key)
              {deleted + 1, scanned + 1}
            else
              {deleted, scanned + 1}
            end

          _ ->
            {deleted, scanned + 1}
        end
      end)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{
        operation: :cleanup_expired,
        index: Map.get(meta, :index),
        deleted_count: deleted_count,
        scanned_keys: scanned_count
      }
    )

    {{:concord_kv, data}, {:ok, deleted_count}, []}
  end

  # ──────────────────────────────────────────────
  # Batch KV Commands
  # ──────────────────────────────────────────────

  def apply_command(meta, {:put_many, operations}, {:concord_kv, data})
      when is_list(operations) do
    start_time = System.monotonic_time()

    case validate_put_many_operations(operations) do
      :ok ->
        results = execute_put_many_batch(operations, data)

        case Enum.find(results, fn {_key, result} -> match?({:error, _}, result) end) do
          nil ->
            duration = System.monotonic_time() - start_time

            :telemetry.execute(
              [:concord, :operation, :apply],
              %{duration: duration},
              %{
                operation: :put_many,
                index: Map.get(meta, :index),
                batch_size: length(operations),
                success_count: length(results)
              }
            )

            {{:concord_kv, data}, {:ok, results}, []}

          {_, _} ->
            {{:concord_kv, data}, {:error, :partial_failure}, []}
        end

      {:error, reason} ->
        {{:concord_kv, data}, {:error, reason}, []}
    end
  end

  def apply_command(meta, {:delete_many, keys}, {:concord_kv, data}) when is_list(keys) do
    start_time = System.monotonic_time()

    case validate_delete_many_operations(keys) do
      :ok ->
        results = execute_delete_many_batch(keys, data)

        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:concord, :operation, :apply],
          %{duration: duration},
          %{
            operation: :delete_many,
            index: Map.get(meta, :index),
            batch_size: length(keys),
            deleted_count: Enum.count(results, fn {_, result} -> result == :ok end)
          }
        )

        {{:concord_kv, data}, {:ok, results}, []}

      {:error, reason} ->
        {{:concord_kv, data}, {:error, reason}, []}
    end
  end

  def apply_command(meta, {:touch_many, operations}, {:concord_kv, data})
      when is_list(operations) do
    start_time = System.monotonic_time()
    now = meta_time(meta)

    case validate_touch_many_operations(operations) do
      :ok ->
        results = execute_touch_many_batch(operations, now)

        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:concord, :operation, :apply],
          %{duration: duration},
          %{
            operation: :touch_many,
            index: Map.get(meta, :index),
            batch_size: length(operations),
            success_count: Enum.count(results, fn {_, result} -> result == :ok end)
          }
        )

        {{:concord_kv, data}, {:ok, results}, []}

      {:error, reason} ->
        {{:concord_kv, data}, {:error, reason}, []}
    end
  end

  # ══════════════════════════════════════════════
  # SECONDARY INDEX COMMANDS
  # ══════════════════════════════════════════════

  def apply_command(_meta, {:create_index, name, extractor}, {:concord_kv, data}) do
    indexes = Map.get(data, :indexes, %{})

    if Map.has_key?(indexes, name) do
      {{:concord_kv, data}, {:error, :index_exists}, []}
    else
      table_name = Index.index_table_name(name)
      ensure_ets_table(table_name, [:set, :named_table])

      new_indexes = Map.put(indexes, name, extractor)
      new_data = Map.put(data, :indexes, new_indexes)

      {{:concord_kv, new_data}, :ok, []}
    end
  end

  def apply_command(_meta, {:drop_index, name}, {:concord_kv, data}) do
    indexes = Map.get(data, :indexes, %{})

    if Map.has_key?(indexes, name) do
      table_name = Index.index_table_name(name)

      if :ets.whereis(table_name) != :undefined do
        :ets.delete(table_name)
      end

      new_indexes = Map.delete(indexes, name)
      new_data = Map.put(data, :indexes, new_indexes)

      {{:concord_kv, new_data}, :ok, []}
    else
      {{:concord_kv, data}, {:error, :not_found}, []}
    end
  end

  # ══════════════════════════════════════════════
  # BACKUP RESTORE COMMAND
  # ══════════════════════════════════════════════

  # V2 backup format: map with all state categories
  def apply_command(meta, {:restore_backup, %{version: 2} = backup_state}, {:concord_kv, data}) do
    start_time = System.monotonic_time()

    # Restore KV data
    :ets.delete_all_objects(store_table())

    Enum.each(Map.get(backup_state, :kv_data, []), fn entry ->
      :ets.insert(store_table(), entry)
    end)

    # Restore index definitions into the Raft state map
    new_data =
      data
      |> Map.put(:indexes, Map.get(backup_state, :indexes, %{}))

    # Rebuild index ETS tables from the restored state
    rebuild_all_index_ets(Map.get(new_data, :indexes, %{}))

    duration = System.monotonic_time() - start_time
    kv_count = length(Map.get(backup_state, :kv_data, []))

    :telemetry.execute(
      [:concord, :backup, :restored],
      %{entry_count: kv_count, duration: duration},
      %{index: Map.get(meta, :index)}
    )

    {{:concord_kv, new_data}, :ok, []}
  end

  # V1 backup format: bare list of KV entries (backward compatible)
  def apply_command(meta, {:restore_backup, kv_entries}, {:concord_kv, data})
      when is_list(kv_entries) do
    start_time = System.monotonic_time()

    :ets.delete_all_objects(store_table())

    Enum.each(kv_entries, fn entry ->
      :ets.insert(store_table(), entry)
    end)

    # Rebuild all indexes from the restored data
    indexes = Map.get(data, :indexes, %{})
    rebuild_all_index_ets(indexes)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :backup, :restored],
      %{entry_count: length(kv_entries), duration: duration},
      %{index: Map.get(meta, :index)}
    )

    {{:concord_kv, data}, :ok, []}
  end

  # ──────────────────────────────────────────────
  # Legacy: get_many as command (backward compat)
  # New code should use the query path instead.
  # ──────────────────────────────────────────────

  def apply_command(meta, {:get_many, keys}, {:concord_kv, data}) when is_list(keys) do
    start_time = System.monotonic_time()
    now = meta_time(meta)

    results = batch_get_keys(keys, now)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :get_many, index: Map.get(meta, :index), batch_size: length(keys)}
    )

    {{:concord_kv, data}, {:ok, results}, []}
  end

  # ══════════════════════════════════════════════
  # TRANSACTION COMMAND
  # ══════════════════════════════════════════════

  def apply_command(meta, {:txn, spec}, {:concord_kv, data}) do
    alias Concord.Txn.Result

    compares = Map.get(spec, :compare, [])
    success_ops = Map.get(spec, :success, [])
    failure_ops = Map.get(spec, :failure, [])

    now = meta_time(meta)

    # Step 1: Evaluate all compares against pre-txn state
    compare_ok? = Enum.all?(compares, &eval_compare(&1, now))

    # Step 2: Select branch
    branch = if compare_ok?, do: success_ops, else: failure_ops

    # Step 3: Check if branch has mutating ops
    mutating? = Enum.any?(branch, &mutating_op?/1)

    # Step 4: Allocate revision if mutating
    commit_rev =
      if mutating?,
        do: Map.get(data, :revision, 0) + 1,
        else: Map.get(data, :revision, 0)

    # Step 5: Execute ops in order with read-your-writes
    {responses, new_data} =
      Enum.reduce(branch, {[], data}, fn op, {resps, d} ->
        {resp, d2} = execute_txn_op(op, d, commit_rev, meta)
        {resps ++ [resp], d2}
      end)

    # Step 6: Update revision
    final_data = if mutating?, do: Map.put(new_data, :revision, commit_rev), else: new_data

    result = %Result{
      succeeded: compare_ok?,
      revision: commit_rev,
      responses: responses
    }

    {{:concord_kv, final_data}, {:ok, result}, []}
  end

  # ══════════════════════════════════════════════
  # LEASE COMMANDS
  # ══════════════════════════════════════════════

  def apply_command(meta, {:grant_lease, ttl_seconds, _opts}, {:concord_kv, data}) do
    now = meta_time(meta)
    lease_id = Map.get(data, :next_lease_id, 1)
    commit_rev = Map.get(data, :revision, 0) + 1

    lease = %{
      id: lease_id,
      ttl: ttl_seconds,
      expires_at: now + ttl_seconds,
      granted_at: commit_rev,
      keys: []
    }

    ensure_ets_table(leases_table(), [:set, :named_table])
    :ets.insert(leases_table(), {lease_id, lease})

    new_data =
      data
      |> Map.put(:next_lease_id, lease_id + 1)
      |> Map.put(:revision, commit_rev)

    :telemetry.execute(
      [:concord, :lease, :granted],
      %{ttl: ttl_seconds, lease_id: lease_id},
      %{index: Map.get(meta, :index)}
    )

    {{:concord_kv, new_data}, {:ok, %{lease_id: lease_id, ttl: ttl_seconds}}, []}
  end

  def apply_command(meta, {:keep_alive_lease, lease_id, _opts}, {:concord_kv, data}) do
    now = meta_time(meta)
    ensure_ets_table(leases_table(), [:set, :named_table])

    case :ets.lookup(leases_table(), lease_id) do
      [{^lease_id, lease}] ->
        updated = %{lease | expires_at: now + lease.ttl}
        :ets.insert(leases_table(), {lease_id, updated})

        :telemetry.execute(
          [:concord, :lease, :renewed],
          %{lease_id: lease_id, ttl: lease.ttl},
          %{index: Map.get(meta, :index)}
        )

        {{:concord_kv, data}, :ok, []}

      [] ->
        {{:concord_kv, data}, {:error, :lease_not_found}, []}
    end
  end

  def apply_command(meta, {:revoke_lease, lease_id, _opts}, {:concord_kv, data}) do
    ensure_ets_table(leases_table(), [:set, :named_table])

    case :ets.lookup(leases_table(), lease_id) do
      [{^lease_id, lease}] ->
        commit_rev = Map.get(data, :revision, 0) + 1

        # Delete all attached keys
        deleted =
          Enum.count(lease.keys, fn key ->
            prev = get_current_record(key)

            if prev && prev.version > 0 do
              :ets.insert(history_table(), {{key, prev.mod_revision}, prev})
              tombstone = Record.tombstone(key, commit_rev, prev)
              :ets.insert(history_table(), {{key, commit_rev}, tombstone})
              :ets.delete(current_table(), key)
              :ets.delete(store_table(), key)

              old_val = Compression.decompress(prev.value)
              if old_val, do: remove_from_all_indexes(data, key, old_val)
              true
            else
              false
            end
          end)

        :ets.delete(leases_table(), lease_id)
        new_data = Map.put(data, :revision, commit_rev)

        :telemetry.execute(
          [:concord, :lease, :revoked],
          %{lease_id: lease_id, deleted_keys: deleted},
          %{index: Map.get(meta, :index)}
        )

        {{:concord_kv, new_data}, {:ok, %{deleted_keys: deleted}}, []}

      [] ->
        {{:concord_kv, data}, {:error, :lease_not_found}, []}
    end
  end

  # Expire lease (triggered by periodic tick)
  def apply_command(meta, {:expire_lease, lease_id}, {:concord_kv, data}) do
    apply_command(meta, {:revoke_lease, lease_id, %{}}, {:concord_kv, data})
  end

  # Catch-all for unknown commands
  def apply_command(meta, command, {:concord_kv, data}) do
    :telemetry.execute(
      [:concord, :operation, :unknown_command],
      %{command: inspect(command)},
      %{index: Map.get(meta, :index)}
    )

    {{:concord_kv, data}, :ok, []}
  end

  # ══════════════════════════════════════════════
  # STATE ENTER CALLBACK
  # ══════════════════════════════════════════════

  @impl :ra_machine
  def state_enter(status, {:concord_kv, _data}) do
    :telemetry.execute(
      [:concord, :state, :change],
      %{timestamp: System.system_time()},
      %{status: status, node: node()}
    )

    []
  end

  def state_enter(_status, _state), do: []

  # ══════════════════════════════════════════════
  # QUERY FUNCTIONS (read-only, bypass Raft log)
  # ══════════════════════════════════════════════

  # MFA-compatible wrapper for Ra 3.0 remote queries (leader_query, consistent_query).
  # Ra 3.0 calls MFA tuples as Module.func(state, extra_args...), so this reverses
  # arg order to match the query/2 convention of query(query_term, state).
  def ra_query(query_term, state) do
    query(query_term, state)
  end

  def query({:get, key}, {:concord_kv, _data}) do
    now = System.system_time(:second)

    case :ets.lookup(store_table(), key) do
      [{^key, stored_data}] ->
        case extract_value(stored_data) do
          {value, expires_at} ->
            if expired?(expires_at, now), do: {:error, :not_found}, else: {:ok, value}

          _ ->
            {:error, :invalid_stored_format}
        end

      [] ->
        {:error, :not_found}
    end
  end

  def query({:get_with_ttl, key}, {:concord_kv, _data}) do
    now = System.system_time(:second)

    case :ets.lookup(store_table(), key) do
      [{^key, stored_data}] ->
        case extract_value(stored_data) do
          {value, expires_at} ->
            if expired?(expires_at, now) do
              {:error, :not_found}
            else
              remaining_ttl = if expires_at, do: max(0, expires_at - now), else: nil
              {:ok, {value, remaining_ttl}}
            end

          _ ->
            {:error, :invalid_stored_format}
        end

      [] ->
        {:error, :not_found}
    end
  end

  def query(:get_all, {:concord_kv, _data}) do
    now = System.system_time(:second)
    all = :ets.tab2list(store_table())

    valid_entries =
      Enum.reduce(all, [], fn {key, stored_data}, acc ->
        case extract_value(stored_data) do
          {value, expires_at} ->
            if expired?(expires_at, now), do: acc, else: [{key, value} | acc]

          _ ->
            acc
        end
      end)

    {:ok, Map.new(valid_entries)}
  end

  def query(:get_all_with_ttl, {:concord_kv, _data}) do
    now = System.system_time(:second)
    all = :ets.tab2list(store_table())

    valid_entries =
      Enum.reduce(all, [], fn {key, stored_data}, acc ->
        case extract_value(stored_data) do
          {value, expires_at} ->
            if expired?(expires_at, now) do
              acc
            else
              remaining_ttl = if expires_at, do: max(0, expires_at - now), else: nil
              [{key, %{value: value, ttl: remaining_ttl}} | acc]
            end

          _ ->
            acc
        end
      end)

    {:ok, Map.new(valid_entries)}
  end

  def query({:ttl, key}, {:concord_kv, _data}) do
    now = System.system_time(:second)

    case :ets.lookup(store_table(), key) do
      [{^key, stored_data}] ->
        case extract_value(stored_data) do
          {_value, expires_at} ->
            if expired?(expires_at, now) do
              {:error, :not_found}
            else
              if expires_at do
                {:ok, max(0, expires_at - now)}
              else
                {:ok, nil}
              end
            end

          _ ->
            {:error, :invalid_stored_format}
        end

      [] ->
        {:error, :not_found}
    end
  end

  def query({:get_many, keys}, {:concord_kv, _data}) when is_list(keys) do
    now = System.system_time(:second)
    results = batch_get_keys(keys, now)
    {:ok, Map.new(results)}
  end

  def query({:prefix_scan, prefix}, {:concord_kv, _data}) when is_binary(prefix) do
    now = System.system_time(:second)
    # Upper bound: any key starting with `prefix` is lexicographically < prefix <> <<255>>
    # because byte values after the prefix will be < 255 for all normal string characters.
    end_key = prefix <> <<255>>

    match_spec = [
      {{:"$1", :"$2"}, [{:>=, :"$1", prefix}, {:<, :"$1", end_key}], [{{:"$1", :"$2"}}]}
    ]

    entries =
      case :ets.whereis(store_table()) do
        :undefined ->
          []

        table ->
          try do
            :ets.select(table, match_spec)
          catch
            :error, :badarg -> []
          end
      end

    results =
      Enum.reduce(entries, [], fn {key, stored_data}, acc ->
        case extract_value(stored_data) do
          {value, expires_at} ->
            if expired?(expires_at, now), do: acc, else: [{key, value} | acc]

          _ ->
            acc
        end
      end)

    {:ok, results}
  end

  def query(:stats, {:concord_kv, _data}) do
    info = :ets.info(store_table())

    {:ok,
     %{
       size: Keyword.get(info, :size, 0),
       memory: Keyword.get(info, :memory, 0)
     }}
  end

  def query({:index_lookup, name, value}, {:concord_kv, data}) do
    indexes = Map.get(data, :indexes, %{})

    if Map.has_key?(indexes, name) do
      table_name = Index.index_table_name(name)

      keys =
        if :ets.whereis(table_name) != :undefined do
          case :ets.lookup(table_name, value) do
            [{^value, key_list}] -> key_list
            [] -> []
          end
        else
          []
        end

      {:ok, keys}
    else
      {:ok, {:error, :not_found}}
    end
  end

  def query(:list_indexes, {:concord_kv, data}) do
    indexes = Map.get(data, :indexes, %{})
    {:ok, Map.keys(indexes)}
  end

  def query({:get_index_extractor, name}, {:concord_kv, data}) do
    indexes = Map.get(data, :indexes, %{})

    case Map.get(indexes, name) do
      nil -> {:ok, {:error, :not_found}}
      extractor -> {:ok, extractor}
    end
  end

  # ──────────────────────────────────────────────
  # v2 Query Handlers
  # ──────────────────────────────────────────────

  # Return full Record struct for a key
  def query({:get_record, key}, {:concord_kv, _data}) do
    now = System.system_time(:second)

    case :ets.lookup(current_table(), key) do
      [{^key, %Record{} = record}] ->
        if Record.expired?(record, now), do: {:error, :not_found}, else: {:ok, record}

      _ ->
        {:error, :not_found}
    end
  end

  # Time-travel read: get value at a specific revision
  def query({:get, key, revision: rev}, {:concord_kv, data}) do
    compact_rev = Map.get(data, :compact_revision, 0)

    if rev <= compact_rev do
      {:error, {:compacted, compact_rev}}
    else
      # Check current first
      case :ets.lookup(current_table(), key) do
        [{^key, %Record{mod_revision: mod_rev} = record}] when mod_rev <= rev ->
          if Record.tombstone?(record), do: {:error, :not_found}, else: {:ok, record.value}

        _ ->
          # Walk history for the latest version at or before rev
          find_record_at_revision(key, rev)
      end
    end
  end

  # Get current cluster revision
  def query(:get_revision, {:concord_kv, data}) do
    {:ok, Map.get(data, :revision, 0)}
  end

  # Key history
  def query({:history, key, opts}, {:concord_kv, data}) do
    from_rev = Keyword.get(opts, :from_revision, 0)
    to_rev = Keyword.get(opts, :to_revision, Map.get(data, :revision, 0))
    limit = Keyword.get(opts, :limit, 100)
    compact_rev = Map.get(data, :compact_revision, 0)

    if from_rev <= compact_rev do
      {:error, {:compacted, compact_rev}}
    else
      # Collect from history table
      history =
        :ets.select(history_table(), [
          {{{:"$1", :"$2"}, :"$3"},
           [{:==, :"$1", key}, {:>=, :"$2", from_rev}, {:"=<", :"$2", to_rev}],
           [{{:"$2", :"$3"}}]}
        ])
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.take(limit)
        |> Enum.map(&elem(&1, 1))

      # Also include current if in range
      current =
        case :ets.lookup(current_table(), key) do
          [{^key, %Record{mod_revision: mr} = rec}]
          when mr >= from_rev and mr <= to_rev ->
            [rec]

          _ ->
            []
        end

      all = (history ++ current) |> Enum.sort_by(& &1.mod_revision) |> Enum.take(limit)
      {:ok, all}
    end
  end

  # List by prefix or range
  def query({:list, selector, list_opts}, {:concord_kv, _data}) do
    now = System.system_time(:second)
    limit = Map.get(list_opts, :limit, 1000)
    keys_only = Map.get(list_opts, :keys_only, false)

    {start_key, end_key} =
      case selector do
        {:prefix, p} -> {p, p <> <<0xFF>>}
        {:range, s, e} -> {s, e}
      end

    match_spec = [
      {{:"$1", :"$2"}, [{:>=, :"$1", start_key}, {:<, :"$1", end_key}], [{{:"$1", :"$2"}}]}
    ]

    # Fetch limit+1 to detect has_more
    results =
      :ets.select(current_table(), match_spec)
      |> Enum.reduce([], fn {key, %Record{} = rec}, acc ->
        if Record.expired?(rec, now), do: acc, else: [{key, rec} | acc]
      end)
      |> Enum.sort_by(&elem(&1, 0))

    has_more = length(results) > limit
    trimmed = Enum.take(results, limit)

    records =
      if keys_only do
        Enum.map(trimmed, fn {key, rec} -> %{rec | value: nil} |> Map.put(:key, key) end)
      else
        Enum.map(trimmed, fn {key, rec} -> Map.put(rec, :key, key) end)
      end

    last_key = if trimmed != [], do: elem(List.last(trimmed), 0), else: nil
    {:ok, records, %{has_more: has_more, last_key: last_key}}
  end

  # Lease queries
  def query({:lease_info, lease_id}, {:concord_kv, _data}) do
    now = System.system_time(:second)

    case :ets.whereis(leases_table()) do
      :undefined ->
        {:error, :lease_not_found}

      _ ->
        case :ets.lookup(leases_table(), lease_id) do
          [{^lease_id, lease}] ->
            remaining = max(0, lease.expires_at - now)
            {:ok, Map.put(lease, :remaining, remaining)}

          [] ->
            {:error, :lease_not_found}
        end
    end
  end

  def query(:list_leases, {:concord_kv, _data}) do
    now = System.system_time(:second)

    leases =
      case :ets.whereis(leases_table()) do
        :undefined ->
          []

        _ ->
          :ets.tab2list(leases_table())
          |> Enum.map(fn {_id, lease} ->
            Map.put(lease, :remaining, max(0, lease.expires_at - now))
          end)
      end

    {:ok, leases}
  end

  # Query handlers for snapshot format state (before first apply normalizes it)
  def query(query_cmd, %{__concord_snapshot_version__: 3, state: state_data}) do
    query(query_cmd, {:concord_kv, state_data})
  end

  def query(_query_cmd, _state), do: {:error, :unknown_query}

  # ══════════════════════════════════════════════
  # SNAPSHOT STATE BUILDER
  # ══════════════════════════════════════════════
  #
  # Ra does NOT have a snapshot/1 callback. Instead, we embed ETS data
  # into the state passed to the {:release_cursor, index, state} effect.
  # Ra serializes this state as the snapshot. On restore, snapshot_installed/4
  # rebuilds ETS from the embedded data, and normalize_state/1 strips the
  # snapshot keys on the next apply.

  defp build_release_cursor_state({:concord_kv, data}) do
    kv_data = :ets.tab2list(store_table())
    current_data = :ets.tab2list(current_table())
    history_data = :ets.tab2list(history_table())

    lease_data =
      case :ets.whereis(leases_table()) do
        :undefined -> []
        _ -> :ets.tab2list(leases_table())
      end

    indexes = Map.get(data, :indexes, %{})

    # Capture index ETS data
    index_ets =
      Enum.reduce(indexes, %{}, fn {name, _spec}, acc ->
        table = Index.index_table_name(name)

        ets_data =
          if :ets.whereis(table) != :undefined,
            do: :ets.tab2list(table),
            else: []

        Map.put(acc, name, ets_data)
      end)

    {:concord_kv,
     Map.merge(data, %{
       __snapshot_version__: 3,
       __kv_data__: kv_data,
       __current_data__: current_data,
       __history_data__: history_data,
       __lease_data__: lease_data,
       __index_ets__: index_ets
     })}
  end

  # ══════════════════════════════════════════════
  # SNAPSHOT INSTALLED — Rebuild all ETS tables
  # ══════════════════════════════════════════════

  @impl :ra_machine
  def snapshot_installed(snapshot, _metadata, _old_state, _aux) do
    case snapshot do
      {:concord_kv, data} when is_map(data) ->
        rebuild_all_ets_from_snapshot(data)

      # V1/V2 legacy: bare list of KV tuples
      data when is_list(data) ->
        ensure_ets_table(store_table(), [:ordered_set, :named_table])
        :ets.delete_all_objects(store_table())
        Enum.each(data, fn entry -> :ets.insert(store_table(), entry) end)
    end

    :telemetry.execute(
      [:concord, :snapshot, :installed],
      %{timestamp: System.system_time()},
      %{node: node()}
    )

    []
  end

  defp rebuild_all_ets_from_snapshot(data) do
    # Rebuild main KV store (legacy)
    ensure_ets_table(store_table(), [:ordered_set, :named_table])
    :ets.delete_all_objects(store_table())

    Enum.each(Map.get(data, :__kv_data__, []), fn entry ->
      :ets.insert(store_table(), entry)
    end)

    # Rebuild v2 current table
    ensure_ets_table(current_table(), [:ordered_set, :named_table])
    :ets.delete_all_objects(current_table())

    Enum.each(Map.get(data, :__current_data__, []), fn entry ->
      :ets.insert(current_table(), entry)
    end)

    # Rebuild v2 history table
    ensure_ets_table(history_table(), [:ordered_set, :named_table])
    :ets.delete_all_objects(history_table())

    Enum.each(Map.get(data, :__history_data__, []), fn entry ->
      :ets.insert(history_table(), entry)
    end)

    # Rebuild index ETS tables
    index_ets = Map.get(data, :__index_ets__, %{})

    Enum.each(Map.get(data, :indexes, %{}), fn {name, _spec} ->
      table = Index.index_table_name(name)
      ensure_ets_table(table)
      :ets.delete_all_objects(table)

      Enum.each(Map.get(index_ets, name, []), fn entry ->
        :ets.insert(table, entry)
      end)
    end)

    # Rebuild lease table
    ensure_ets_table(leases_table(), [:set, :named_table])
    :ets.delete_all_objects(leases_table())

    Enum.each(Map.get(data, :__lease_data__, []), fn entry ->
      :ets.insert(leases_table(), entry)
    end)
  end

  # ══════════════════════════════════════════════
  # VERSION
  # ══════════════════════════════════════════════

  @impl :ra_machine
  def version, do: 3

  # ══════════════════════════════════════════════
  # PRIVATE HELPERS
  # ══════════════════════════════════════════════

  defp get_decompressed_value(key) do
    case :ets.lookup(store_table(), key) do
      [{^key, stored_data}] ->
        case extract_value(stored_data) do
          {val, _expires} -> Compression.decompress(val)
          _ -> nil
        end

      [] ->
        nil
    end
  end

  # v2: Look up the full Record from concord_current table
  defp get_current_record(key) do
    case :ets.lookup(current_table(), key) do
      [{^key, %Record{} = record}] -> record
      _ -> nil
    end
  end

  # v2: Find the latest record version at or before a given revision
  defp find_record_at_revision(key, target_rev) do
    # Walk backward from target_rev in history
    case :ets.prev(history_table(), {key, target_rev + 1}) do
      :"$end_of_table" ->
        {:error, :not_found}

      {^key, _rev} = hist_key ->
        case :ets.lookup(history_table(), hist_key) do
          [{_, %Record{version: 0}}] -> {:error, :not_found}
          [{_, %Record{} = record}] -> {:ok, record.value}
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp update_indexes_on_put(data, key, old_value, new_decompressed) do
    indexes = Map.get(data, :indexes, %{})

    Enum.each(indexes, fn {index_name, extractor} ->
      table_name = Index.index_table_name(index_name)

      if old_value != nil do
        Extractor.remove_from_index(table_name, key, old_value, extractor)
      end

      Extractor.index_value(table_name, key, new_decompressed, extractor)
    end)
  end

  defp remove_from_all_indexes(data, key, old_value) do
    indexes = Map.get(data, :indexes, %{})

    Enum.each(indexes, fn {index_name, extractor} ->
      table_name = Index.index_table_name(index_name)
      Extractor.remove_from_index(table_name, key, old_value, extractor)
    end)
  end

  defp rebuild_all_index_ets(indexes) do
    all_entries = :ets.tab2list(store_table())

    Enum.each(indexes, fn {name, spec} ->
      table = Index.index_table_name(name)
      ensure_ets_table(table)
      :ets.delete_all_objects(table)

      Enum.each(all_entries, fn {key, stored_data} ->
        case extract_value(stored_data) do
          {val, _expires} ->
            decompressed = Compression.decompress(val)
            Extractor.index_value(table, key, decompressed, spec)

          _ ->
            :ok
        end
      end)
    end)
  end

  # Conditional operations helper: delete_if CAS path.
  # expected is always non-nil (set by public API before entering the log).
  defp check_conditional_operation(key, expected, now, on_success) do
    case :ets.lookup(store_table(), key) do
      [{^key, stored_data}] ->
        case extract_value(stored_data) do
          {current_value, current_expires_at} ->
            if expired?(current_expires_at, now) do
              {:error, :not_found}
            else
              if expected != nil and Compression.decompress(current_value) == expected do
                on_success.()
              else
                {:error, :condition_failed}
              end
            end

          _ ->
            {:error, :invalid_stored_format}
        end

      [] ->
        {:error, :not_found}
    end
  end

  # Batch get using deterministic time parameter
  defp batch_get_keys(keys, now) do
    Enum.map(keys, fn key ->
      case :ets.lookup(store_table(), key) do
        [{^key, stored_data}] ->
          case extract_value(stored_data) do
            {value, expires_at} ->
              if expired?(expires_at, now),
                do: {key, {:error, :not_found}},
                else: {key, {:ok, value}}

            _ ->
              {key, {:error, :invalid_stored_format}}
          end

        [] ->
          {key, {:error, :not_found}}
      end
    end)
  end

  # Batch validation and execution helpers

  defp validate_put_many_operations(operations) do
    if length(operations) > 500 do
      {:error, :batch_too_large}
    else
      case Enum.find_value(operations, fn op ->
             case validate_put_operation(op) do
               :ok -> nil
               error -> error
             end
           end) do
        nil -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_put_operation({key, _value, expires_at}) when is_binary(key) do
    cond do
      byte_size(key) == 0 -> {:error, :invalid_key}
      expires_at != nil and not is_integer(expires_at) -> {:error, :invalid_expires_at}
      true -> :ok
    end
  end

  defp validate_put_operation({key, _value}) when is_binary(key) do
    if byte_size(key) == 0, do: {:error, :invalid_key}, else: :ok
  end

  defp validate_put_operation(_), do: {:error, :invalid_operation_format}

  defp execute_put_many_batch(operations, data) do
    Enum.map(operations, fn
      {key, value, expires_at} ->
        old_value = get_decompressed_value(key)
        formatted_value = format_value(value, expires_at)

        case :ets.insert(store_table(), {key, formatted_value}) do
          true ->
            update_indexes_on_put(data, key, old_value, Compression.decompress(value))
            {key, :ok}

          _ ->
            {key, {:error, :insert_failed}}
        end

      {key, value} ->
        old_value = get_decompressed_value(key)
        formatted_value = format_value(value, nil)

        case :ets.insert(store_table(), {key, formatted_value}) do
          true ->
            update_indexes_on_put(data, key, old_value, Compression.decompress(value))
            {key, :ok}

          _ ->
            {key, {:error, :insert_failed}}
        end

      _ ->
        {:error, :invalid_operation_format}
    end)
  end

  defp validate_delete_many_operations(keys) do
    if length(keys) > 500 do
      {:error, :batch_too_large}
    else
      case Enum.find(keys, fn key ->
             not (is_binary(key) and byte_size(key) > 0)
           end) do
        nil -> :ok
        _ -> {:error, :invalid_key}
      end
    end
  end

  defp execute_delete_many_batch(keys, data) do
    Enum.map(keys, fn key ->
      # Remove from indexes before deleting
      old_value = get_decompressed_value(key)

      if old_value != nil do
        remove_from_all_indexes(data, key, old_value)
      end

      case :ets.delete(store_table(), key) do
        true -> {key, :ok}
        false -> {key, {:error, :not_found}}
        _ -> {key, {:error, :delete_failed}}
      end
    end)
  end

  defp validate_touch_many_operations(operations) do
    if length(operations) > 500 do
      {:error, :batch_too_large}
    else
      case Enum.find_value(operations, fn op ->
             case validate_touch_operation(op) do
               :ok -> nil
               error -> error
             end
           end) do
        nil -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_touch_operation({key, ttl_seconds})
       when is_binary(key) and byte_size(key) > 0 and is_integer(ttl_seconds) and ttl_seconds > 0,
       do: :ok

  defp validate_touch_operation(_), do: {:error, :invalid_touch_operation}

  defp execute_touch_many_batch(operations, now) do
    Enum.map(operations, fn {key, ttl_seconds} ->
      case :ets.lookup(store_table(), key) do
        [{^key, stored_data}] ->
          case extract_value(stored_data) do
            {value, _current_expires_at} ->
              new_expires_at = now + ttl_seconds
              new_stored_data = format_value(value, new_expires_at)

              case :ets.insert(store_table(), {key, new_stored_data}) do
                true -> {key, :ok}
                _ -> {key, {:error, :touch_failed}}
              end

            _ ->
              {key, {:error, :invalid_stored_format}}
          end

        [] ->
          {key, {:error, :not_found}}
      end
    end)
  end

  # ══════════════════════════════════════════════
  # TRANSACTION HELPERS
  # ══════════════════════════════════════════════

  defp mutating_op?({:put, _, _, _}), do: true
  defp mutating_op?({:delete, _, _}), do: true
  defp mutating_op?({:touch, _, _, _}), do: true
  defp mutating_op?(_), do: false

  # Compare evaluation — each compare targets exactly one key
  defp eval_compare({:exists, key, op, expected_bool}, now) do
    record = get_current_record(key)
    actual = record != nil and not Record.expired?(record, now) and record.version > 0
    compare_values(op, actual, expected_bool)
  end

  defp eval_compare({:value, key, op, expected}, now) do
    actual = get_record_value_for_compare(key, now)
    compare_values(op, actual, expected)
  end

  defp eval_compare({:field, key, path, op, expected}, now) do
    actual = get_record_value_for_compare(key, now)
    extracted = extract_field(actual, path)
    compare_values(op, extracted, expected)
  end

  defp eval_compare({:version, key, op, expected}, now) do
    actual = get_record_field_for_compare(key, now, :version, 0)
    compare_values(op, actual, expected)
  end

  defp eval_compare({:create_revision, key, op, expected}, now) do
    actual = get_record_field_for_compare(key, now, :create_revision, 0)
    compare_values(op, actual, expected)
  end

  defp eval_compare({:mod_revision, key, op, expected}, now) do
    actual = get_record_field_for_compare(key, now, :mod_revision, 0)
    compare_values(op, actual, expected)
  end

  defp eval_compare({:lease, key, op, expected}, now) do
    actual = get_record_field_for_compare(key, now, :lease_id, nil)
    compare_values(op, actual, expected)
  end

  defp eval_compare({:ttl, key, op, expected}, now) do
    record = get_current_record(key)

    actual =
      cond do
        record == nil -> nil
        Record.expired?(record, now) -> nil
        record.expires_at == nil -> nil
        true -> max(0, record.expires_at - now)
      end

    compare_values(op, actual, expected)
  end

  defp eval_compare(_, _now), do: false

  defp get_record_value_for_compare(key, now) do
    case get_current_record(key) do
      nil ->
        nil

      record ->
        if Record.expired?(record, now) or record.version == 0,
          do: nil,
          else: Compression.decompress(record.value)
    end
  end

  defp get_record_field_for_compare(key, now, field, default) do
    case get_current_record(key) do
      nil ->
        default

      record ->
        if Record.expired?(record, now), do: default, else: Map.get(record, field, default)
    end
  end

  defp extract_field(nil, _path), do: nil

  defp extract_field(value, path) when is_list(path) do
    Enum.reduce_while(path, value, fn
      key, acc when is_map(acc) -> {:cont, Map.get(acc, key)}
      _key, _acc -> {:halt, nil}
    end)
  end

  defp compare_values(:==, a, b), do: a == b
  defp compare_values(:!=, a, b), do: a != b
  defp compare_values(:>, a, b) when is_number(a) and is_number(b), do: a > b
  defp compare_values(:>=, a, b) when is_number(a) and is_number(b), do: a >= b
  defp compare_values(:<, a, b) when is_number(a) and is_number(b), do: a < b
  defp compare_values(:<=, a, b) when is_number(a) and is_number(b), do: a <= b
  defp compare_values(_, _, _), do: false

  # Execute a single operation within a txn branch
  defp execute_txn_op({:get, {:key, key}, _opts}, data, _commit_rev, _meta) do
    now = System.system_time(:second)
    record = get_current_record(key)

    kvs =
      if record && not Record.expired?(record, now) && record.version > 0,
        do: [record],
        else: []

    resp = {:get, {:key, key}, %{kvs: kvs, count: length(kvs)}}
    {resp, data}
  end

  defp execute_txn_op({:get, selector, opts}, data, _commit_rev, _meta) do
    now = System.system_time(:second)
    limit = Map.get(opts, :limit, 1000)

    {start_key, end_key} =
      case selector do
        {:prefix, p} -> {p, p <> <<0xFF>>}
        {:range, s, e} -> {s, e}
      end

    match_spec = [
      {{:"$1", :"$2"}, [{:>=, :"$1", start_key}, {:<, :"$1", end_key}], [{{:"$1", :"$2"}}]}
    ]

    kvs =
      :ets.select(current_table(), match_spec)
      |> Enum.reduce([], fn {_key, %Record{} = rec}, acc ->
        if Record.expired?(rec, now) or rec.version == 0, do: acc, else: [rec | acc]
      end)
      |> Enum.sort_by(& &1.mod_revision)
      |> Enum.take(limit)

    resp = {:get, selector, %{kvs: kvs, count: length(kvs)}}
    {resp, data}
  end

  defp execute_txn_op({:put, key, value, opts}, data, commit_rev, meta) do
    return_prev = Map.get(opts, :prev_kv, false)
    ttl = Map.get(opts, :ttl)
    expires_at = if ttl, do: meta_time(meta) + ttl, else: nil
    content_type = Map.get(opts, :content_type)
    kv_metadata = Map.get(opts, :metadata, %{})
    lease_id = Map.get(opts, :lease)

    prev_record = get_current_record(key)
    old_value = if prev_record, do: Compression.decompress(prev_record.value), else: nil

    if prev_record do
      :ets.insert(history_table(), {{key, prev_record.mod_revision}, prev_record})
    end

    new_record = %Record{
      value: value,
      create_revision:
        if(prev_record && prev_record.version > 0,
          do: prev_record.create_revision,
          else: commit_rev
        ),
      mod_revision: commit_rev,
      version: if(prev_record && prev_record.version > 0, do: prev_record.version + 1, else: 1),
      expires_at: expires_at,
      lease_id: lease_id,
      content_type: content_type,
      metadata: kv_metadata || %{}
    }

    :ets.insert(current_table(), {key, new_record})
    :ets.insert(store_table(), {key, format_value(value, expires_at)})

    update_indexes_on_put(data, key, old_value, Compression.decompress(value))

    resp = {:put, key, %{prev_kv: if(return_prev, do: prev_record, else: nil)}}
    {resp, data}
  end

  defp execute_txn_op({:delete, selector, opts}, data, commit_rev, _meta) do
    return_prev = Map.get(opts, :prev_kv, false)

    keys_to_delete =
      case selector do
        {:key, key} ->
          [key]

        {:prefix, p} ->
          end_key = p <> <<0xFF>>

          :ets.select(current_table(), [
            {{:"$1", :_}, [{:>=, :"$1", p}, {:<, :"$1", end_key}], [:"$1"]}
          ])

        {:range, s, e} ->
          :ets.select(current_table(), [
            {{:"$1", :_}, [{:>=, :"$1", s}, {:<, :"$1", e}], [:"$1"]}
          ])
      end

    prev_kvs =
      Enum.flat_map(keys_to_delete, fn key ->
        prev = get_current_record(key)

        if prev && prev.version > 0 do
          :ets.insert(history_table(), {{key, prev.mod_revision}, prev})
          tombstone = Record.tombstone(key, commit_rev, prev)
          :ets.insert(history_table(), {{key, commit_rev}, tombstone})
          :ets.delete(current_table(), key)
          :ets.delete(store_table(), key)

          old_val = Compression.decompress(prev.value)
          if old_val, do: remove_from_all_indexes(data, key, old_val)

          if return_prev, do: [prev], else: []
        else
          []
        end
      end)

    resp = {:delete, selector, %{deleted: length(keys_to_delete), prev_kvs: prev_kvs}}
    {resp, data}
  end

  defp execute_txn_op({:touch, key, ttl_seconds, _opts}, data, commit_rev, meta) do
    now = meta_time(meta)

    case get_current_record(key) do
      nil ->
        resp = {:touch, key, %{ttl: :not_found}}
        {resp, data}

      record ->
        if Record.expired?(record, now) or record.version == 0 do
          resp = {:touch, key, %{ttl: :not_found}}
          {resp, data}
        else
          new_expires = now + ttl_seconds

          updated = %{record | expires_at: new_expires, mod_revision: commit_rev}
          :ets.insert(current_table(), {key, updated})
          :ets.insert(store_table(), {key, format_value(record.value, new_expires)})

          resp = {:touch, key, %{ttl: ttl_seconds}}
          {resp, data}
        end
    end
  end

  defp execute_txn_op(_, data, _commit_rev, _meta) do
    {{:error, :unsupported_op}, data}
  end
end
