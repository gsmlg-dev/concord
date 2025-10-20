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
  defp extract_value(value), do: {value, nil}  # Backward compatibility

  defp is_expired?(nil), do: false  # No expiration
  defp is_expired?(expires_at) do
    System.system_time(:second) > expires_at
  end

  defp current_timestamp, do: System.system_time(:second)

  @impl :ra_machine
  def init(_config) do
    # Create the ETS table with a known name
    _table = :ets.new(:concord_store, [:set, :public, :named_table])
    # Return simple state similar to ra_machine_simple
    {:concord_kv, %{}}
  end

  def apply_command(meta, {:put, key, value}, {:concord_kv, data}) do
    # Handle backward compatibility - existing puts without TTL
    apply_command(meta, {:put, key, value, nil}, {:concord_kv, data})
  end

  def apply_command(meta, {:put, key, value, expires_at}, {:concord_kv, data}) do
    start_time = System.monotonic_time()
    formatted_value = format_value(value, expires_at)
    :ets.insert(:concord_store, {key, formatted_value})

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
    :ets.delete(:concord_store, key)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:concord, :operation, :apply],
      %{duration: duration},
      %{operation: :delete, key: key, index: Map.get(meta, :index)}
    )

    {{:concord_kv, data}, :ok, []}
  end

  def apply_command(meta, {:touch, key, additional_ttl_seconds}, {:concord_kv, data}) do
    start_time = System.monotonic_time()

    result = case :ets.lookup(:concord_store, key) do
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
    current_time = current_timestamp()

    # Match pattern for expired entries
    expired_match = {
      :"$1",
      %{value: :"$2", expires_at: :"$3"}
    }

    guards = {:andalso, {:">", :"$3", 0}, {"<", :"$3", current_time}}

    # Select all expired keys
    expired_keys = :ets.select(:concord_store, [
      {expired_match, guards, [:"$1"]}
    ])

    # Delete expired keys in batch
    deleted_count = Enum.reduce(expired_keys, 0, fn key, acc ->
      case :ets.delete(:concord_store, key) do
        :ok -> acc + 1
        _ -> acc
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
        scanned_keys: length(expired_keys)
      }
    )

    {{:concord_kv, data}, {:ok, deleted_count}, []}
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
            if is_expired?(expires_at) do
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
            if is_expired?(expires_at) do
              {:error, :not_found}
            else
              remaining_ttl = if expires_at do
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
    valid_entries = Enum.reduce(all, [], fn {key, stored_data}, acc ->
      case extract_value(stored_data) do
        {value, expires_at} ->
          if not is_expired?(expires_at) do
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
    valid_entries = Enum.reduce(all, [], fn {key, stored_data}, acc ->
      case extract_value(stored_data) do
        {value, expires_at} ->
          if not is_expired?(expires_at) do
            remaining_ttl = if expires_at do
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
            if is_expired?(expires_at) do
              {:error, :not_found}
            else
              remaining_ttl = if expires_at do
                max(0, expires_at - current_timestamp())
              else
                nil
              end
              {:ok, remaining_ttl}
            end

          _ ->
            {:error, :invalid_stored_format}
        end

      [] ->
        {:error, :not_found}
    end
  end

  def query(:stats, {:concord_kv, _data}) do
    info = :ets.info(:concord_store)

    {:ok,
     %{
       size: Keyword.get(info, :size, 0),
       memory: Keyword.get(info, :memory, 0)
     }}
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

  @impl :ra_machine
  def version, do: 1
end
