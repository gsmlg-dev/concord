defmodule Concord.Engine.Turso do
  @moduledoc """
  Turso-backed Concord KV engine.

  This engine persists Concord records into a local Turso database through
  `ex_turso`. It is intentionally node-local and does not provide Raft
  consensus, cluster membership, leases, watches, or secondary indexes.
  """

  @behaviour Concord.Engine

  alias Concord.Compression
  alias Concord.KV.Record
  alias Concord.Turso
  alias Concord.Turso.{Codec, Migrations}
  alias Concord.Txn.Result, as: TxnResult

  @db Concord.Turso.DB
  @default_timeout 5_000
  @prefix_upper_bound <<0xF4, 0x8F, 0xBF, 0xBF>>

  @impl true
  def command(command, opts \\ [])

  def command({:put, key, value, %{} = put_opts}, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with_transaction(timeout, fn conn ->
      expires_at = ttl_to_expires_at(Map.get(put_opts, :ttl), now_seconds())
      put_record(conn, key, value, expires_at, put_opts, :revisioned)
    end)
  end

  def command({:put, key, value, expires_at}, opts)
      when is_integer(expires_at) or is_nil(expires_at) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with_transaction(timeout, fn conn ->
      put_record(conn, key, value, expires_at, %{}, :legacy)
    end)
  end

  def command({:delete, key, %{} = delete_opts}, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with_transaction(timeout, fn conn ->
      delete_key(conn, key, Map.get(delete_opts, :prev_kv, false), :revisioned)
    end)
  end

  def command({:delete, key}, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with_transaction(timeout, fn conn ->
      delete_key(conn, key, false, :legacy)
    end)
  end

  def command({:put_if, key, value, expires_at, expected}, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with_transaction(timeout, fn conn ->
      now = now_seconds()

      case fetch_visible_current(conn, key, now) do
        {:ok, %Record{} = record} ->
          if Compression.decompress(record.value) == expected do
            put_record(conn, key, value, expires_at, %{}, :legacy)
          else
            {:ok, {:error, :condition_failed}}
          end

        {:ok, nil} ->
          {:ok, {:error, :not_found}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  def command({:delete_if, key, expected, _condition_fn}, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with_transaction(timeout, fn conn ->
      now = now_seconds()

      case fetch_visible_current(conn, key, now) do
        {:ok, %Record{} = record} ->
          if Compression.decompress(record.value) == expected do
            delete_key(conn, key, false, :legacy)
          else
            {:ok, {:error, :condition_failed}}
          end

        {:ok, nil} ->
          {:ok, {:error, :not_found}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  def command({:touch, key, ttl_seconds}, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with_transaction(timeout, fn conn ->
      touch_key(conn, key, ttl_seconds, :legacy)
    end)
  end

  def command({:put_many, operations}, opts) when is_list(operations) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with_transaction(timeout, fn conn ->
      Enum.reduce_while(operations, {:ok, []}, fn
        {key, value, expires_at}, {:ok, acc} ->
          case put_record(conn, key, value, expires_at, %{}, :batch) do
            {:ok, :ok} -> {:cont, {:ok, [{key, :ok} | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {key, value}, {:ok, acc} ->
          case put_record(conn, key, value, nil, %{}, :batch) do
            {:ok, :ok} -> {:cont, {:ok, [{key, :ok} | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end)
      |> case do
        {:ok, results} -> {:ok, {:ok, Enum.reverse(results)}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def command({:delete_many, keys}, opts) when is_list(keys) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with_transaction(timeout, fn conn ->
      Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
        case delete_key(conn, key, false, :batch) do
          {:ok, :ok} -> {:cont, {:ok, [{key, :ok} | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, results} -> {:ok, {:ok, Enum.reverse(results)}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def command({:touch_many, operations}, opts) when is_list(operations) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with_transaction(timeout, fn conn ->
      Enum.reduce_while(operations, {:ok, []}, fn {key, ttl_seconds}, {:ok, acc} ->
        case touch_key(conn, key, ttl_seconds, :batch) do
          {:ok, :ok} -> {:cont, {:ok, [{key, :ok} | acc]}}
          {:ok, {:error, reason}} -> {:cont, {:ok, [{key, {:error, reason}} | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, results} -> {:ok, {:ok, Enum.reverse(results)}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def command(:cleanup_expired, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with_transaction(timeout, fn conn ->
      now = now_seconds()

      with {:ok, rows} <-
             query_rows(conn, "SELECT key FROM concord_turso_current
               WHERE expires_at IS NOT NULL AND expires_at < ?", [now]),
           :ok <- execute(conn, "DELETE FROM concord_turso_current
               WHERE expires_at IS NOT NULL AND expires_at < ?", [now]) do
        {:ok, {:ok, length(rows)}}
      end
    end)
  end

  def command({:txn, spec}, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with_transaction(timeout, fn conn ->
      commit_txn(conn, spec)
    end)
  end

  def command(command, _opts), do: unsupported(command)

  @impl true
  def query(query, opts \\ [])

  def query({:get, key}, opts) do
    with_db(opts, fn conn ->
      case fetch_visible_current(conn, key, now_seconds()) do
        {:ok, %Record{} = record} -> {:ok, {:ok, record.value}}
        {:ok, nil} -> {:ok, {:error, :not_found}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def query({:get_with_ttl, key}, opts) do
    with_db(opts, fn conn ->
      now = now_seconds()

      case fetch_visible_current(conn, key, now) do
        {:ok, %Record{} = record} ->
          {:ok, {:ok, {record.value, remaining_ttl(record, now)}}}

        {:ok, nil} ->
          {:ok, {:error, :not_found}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  def query({:ttl, key}, opts) do
    with_db(opts, fn conn ->
      now = now_seconds()

      case fetch_visible_current(conn, key, now) do
        {:ok, %Record{} = record} -> {:ok, {:ok, remaining_ttl(record, now)}}
        {:ok, nil} -> {:ok, {:error, :not_found}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def query(:get_all, opts) do
    with_db(opts, fn conn ->
      with {:ok, records} <- current_records(conn, nil, nil, :all) do
        visible =
          records
          |> Enum.reject(fn {_key, record} -> hidden?(record, now_seconds()) end)
          |> Map.new(fn {key, record} -> {key, record.value} end)

        {:ok, {:ok, visible}}
      end
    end)
  end

  def query(:get_all_with_ttl, opts) do
    with_db(opts, fn conn ->
      now = now_seconds()

      with {:ok, records} <- current_records(conn, nil, nil, :all) do
        visible =
          records
          |> Enum.reject(fn {_key, record} -> hidden?(record, now) end)
          |> Map.new(fn {key, record} ->
            {key, %{value: record.value, ttl: remaining_ttl(record, now)}}
          end)

        {:ok, {:ok, visible}}
      end
    end)
  end

  def query({:get_many, keys}, opts) when is_list(keys) do
    with_db(opts, fn conn ->
      now = now_seconds()

      results =
        Enum.map(keys, fn key ->
          case fetch_visible_current(conn, key, now) do
            {:ok, %Record{} = record} -> {key, {:ok, record.value}}
            {:ok, nil} -> {key, {:error, :not_found}}
            {:error, reason} -> {key, {:error, reason}}
          end
        end)

      {:ok, {:ok, Map.new(results)}}
    end)
  end

  def query({:prefix_scan, prefix}, opts) when is_binary(prefix) do
    with_db(opts, fn conn ->
      now = now_seconds()
      {start_key, end_key} = prefix_range(prefix)

      with {:ok, records} <- current_records(conn, start_key, end_key, :all) do
        visible =
          records
          |> Enum.reject(fn {_key, record} -> hidden?(record, now) end)
          |> Enum.map(fn {key, record} -> {key, record.value} end)

        {:ok, {:ok, visible}}
      end
    end)
  end

  def query(:stats, opts) do
    with_db(opts, fn conn ->
      with {:ok, size} <- current_size(conn),
           {:ok, revision} <- current_revision(conn) do
        {:ok, {:ok, %{size: size, memory: nil, revision: revision}}}
      end
    end)
  end

  def query({:get_record, key}, opts) do
    with_db(opts, fn conn ->
      case fetch_visible_current(conn, key, now_seconds()) do
        {:ok, %Record{} = record} -> {:ok, {:ok, record}}
        {:ok, nil} -> {:ok, {:error, :not_found}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def query({:get, key, revision: revision}, opts) do
    with_db(opts, fn conn ->
      with {:ok, record} <- record_at_revision(conn, key, revision) do
        cond do
          is_nil(record) -> {:ok, {:error, :not_found}}
          Record.tombstone?(record) -> {:ok, {:error, :not_found}}
          true -> {:ok, {:ok, record.value}}
        end
      end
    end)
  end

  def query(:get_revision, opts) do
    with_db(opts, fn conn ->
      case current_revision(conn) do
        {:ok, revision} -> {:ok, {:ok, revision}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def query({:history, key, history_opts}, opts) do
    with_db(opts, fn conn ->
      from_revision = Keyword.get(history_opts, :from_revision, 0)
      limit = Keyword.get(history_opts, :limit, 100)

      with {:ok, to_revision} <- history_to_revision(conn, history_opts),
           {:ok, records} <- history_records(conn, key, from_revision, to_revision, limit),
           {:ok, current} <- fetch_current(conn, key) do
        current_records =
          case current do
            %Record{mod_revision: mod_revision} = record
            when mod_revision >= from_revision and mod_revision <= to_revision ->
              [record]

            _ ->
              []
          end

        result =
          (records ++ current_records)
          |> Enum.sort_by(& &1.mod_revision)
          |> Enum.take(limit)

        {:ok, {:ok, result}}
      end
    end)
  end

  def query({:list, selector, list_opts}, opts) do
    with_db(opts, fn conn ->
      limit = Map.get(list_opts, :limit, 1_000)
      keys_only = Map.get(list_opts, :keys_only, false)
      now = now_seconds()
      {start_key, end_key} = selector_range(selector)

      with {:ok, records} <- current_records(conn, start_key, end_key, limit + 1) do
        visible =
          records
          |> Enum.reject(fn {_key, record} -> hidden?(record, now) end)

        has_more = length(visible) > limit
        trimmed = Enum.take(visible, limit)

        result =
          Enum.map(trimmed, fn {key, record} ->
            value = if keys_only, do: nil, else: record.value
            record |> Map.put(:value, value) |> Map.put(:key, key)
          end)

        last_key =
          case List.last(trimmed) do
            {key, _record} -> key
            nil -> nil
          end

        {:ok, {:ok, result, %{has_more: has_more, last_key: last_key}}}
      end
    end)
  end

  def query(query, _opts), do: unsupported(query)

  @impl true
  def status(opts \\ []) do
    with_db(opts, fn conn ->
      with {:ok, size} <- current_size(conn),
           {:ok, revision} <- current_revision(conn) do
        {:ok,
         %{
           cluster: %{engine: :turso, members: [node()]},
           storage: %{size: size, revision: revision, database: database_path()},
           engine: :turso,
           node: node(),
           sync: sync_configured?()
         }}
      end
    end)
  end

  @impl true
  def members(opts \\ []) do
    with :ok <- ensure_ready(opts) do
      {:ok, [{:turso, node()}]}
    end
  end

  defp put_record(conn, key, value, expires_at, opts, return_style) do
    with {:ok, revision} <- bump_revision(conn),
         {:ok, result} <- put_record_at_revision(conn, key, value, expires_at, opts, revision) do
      case return_style do
        :legacy -> {:ok, :ok}
        :batch -> {:ok, :ok}
        :revisioned -> {:ok, result}
      end
    end
  end

  defp put_record_at_revision(conn, key, value, expires_at, opts, revision) do
    with {:ok, previous} <- fetch_current(conn, key) do
      with :ok <- maybe_insert_previous(conn, key, previous) do
        record = %Record{
          value: value,
          create_revision:
            if(previous && previous.version > 0,
              do: previous.create_revision,
              else: revision
            ),
          mod_revision: revision,
          version: if(previous && previous.version > 0, do: previous.version + 1, else: 1),
          expires_at: expires_at,
          lease_id: Map.get(opts, :lease),
          content_type: Map.get(opts, :content_type),
          metadata: Map.get(opts, :metadata, %{}) || %{}
        }

        with :ok <- upsert_current(conn, key, record) do
          {:ok, %{revision: revision, prev_kv: if(Map.get(opts, :prev_kv, false), do: previous)}}
        end
      end
    end
  end

  defp delete_key(conn, key, return_previous?, return_style) do
    with {:ok, previous} <- fetch_current(conn, key) do
      if previous && previous.version > 0 do
        with {:ok, revision} <- bump_revision(conn),
             :ok <- insert_history(conn, key, previous),
             :ok <- insert_history(conn, key, Record.tombstone(key, revision, previous)),
             :ok <- execute(conn, "DELETE FROM concord_turso_current WHERE key = ?", [key]) do
          result = %{revision: revision, prev_kv: if(return_previous?, do: previous)}
          delete_result(return_style, result)
        end
      else
        with {:ok, revision} <- current_revision(conn) do
          result = %{revision: revision, prev_kv: nil}
          delete_result(return_style, result)
        end
      end
    end
  end

  defp delete_result(:legacy, _result), do: {:ok, :ok}
  defp delete_result(:batch, _result), do: {:ok, :ok}
  defp delete_result(:revisioned, result), do: {:ok, result}

  defp touch_key(conn, key, ttl_seconds, return_style) do
    now = now_seconds()

    with {:ok, record} <- fetch_visible_current(conn, key, now) do
      case record do
        nil ->
          {:ok, {:error, :not_found}}

        %Record{} ->
          with {:ok, revision} <- bump_revision(conn) do
            updated = %{record | expires_at: now + ttl_seconds, mod_revision: revision}

            with :ok <- upsert_current(conn, key, updated) do
              case return_style do
                :legacy -> {:ok, :ok}
                :batch -> {:ok, :ok}
              end
            end
          end
      end
    end
  end

  defp commit_txn(conn, spec) do
    compares = Map.get(spec, :compare, [])
    success_ops = Map.get(spec, :success, [])
    failure_ops = Map.get(spec, :failure, [])
    now = now_seconds()

    with {:ok, compare_ok?} <- eval_compares(conn, compares, now),
         branch = if(compare_ok?, do: success_ops, else: failure_ops),
         mutating? = Enum.any?(branch, &mutating_op?/1),
         {:ok, revision} <- txn_revision(conn, mutating?) do
      Enum.reduce_while(branch, {:ok, []}, fn op, {:ok, responses} ->
        case execute_txn_op(conn, op, revision, now) do
          {:ok, response} -> {:cont, {:ok, [response | responses]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, responses} ->
          {:ok,
           {:ok,
            %TxnResult{
              succeeded: compare_ok?,
              revision: revision,
              responses: Enum.reverse(responses)
            }}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_txn_op(conn, {:get, {:key, key}, _opts}, _revision, now) do
    with {:ok, record} <- fetch_visible_current(conn, key, now) do
      kvs = if record, do: [record], else: []
      {:ok, {:get, {:key, key}, %{kvs: kvs, count: length(kvs)}}}
    end
  end

  defp execute_txn_op(conn, {:get, selector, opts}, _revision, now) do
    limit = Map.get(opts, :limit, 1_000)
    {start_key, end_key} = selector_range(selector)

    with {:ok, records} <- current_records(conn, start_key, end_key, limit) do
      kvs =
        records
        |> Enum.map(fn {_key, record} -> record end)
        |> Enum.reject(&hidden?(&1, now))
        |> Enum.sort_by(& &1.mod_revision)
        |> Enum.take(limit)

      {:ok, {:get, selector, %{kvs: kvs, count: length(kvs)}}}
    end
  end

  defp execute_txn_op(conn, {:put, key, value, opts}, revision, now) do
    expires_at = ttl_to_expires_at(Map.get(opts, :ttl), now)

    with {:ok, result} <- put_record_at_revision(conn, key, value, expires_at, opts, revision) do
      {:ok, {:put, key, %{prev_kv: result.prev_kv}}}
    end
  end

  defp execute_txn_op(conn, {:delete, selector, opts}, revision, _now) do
    return_previous? = Map.get(opts, :prev_kv, false)

    with {:ok, keys} <- keys_for_selector(conn, selector) do
      Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, previous_records} ->
        case delete_txn_key(conn, key, revision, return_previous?, previous_records) do
          {:ok, next_records} -> {:cont, {:ok, next_records}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, previous_records} ->
          {:ok,
           {:delete, selector, %{deleted: length(keys), prev_kvs: Enum.reverse(previous_records)}}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_txn_op(conn, {:touch, key, ttl_seconds, _opts}, revision, now) do
    with {:ok, record} <- fetch_visible_current(conn, key, now) do
      case record do
        nil ->
          {:ok, {:touch, key, %{ttl: :not_found}}}

        %Record{} ->
          updated = %{record | expires_at: now + ttl_seconds, mod_revision: revision}

          with :ok <- upsert_current(conn, key, updated) do
            {:ok, {:touch, key, %{ttl: ttl_seconds}}}
          end
      end
    end
  end

  defp execute_txn_op(_conn, op, _revision, _now), do: unsupported(op)

  defp delete_txn_key(conn, key, revision, return_previous?, previous_records) do
    with {:ok, previous} <- fetch_current(conn, key) do
      delete_existing_txn_key(conn, key, revision, return_previous?, previous, previous_records)
    end
  end

  defp delete_existing_txn_key(_conn, _key, _revision, _return_previous?, nil, previous_records),
    do: {:ok, previous_records}

  defp delete_existing_txn_key(
         _conn,
         _key,
         _revision,
         _return_previous?,
         %Record{version: version},
         previous_records
       )
       when version <= 0,
       do: {:ok, previous_records}

  defp delete_existing_txn_key(conn, key, revision, return_previous?, previous, previous_records) do
    tombstone = Record.tombstone(key, revision, previous)

    with :ok <- insert_history(conn, key, previous),
         :ok <- insert_history(conn, key, tombstone),
         :ok <- execute(conn, "DELETE FROM concord_turso_current WHERE key = ?", [key]) do
      if return_previous?, do: {:ok, [previous | previous_records]}, else: {:ok, previous_records}
    end
  end

  defp eval_compares(conn, compares, now) do
    Enum.reduce_while(compares, {:ok, true}, fn compare, {:ok, _result} ->
      case eval_compare(conn, compare, now) do
        {:ok, true} -> {:cont, {:ok, true}}
        {:ok, false} -> {:halt, {:ok, false}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp eval_compare(conn, {:exists, key, op, expected}, now) do
    with {:ok, record} <- fetch_visible_current(conn, key, now) do
      compare_values(op, record != nil, expected)
    end
  end

  defp eval_compare(conn, {:value, key, op, expected}, now) do
    with {:ok, value} <- compare_value(conn, key, now) do
      compare_values(op, value, expected)
    end
  end

  defp eval_compare(conn, {:field, key, path, op, expected}, now) do
    with {:ok, value} <- compare_value(conn, key, now) do
      compare_values(op, extract_field(value, path), expected)
    end
  end

  defp eval_compare(conn, {field, key, op, expected}, now)
       when field in [:version, :create_revision, :mod_revision, :lease] do
    default = if field == :lease, do: nil, else: 0
    record_field = if field == :lease, do: :lease_id, else: field

    with {:ok, record} <- fetch_visible_current(conn, key, now) do
      actual = if record, do: Map.get(record, record_field, default), else: default
      compare_values(op, actual, expected)
    end
  end

  defp eval_compare(conn, {:ttl, key, op, expected}, now) do
    with {:ok, record} <- fetch_visible_current(conn, key, now) do
      actual = if record, do: remaining_ttl(record, now), else: nil
      compare_values(op, actual, expected)
    end
  end

  defp eval_compare(_conn, _compare, _now), do: {:ok, false}

  defp compare_value(conn, key, now) do
    with {:ok, record} <- fetch_visible_current(conn, key, now) do
      value = if record, do: Compression.decompress(record.value)
      {:ok, value}
    end
  end

  defp compare_values(:==, actual, expected), do: {:ok, actual == expected}
  defp compare_values(:!=, actual, expected), do: {:ok, actual != expected}

  defp compare_values(:>, actual, expected) when is_number(actual) and is_number(expected),
    do: {:ok, actual > expected}

  defp compare_values(:>=, actual, expected) when is_number(actual) and is_number(expected),
    do: {:ok, actual >= expected}

  defp compare_values(:<, actual, expected) when is_number(actual) and is_number(expected),
    do: {:ok, actual < expected}

  defp compare_values(:<=, actual, expected) when is_number(actual) and is_number(expected),
    do: {:ok, actual <= expected}

  defp compare_values(_op, _actual, _expected), do: {:ok, false}

  defp extract_field(nil, _path), do: nil

  defp extract_field(value, path) when is_list(path) do
    Enum.reduce_while(path, value, fn
      key, acc when is_map(acc) -> {:cont, Map.get(acc, key)}
      _key, _acc -> {:halt, nil}
    end)
  end

  defp mutating_op?({:put, _, _, _}), do: true
  defp mutating_op?({:delete, _, _}), do: true
  defp mutating_op?({:touch, _, _, _}), do: true
  defp mutating_op?(_op), do: false

  defp txn_revision(conn, true), do: bump_revision(conn)
  defp txn_revision(conn, false), do: current_revision(conn)

  defp fetch_current(conn, key) do
    case query_rows(conn, "SELECT record FROM concord_turso_current WHERE key = ?", [key]) do
      {:ok, [%{"record" => record}]} -> {:ok, Codec.decode_record(record)}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_visible_current(conn, key, now) do
    with {:ok, record} <- fetch_current(conn, key) do
      if hidden?(record, now), do: {:ok, nil}, else: {:ok, record}
    end
  end

  defp current_records(conn, nil, nil, :all) do
    query_rows(conn, "SELECT key, record FROM concord_turso_current ORDER BY key")
    |> decode_record_rows()
  end

  defp current_records(conn, start_key, end_key, :all) do
    query_rows(conn, "SELECT key, record FROM concord_turso_current
      WHERE key >= ? AND key < ? ORDER BY key", [start_key, end_key])
    |> decode_record_rows()
  end

  defp current_records(conn, start_key, end_key, limit) do
    query_rows(conn, "SELECT key, record FROM concord_turso_current
      WHERE key >= ? AND key < ? ORDER BY key LIMIT ?", [start_key, end_key, limit])
    |> decode_record_rows()
  end

  defp decode_record_rows({:ok, rows}) do
    {:ok,
     Enum.map(rows, fn %{"key" => key, "record" => record} ->
       {key, Codec.decode_record(record)}
     end)}
  end

  defp decode_record_rows({:error, reason}), do: {:error, reason}

  defp record_at_revision(conn, key, revision) do
    with {:ok, current} <- fetch_current(conn, key) do
      if current && current.mod_revision <= revision do
        {:ok, current}
      else
        case query_rows(conn, "SELECT record FROM concord_turso_history
                 WHERE key = ? AND revision <= ? ORDER BY revision DESC LIMIT 1", [
               key,
               revision
             ]) do
          {:ok, [%{"record" => record}]} -> {:ok, Codec.decode_record(record)}
          {:ok, []} -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp history_records(conn, key, from_revision, to_revision, limit) do
    query_rows(conn, "SELECT record FROM concord_turso_history
      WHERE key = ? AND revision >= ? AND revision <= ?
      ORDER BY revision ASC LIMIT ?", [key, from_revision, to_revision, limit])
    |> case do
      {:ok, rows} ->
        {:ok, Enum.map(rows, fn %{"record" => record} -> Codec.decode_record(record) end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp history_to_revision(conn, opts) do
    case Keyword.fetch(opts, :to_revision) do
      {:ok, revision} -> {:ok, revision}
      :error -> current_revision(conn)
    end
  end

  defp keys_for_selector(_conn, {:key, key}), do: {:ok, [key]}

  defp keys_for_selector(conn, {:prefix, prefix}) do
    {start_key, end_key} = prefix_range(prefix)
    keys_in_range(conn, start_key, end_key)
  end

  defp keys_for_selector(conn, {:range, start_key, end_key}) do
    keys_in_range(conn, start_key, end_key)
  end

  defp keys_in_range(conn, start_key, end_key) do
    case query_rows(conn, "SELECT key FROM concord_turso_current
           WHERE key >= ? AND key < ? ORDER BY key", [start_key, end_key]) do
      {:ok, rows} -> {:ok, Enum.map(rows, &Map.fetch!(&1, "key"))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_current(conn, key, %Record{} = record) do
    execute(conn, "INSERT OR REPLACE INTO concord_turso_current
      (key, record, expires_at, mod_revision, version)
      VALUES (?, ?, ?, ?, ?)", [
      key,
      Codec.encode_record(record),
      record.expires_at,
      record.mod_revision,
      record.version
    ])
  end

  defp insert_history(conn, key, %Record{} = record) do
    execute(conn, "INSERT OR REPLACE INTO concord_turso_history
      (key, revision, record) VALUES (?, ?, ?)", [
      key,
      record.mod_revision,
      Codec.encode_record(record)
    ])
  end

  defp maybe_insert_previous(_conn, _key, nil), do: :ok

  defp maybe_insert_previous(conn, key, %Record{} = previous),
    do: insert_history(conn, key, previous)

  defp current_revision(conn) do
    case query_rows(conn, "SELECT value FROM concord_turso_meta WHERE name = 'revision'") do
      {:ok, [%{"value" => value}]} -> {:ok, value}
      {:ok, []} -> {:error, :missing_revision_counter}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bump_revision(conn) do
    with :ok <- execute(conn, "UPDATE concord_turso_meta SET value = value + 1
             WHERE name = 'revision'") do
      current_revision(conn)
    end
  end

  defp current_size(conn) do
    case query_rows(conn, "SELECT COUNT(*) AS count FROM concord_turso_current") do
      {:ok, [%{"count" => count}]} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_db(opts, fun) do
    with :ok <- ensure_ready(opts) do
      fun.(@db)
    end
  end

  defp with_transaction(timeout, fun) do
    with :ok <- ensure_ready(timeout: timeout) do
      case DBConnection.transaction(
             @db,
             fn conn ->
               case fun.(conn) do
                 {:ok, result} -> {:ok, result}
                 {:error, reason} -> DBConnection.rollback(conn, reason)
               end
             end,
             timeout: timeout
           ) do
        {:ok, {:ok, result}} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_ready(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    try do
      case Process.whereis(@db) do
        nil ->
          {:error, :engine_not_started}

        _pid ->
          case Migrations.migrate(@db) do
            :ok -> :ok
            {:error, reason} -> {:error, normalize_error(reason)}
          end
      end
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    after
      _ = timeout
    end
  end

  defp query_rows(conn, sql, params \\ []) do
    case ExTurso.query(conn, sql, params) do
      {:ok, %ExTurso.Result{rows: rows}} -> {:ok, rows}
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  defp execute(conn, sql, params \\ []) do
    case ExTurso.execute(conn, sql, params) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  defp unsupported(operation),
    do: {:error, {:unsupported_operation, :turso, operation_name(operation)}}

  defp operation_name({name, _}), do: name
  defp operation_name({name, _, _}), do: name
  defp operation_name({name, _, _, _}), do: name
  defp operation_name({name, _, _, _, _}), do: name
  defp operation_name(name) when is_atom(name), do: name
  defp operation_name(operation), do: operation

  defp normalize_error(%ExTurso.Error{code: code, message: message}) do
    {:turso_error, code || :error, message}
  end

  defp normalize_error(reason), do: reason

  defp hidden?(nil, _now), do: true

  defp hidden?(%Record{} = record, now),
    do: Record.tombstone?(record) or Record.expired?(record, now)

  defp remaining_ttl(%Record{expires_at: nil}, _now), do: nil
  defp remaining_ttl(%Record{expires_at: expires_at}, now), do: max(0, expires_at - now)

  defp ttl_to_expires_at(ttl, now) when is_integer(ttl) and ttl > 0, do: now + ttl
  defp ttl_to_expires_at(_ttl, _now), do: nil

  defp now_seconds, do: System.system_time(:second)

  defp selector_range({:prefix, prefix}), do: prefix_range(prefix)
  defp selector_range({:range, start_key, end_key}), do: {start_key, end_key}

  defp prefix_range(prefix), do: {prefix, prefix <> @prefix_upper_bound}

  defp database_path do
    Turso.pool_options() |> Keyword.fetch!(:database)
  end

  defp sync_configured? do
    opts = Turso.pool_options()
    Keyword.has_key?(opts, :remote_url) and Keyword.has_key?(opts, :auth_token)
  end
end
