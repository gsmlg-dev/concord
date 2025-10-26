defmodule Concord.StateMachine do
  @moduledoc """
  The Raft state machine for Concord.
  Implements the :ra_machine behavior to provide a replicated key-value store
  with optional TTL (Time-To-Live) support.
  """

  @behaviour :ra_machine

  # Utility functions for TTL handling
  defp format_value(value, expires_at) do
    %{
      value: value,
      expires_at: expires_at
    }
  end

  defp extract_value(%{value: value, expires_at: expires_at}), do: {value, expires_at}
  # Legacy tuple format
  defp extract_value({value, expires_at}) when is_integer(expires_at), do: {value, expires_at}
  # Backward compatibility
  defp extract_value(value), do: {value, nil}

  # No expiration
  defp expired?(nil), do: false

  defp expired?(expires_at) do
    System.system_time(:second) > expires_at
  end

  defp current_timestamp, do: System.system_time(:second)

  @impl :ra_machine
  def init(_config) do
    # Create the ETS table with a known name
    _table = :ets.new(:concord_store, [:set, :public, :named_table])
    # Return simple state similar to ra_machine_simple
    # data map will store index definitions: %{index_name => extractor_function}
    {:concord_kv, %{indexes: %{}}}
  end

  def apply_command(meta, {:put, key, value}, {:concord_kv, data}) do
    # Handle backward compatibility - existing puts without TTL
    apply_command(meta, {:put, key, value, nil}, {:concord_kv, data})
  end

  def apply_command(meta, {:put, key, value, expires_at}, {:concord_kv, data}) do
    start_time = System.monotonic_time()

    # Get old value if it exists (for index updates)
    old_value =
      case :ets.lookup(:concord_store, key) do
        [{^key, stored_data}] ->
          case extract_value(stored_data) do
            {val, _expires} -> Concord.Compression.decompress(val)
            _ -> nil
          end

        [] ->
          nil
      end

    # Insert new value
    formatted_value = format_value(value, expires_at)
    :ets.insert(:concord_store, {key, formatted_value})

    # Update indexes
    indexes = Map.get(data, :indexes, %{})
    decompressed_value = Concord.Compression.decompress(value)

    Enum.each(indexes, fn {index_name, extractor} ->
      table_name = Concord.Index.index_table_name(index_name)

      # Remove old value from index if it exists
      if old_value != nil do
        Concord.Index.remove_from_index(table_name, key, old_value, extractor)
      end

      # Add new value to index
      Concord.Index.index_value(table_name, key, decompressed_value, extractor)
    end)

    # Emit telemetry
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{
        operation: :put,
        key: key,
        index: Map.get(meta, :index),
        has_ttl: expires_at != nil
      }
    )

    {{:concord_kv, data}, :ok, []}
  end

  def apply_command(meta, {:delete, key}, {:concord_kv, data}) do
    start_time = System.monotonic_time()

    # Get value before deleting (for index updates)
    old_value =
      case :ets.lookup(:concord_store, key) do
        [{^key, stored_data}] ->
          case extract_value(stored_data) do
            {val, _expires} -> Concord.Compression.decompress(val)
            _ -> nil
          end

        [] ->
          nil
      end

    # Delete from main store
    :ets.delete(:concord_store, key)

    # Remove from indexes
    if old_value != nil do
      indexes = Map.get(data, :indexes, %{})

      Enum.each(indexes, fn {index_name, extractor} ->
        table_name = Concord.Index.index_table_name(index_name)
        Concord.Index.remove_from_index(table_name, key, old_value, extractor)
      end)
    end

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :delete, key: key, index: Map.get(meta, :index)}
    )

    {{:concord_kv, data}, :ok, []}
  end

  def apply_command(
        meta,
        {:put_if, key, value, expires_at, expected, condition_fn},
        {:concord_kv, data}
      ) do
    start_time = System.monotonic_time()

    result =
      case :ets.lookup(:concord_store, key) do
        [{^key, stored_data}] ->
          case extract_value(stored_data) do
            {current_value, current_expires_at} ->
              if expired?(current_expires_at) do
                {:error, :not_found}
              else
                # Check condition
                condition_met =
                  cond do
                    expected != nil ->
                      Concord.Compression.decompress(current_value) == expected

                    condition_fn != nil ->
                      condition_fn.(Concord.Compression.decompress(current_value))

                    true ->
                      false
                  end

                if condition_met do
                  formatted_value = format_value(value, expires_at)
                  :ets.insert(:concord_store, {key, formatted_value})
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
      %{
        operation: :put_if,
        key: key,
        index: Map.get(meta, :index),
        result: result
      }
    )

    {{:concord_kv, data}, result, []}
  end

  def apply_command(meta, {:delete_if, key, expected, condition_fn}, {:concord_kv, data}) do
    start_time = System.monotonic_time()

    result =
      case :ets.lookup(:concord_store, key) do
        [{^key, stored_data}] ->
          case extract_value(stored_data) do
            {current_value, current_expires_at} ->
              if expired?(current_expires_at) do
                {:error, :not_found}
              else
                # Check condition
                condition_met =
                  cond do
                    expected != nil ->
                      Concord.Compression.decompress(current_value) == expected

                    condition_fn != nil ->
                      condition_fn.(Concord.Compression.decompress(current_value))

                    true ->
                      false
                  end

                if condition_met do
                  :ets.delete(:concord_store, key)
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
      %{
        operation: :delete_if,
        key: key,
        index: Map.get(meta, :index),
        result: result
      }
    )

    {{:concord_kv, data}, result, []}
  end

  def apply_command(meta, {:touch, key, additional_ttl_seconds}, {:concord_kv, data}) do
    start_time = System.monotonic_time()

    result =
      case :ets.lookup(:concord_store, key) do
        [{^key, stored_data}] ->
          case extract_value(stored_data) do
            {value, _current_expires_at} ->
              new_expires_at = current_timestamp() + additional_ttl_seconds
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
      %{
        operation: :touch,
        key: key,
        index: Map.get(meta, :index),
        result: result
      }
    )

    {{:concord_kv, data}, result, []}
  end

  def apply_command(meta, :cleanup_expired, {:concord_kv, data}) do
    start_time = System.monotonic_time()

    # Get all keys and check expiration manually (ETS select doesn't support map patterns)
    all_keys = :ets.select(:concord_store, [{{:"$1", :"$2"}, [], [:"$1"]}])

    expired_keys =
      Enum.filter(all_keys, fn key ->
        case :ets.lookup(:concord_store, key) do
          [{^key, stored_data}] ->
            case extract_value(stored_data) do
              {_value, expires_at} -> expired?(expires_at)
              _ -> false
            end

          [] ->
            false
        end
      end)

    # Delete expired keys in batch
    deleted_count =
      Enum.reduce(expired_keys, 0, fn key, acc ->
        case :ets.delete(:concord_store, key) do
          true -> acc + 1
          false -> acc
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
        scanned_keys: length(all_keys)
      }
    )

    {{:concord_kv, data}, {:ok, deleted_count}, []}
  end

  def apply_command(meta, {:put_many, operations}, {:concord_kv, data})
      when is_list(operations) do
    start_time = System.monotonic_time()

    # Pre-validate all operations
    validation_result = validate_put_many_operations(operations)

    case validation_result do
      :ok ->
        # All operations valid, proceed with atomic batch
        results = execute_put_many_batch(operations)

        # Check if all operations succeeded
        case Enum.find(results, fn {status, _} -> status == :error end) do
          nil ->
            # All succeeded, emit telemetry and return success
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
            # Some failed, this should not happen with our validation, but handle gracefully
            {{:concord_kv, data}, {:error, :partial_failure}, []}
        end

      {:error, reason} ->
        # Validation failed, no changes made
        {{:concord_kv, data}, {:error, reason}, []}
    end
  end

  def apply_command(meta, {:get_many, keys}, {:concord_kv, data}) when is_list(keys) do
    start_time = System.monotonic_time()

    results =
      Enum.map(keys, fn key ->
        case :ets.lookup(:concord_store, key) do
          [{^key, stored_data}] ->
            case extract_value(stored_data) do
              {value, expires_at} ->
                if expired?(expires_at) do
                  {key, {:error, :not_found}}
                else
                  {key, {:ok, value}}
                end

              _ ->
                {key, {:error, :invalid_stored_format}}
            end

          [] ->
            {key, {:error, :not_found}}
        end
      end)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{
        operation: :get_many,
        index: Map.get(meta, :index),
        batch_size: length(keys)
      }
    )

    {{:concord_kv, data}, {:ok, results}, []}
  end

  def apply_command(meta, {:delete_many, keys}, {:concord_kv, data}) when is_list(keys) do
    start_time = System.monotonic_time()

    # Pre-validate all keys
    case validate_delete_many_operations(keys) do
      :ok ->
        # All keys valid, proceed with atomic batch
        results = execute_delete_many_batch(keys)

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

    # Pre-validate all operations
    validation_result = validate_touch_many_operations(operations)

    case validation_result do
      :ok ->
        # All operations valid, proceed with atomic batch
        results = execute_touch_many_batch(operations)

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

  # Secondary Index Commands

  def apply_command(_meta, {:create_index, name, extractor}, {:concord_kv, data}) do
    indexes = Map.get(data, :indexes, %{})

    if Map.has_key?(indexes, name) do
      {{:concord_kv, data}, {:error, :index_exists}, []}
    else
      # Create ETS table for this index
      table_name = Concord.Index.index_table_name(name)
      :ets.new(table_name, [:set, :public, :named_table])

      # Store index definition
      new_indexes = Map.put(indexes, name, extractor)
      new_data = Map.put(data, :indexes, new_indexes)

      {{:concord_kv, new_data}, :ok, []}
    end
  end

  def apply_command(_meta, {:drop_index, name}, {:concord_kv, data}) do
    indexes = Map.get(data, :indexes, %{})

    if Map.has_key?(indexes, name) do
      # Delete ETS table
      table_name = Concord.Index.index_table_name(name)

      if :ets.whereis(table_name) != :undefined do
        :ets.delete(table_name)
      end

      # Remove index definition
      new_indexes = Map.delete(indexes, name)
      new_data = Map.put(data, :indexes, new_indexes)

      {{:concord_kv, new_data}, :ok, []}
    else
      {{:concord_kv, data}, {:error, :not_found}, []}
    end
  end

  # Catch-all for unknown commands (e.g., internal ra commands)
  def apply_command(meta, command, {:concord_kv, data}) do
    # Log the unknown command for debugging
    :telemetry.execute(
      [:concord, :operation, :unknown_command],
      %{command: inspect(command)},
      %{index: Map.get(meta, :index)}
    )

    {{:concord_kv, data}, :ok, []}
  end

  # Backward compatibility wrapper
  @impl :ra_machine
  def apply(meta, command, data) do
    apply_command(meta, command, data)
  end

  @impl :ra_machine
  def state_enter(status, {:concord_kv, _data}) do
    :telemetry.execute(
      [:concord, :state, :change],
      %{timestamp: System.system_time()},
      %{status: status, node: node()}
    )

    []
  end

  def query({:get, key}, {:concord_kv, _data}) do
    case :ets.lookup(:concord_store, key) do
      [{^key, stored_data}] ->
        case extract_value(stored_data) do
          {value, expires_at} ->
            if expired?(expires_at) do
              # Key has expired, return not found
              {:error, :not_found}
            else
              {:ok, value}
            end

          _ ->
            {:error, :invalid_stored_format}
        end

      [] ->
        {:error, :not_found}
    end
  end

  def query({:get_with_ttl, key}, {:concord_kv, _data}) do
    case :ets.lookup(:concord_store, key) do
      [{^key, stored_data}] ->
        case extract_value(stored_data) do
          {value, expires_at} ->
            if expired?(expires_at) do
              {:error, :not_found}
            else
              remaining_ttl =
                if expires_at do
                  max(0, expires_at - current_timestamp())
                else
                  nil
                end

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
    all = :ets.tab2list(:concord_store)

    # Filter out expired keys and extract values
    valid_entries =
      Enum.reduce(all, [], fn {key, stored_data}, acc ->
        case extract_value(stored_data) do
          {value, expires_at} ->
            if not expired?(expires_at) do
              [{key, value} | acc]
            else
              acc
            end

          _ ->
            acc
        end
      end)

    {:ok, Map.new(valid_entries)}
  end

  def query(:get_all_with_ttl, {:concord_kv, _data}) do
    all = :ets.tab2list(:concord_store)

    # Filter out expired keys and include TTL info
    valid_entries =
      Enum.reduce(all, [], fn {key, stored_data}, acc ->
        case extract_value(stored_data) do
          {value, expires_at} ->
            if not expired?(expires_at) do
              remaining_ttl =
                if expires_at do
                  max(0, expires_at - current_timestamp())
                else
                  nil
                end

              [{key, %{value: value, ttl: remaining_ttl}} | acc]
            else
              acc
            end

          _ ->
            acc
        end
      end)

    {:ok, Map.new(valid_entries)}
  end

  def query({:ttl, key}, {:concord_kv, _data}) do
    case :ets.lookup(:concord_store, key) do
      [{^key, stored_data}] ->
        case extract_value(stored_data) do
          {_value, expires_at} ->
            if expired?(expires_at) do
              {:error, :not_found}
            else
              if expires_at do
                remaining_ttl = max(0, expires_at - current_timestamp())
                {:ok, remaining_ttl}
              else
                # Key exists but has no TTL
                {:error, :no_ttl}
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
    results =
      Enum.map(keys, fn key ->
        case :ets.lookup(:concord_store, key) do
          [{^key, stored_data}] ->
            case extract_value(stored_data) do
              {value, expires_at} ->
                if expired?(expires_at) do
                  {key, {:error, :not_found}}
                else
                  {key, {:ok, value}}
                end

              _ ->
                {key, {:error, :invalid_stored_format}}
            end

          [] ->
            {key, {:error, :not_found}}
        end
      end)

    {:ok, Map.new(results)}
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
      table_name = Concord.Index.index_table_name(name)

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
    index_names = Map.keys(indexes)
    {:ok, index_names}
  end

  def query({:get_index_extractor, name}, {:concord_kv, data}) do
    indexes = Map.get(data, :indexes, %{})

    case Map.get(indexes, name) do
      nil -> {:ok, {:error, :not_found}}
      extractor -> {:ok, extractor}
    end
  end

  @impl :ra_machine
  def snapshot_installed(snapshot, _metadata, {:concord_kv, _data}, _aux) do
    :ets.delete_all_objects(:concord_store)

    Enum.each(snapshot, fn {k, v} ->
      :ets.insert(:concord_store, {k, v})
    end)

    :telemetry.execute(
      [:concord, :snapshot, :installed],
      %{size: length(snapshot)},
      %{node: node()}
    )

    []
  end

  def snapshot({:concord_kv, _data}) do
    data = :ets.tab2list(:concord_store)

    :telemetry.execute(
      [:concord, :snapshot, :created],
      %{size: length(data)},
      %{node: node()}
    )

    data
  end

  # Helper functions for batch operations

  defp validate_put_many_operations(operations) do
    if length(operations) > 500 do
      {:error, :batch_too_large}
    else
      # Validate each operation
      case Enum.find_value(operations, fn operation ->
             case validate_put_operation(operation) do
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
    if byte_size(key) == 0 do
      {:error, :invalid_key}
    else
      :ok
    end
  end

  defp validate_put_operation(_) do
    {:error, :invalid_operation_format}
  end

  defp execute_put_many_batch(operations) do
    Enum.map(operations, fn operation ->
      case operation do
        {key, value, expires_at} ->
          formatted_value = format_value(value, expires_at)

          case :ets.insert(:concord_store, {key, formatted_value}) do
            true -> {key, :ok}
            _ -> {key, {:error, :insert_failed}}
          end

        {key, value} ->
          execute_put_many_batch([{key, value, nil}])
          |> hd()

        _ ->
          {:error, :invalid_operation_format}
      end
    end)
  end

  defp validate_delete_many_operations(keys) do
    if length(keys) > 500 do
      {:error, :batch_too_large}
    else
      # Validate each key
      case Enum.find(keys, fn key ->
             not (is_binary(key) and byte_size(key) > 0)
           end) do
        nil -> :ok
        _ -> {:error, :invalid_key}
      end
    end
  end

  defp execute_delete_many_batch(keys) do
    Enum.map(keys, fn key ->
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
      # Validate each operation
      case Enum.find_value(operations, fn operation ->
             case validate_touch_operation(operation) do
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
       when is_binary(key) and byte_size(key) > 0 and is_integer(ttl_seconds) and ttl_seconds > 0 do
    :ok
  end

  defp validate_touch_operation(_) do
    {:error, :invalid_touch_operation}
  end

  defp execute_touch_many_batch(operations) do
    Enum.map(operations, fn {key, ttl_seconds} ->
      case :ets.lookup(:concord_store, key) do
        [{^key, stored_data}] ->
          case extract_value(stored_data) do
            {value, _current_expires_at} ->
              new_expires_at = current_timestamp() + ttl_seconds
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

  @impl :ra_machine
  def version, do: 2
end
