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

  defp format_value(value, expires_at) do
    %{value: value, expires_at: expires_at}
  end

  defp extract_value(%{value: value, expires_at: expires_at}), do: {value, expires_at}
  defp extract_value({value, expires_at}) when is_integer(expires_at), do: {value, expires_at}
  defp extract_value(value), do: {value, nil}

  defp expired?(nil, _now), do: false
  defp expired?(expires_at, now), do: now > expires_at

  # ──────────────────────────────────────────────
  # Default State Fields
  # ──────────────────────────────────────────────

  defp default_state_fields do
    %{
      indexes: %{},
      command_count: 0
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
    ensure_ets_table(:concord_store, [:ordered_set, :public, :named_table])

    {:concord_kv, default_state_fields()}
  end

  defp ensure_ets_table(name, opts \\ [:set, :public, :named_table]) do
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

  def apply_command(meta, {:put, key, value, expires_at}, {:concord_kv, data}) do
    start_time = System.monotonic_time()

    old_value = get_decompressed_value(key)

    formatted_value = format_value(value, expires_at)
    :ets.insert(:concord_store, {key, formatted_value})

    update_indexes_on_put(data, key, old_value, Compression.decompress(value))

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :put, key: key, index: Map.get(meta, :index), has_ttl: expires_at != nil}
    )

    {{:concord_kv, data}, :ok, []}
  end

  def apply_command(meta, {:delete, key}, {:concord_kv, data}) do
    start_time = System.monotonic_time()

    old_value = get_decompressed_value(key)
    :ets.delete(:concord_store, key)

    if old_value != nil do
      remove_from_all_indexes(data, key, old_value)
    end

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :delete, key: key, index: Map.get(meta, :index)}
    )

    {{:concord_kv, data}, :ok, []}
  end

  # put_if — Compare-and-swap (no anonymous functions in command)
  def apply_command(meta, {:put_if, key, value, expires_at, expected}, {:concord_kv, data}) do
    start_time = System.monotonic_time()
    now = meta_time(meta)

    result =
      case :ets.lookup(:concord_store, key) do
        [{^key, stored_data}] ->
          case extract_value(stored_data) do
            {current_value, current_expires_at} ->
              if expired?(current_expires_at, now) do
                {:error, :not_found}
              else
                old_decompressed = Compression.decompress(current_value)

                if old_decompressed == expected do
                  formatted_value = format_value(value, expires_at)
                  :ets.insert(:concord_store, {key, formatted_value})

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

  # Backward compatibility: put_if with condition_fn (6-tuple)
  # The condition_fn is evaluated here for backward compat during migration.
  # New code should use the 5-tuple CAS form above.
  def apply_command(
        meta,
        {:put_if, key, value, expires_at, expected, condition_fn},
        {:concord_kv, data}
      ) do
    start_time = System.monotonic_time()
    now = meta_time(meta)

    result =
      check_conditional_operation(key, expected, condition_fn, now, fn ->
        old_value = get_decompressed_value(key)
        formatted_value = format_value(value, expires_at)
        :ets.insert(:concord_store, {key, formatted_value})
        update_indexes_on_put(data, key, old_value, Compression.decompress(value))
        :ok
      end)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :put_if, key: key, index: Map.get(meta, :index), result: result}
    )

    {{:concord_kv, data}, result, []}
  end

  def apply_command(meta, {:delete_if, key, expected, condition_fn}, {:concord_kv, data}) do
    start_time = System.monotonic_time()
    now = meta_time(meta)

    result =
      check_conditional_operation(key, expected, condition_fn, now, fn ->
        old_value = get_decompressed_value(key)
        :ets.delete(:concord_store, key)

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
      case :ets.lookup(:concord_store, key) do
        [{^key, stored_data}] ->
          case extract_value(stored_data) do
            {value, _current_expires_at} ->
              new_expires_at = now + additional_ttl_seconds
              new_stored_data = format_value(value, new_expires_at)
              :ets.insert(:concord_store, {key, new_stored_data})
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
    all_entries = :ets.tab2list(:concord_store)

    {deleted_count, scanned_count} =
      Enum.reduce(all_entries, {0, 0}, fn {key, stored_data}, {deleted, scanned} ->
        case extract_value(stored_data) do
          {value, expires_at} when expires_at != nil ->
            if expired?(expires_at, now) do
              decompressed = Compression.decompress(value)

              if decompressed != nil do
                remove_from_all_indexes(data, key, decompressed)
              end

              :ets.delete(:concord_store, key)
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
      ensure_ets_table(table_name, [:set, :public, :named_table])

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
    :ets.delete_all_objects(:concord_store)

    Enum.each(Map.get(backup_state, :kv_data, []), fn entry ->
      :ets.insert(:concord_store, entry)
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

    :ets.delete_all_objects(:concord_store)

    Enum.each(kv_entries, fn entry ->
      :ets.insert(:concord_store, entry)
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

  def query({:get, key}, {:concord_kv, _data}) do
    now = System.system_time(:second)

    case :ets.lookup(:concord_store, key) do
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

    case :ets.lookup(:concord_store, key) do
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
    all = :ets.tab2list(:concord_store)

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
    all = :ets.tab2list(:concord_store)

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

    case :ets.lookup(:concord_store, key) do
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

    results =
      :ets.select(:concord_store, match_spec)
      |> Enum.reduce([], fn {key, stored_data}, acc ->
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
    info = :ets.info(:concord_store)

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
    kv_data = :ets.tab2list(:concord_store)
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
        ensure_ets_table(:concord_store, [:ordered_set, :public, :named_table])
        :ets.delete_all_objects(:concord_store)
        Enum.each(data, fn entry -> :ets.insert(:concord_store, entry) end)
    end

    :telemetry.execute(
      [:concord, :snapshot, :installed],
      %{timestamp: System.system_time()},
      %{node: node()}
    )

    []
  end

  defp rebuild_all_ets_from_snapshot(data) do
    # Rebuild main KV store
    ensure_ets_table(:concord_store, [:ordered_set, :public, :named_table])
    :ets.delete_all_objects(:concord_store)

    Enum.each(Map.get(data, :__kv_data__, []), fn entry ->
      :ets.insert(:concord_store, entry)
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
    case :ets.lookup(:concord_store, key) do
      [{^key, stored_data}] ->
        case extract_value(stored_data) do
          {val, _expires} -> Compression.decompress(val)
          _ -> nil
        end

      [] ->
        nil
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
    all_entries = :ets.tab2list(:concord_store)

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

  # Conditional operations helper (supports both expected and condition_fn for backward compat)
  defp check_conditional_operation(key, expected, condition_fn, now, on_success) do
    case :ets.lookup(:concord_store, key) do
      [{^key, stored_data}] ->
        case extract_value(stored_data) do
          {current_value, current_expires_at} ->
            if expired?(current_expires_at, now) do
              {:error, :not_found}
            else
              condition_met =
                cond do
                  expected != nil ->
                    Compression.decompress(current_value) == expected

                  condition_fn != nil and is_function(condition_fn, 1) ->
                    try do
                      condition_fn.(Compression.decompress(current_value))
                    rescue
                      _ -> false
                    end

                  true ->
                    false
                end

              if condition_met, do: on_success.(), else: {:error, :condition_failed}
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
      case :ets.lookup(:concord_store, key) do
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

        case :ets.insert(:concord_store, {key, formatted_value}) do
          true ->
            update_indexes_on_put(data, key, old_value, Compression.decompress(value))
            {key, :ok}

          _ ->
            {key, {:error, :insert_failed}}
        end

      {key, value} ->
        old_value = get_decompressed_value(key)
        formatted_value = format_value(value, nil)

        case :ets.insert(:concord_store, {key, formatted_value}) do
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

      case :ets.delete(:concord_store, key) do
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
      case :ets.lookup(:concord_store, key) do
        [{^key, stored_data}] ->
          case extract_value(stored_data) do
            {value, _current_expires_at} ->
              new_expires_at = now + ttl_seconds
              new_stored_data = format_value(value, new_expires_at)

              case :ets.insert(:concord_store, {key, new_stored_data}) do
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
end
