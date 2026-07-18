defmodule ViewstampedReplication.Storage.File do
  @moduledoc """
  Checksummed write-ahead log and atomic checkpoint storage.

  Recovery ignores WAL records already represented by the checkpoint. A
  partial or corrupt WAL tail is truncated to the last checksummed record.
  """

  @behaviour ViewstampedReplication.Storage

  alias ViewstampedReplication.Storage.Memory

  @magic "VSRW"
  @version 1
  @header_size byte_size(@magic) + 1 + 8 + 4
  @max_record_size 256 * 1024 * 1024
  @wal_name "replica.wal"
  @checkpoint_name "checkpoint.vsr"

  @enforce_keys [:directory, :wal_path, :checkpoint_path, :memory]
  defstruct [:directory, :wal_path, :checkpoint_path, :memory, sequence: 0]

  @impl true
  def open(opts) do
    with {:ok, directory} <- Keyword.fetch(opts, :path),
         {:ok, memory} <- Memory.open(opts),
         :ok <- File.mkdir_p(directory),
         :ok <- ensure_file(Path.join(directory, @wal_name)) do
      {:ok,
       %__MODULE__{
         directory: directory,
         wal_path: Path.join(directory, @wal_name),
         checkpoint_path: Path.join(directory, @checkpoint_name),
         memory: memory
       }}
    else
      :error -> {:error, :storage_path_required}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def recover(%__MODULE__{} = state) do
    with {:ok, checkpoint_sequence, memory} <- read_checkpoint(state),
         {:ok, records, valid_bytes} <- read_wal(state.wal_path),
         :ok <- truncate_tail(state.wal_path, valid_bytes),
         {:ok, sequence, recovered_memory} <-
           replay(records, checkpoint_sequence, memory),
         :ok <- validate_identity(state.memory, recovered_memory),
         {:ok, recovered, recovered_memory} <- Memory.recover(recovered_memory) do
      {:ok, Map.put(recovered, :durable, true),
       %{state | memory: recovered_memory, sequence: sequence}}
    end
  end

  @impl true
  def persist_hard_state(%__MODULE__{} = state, hard_state) when is_map(hard_state),
    do: persist(state, {:hard_state, hard_state})

  @impl true
  def append(%__MODULE__{} = state, entries), do: persist(state, {:append, List.wrap(entries)})

  @impl true
  def truncate_suffix(%__MODULE__{} = state, last_op_number),
    do: persist(state, {:truncate_suffix, last_op_number})

  @impl true
  def set_commit_number(%__MODULE__{} = state, commit_number),
    do: persist(state, {:commit_number, commit_number})

  @impl true
  def set_applied(%__MODULE__{} = state, applied_number, client_table),
    do: persist(state, {:applied, applied_number, client_table})

  @impl true
  def write_snapshot(%__MODULE__{} = state, snapshot) do
    with {:ok, updated} <- persist(state, {:snapshot, snapshot}),
         :ok <- write_checkpoint(updated) do
      {:ok, updated}
    end
  end

  @impl true
  def install_snapshot(%__MODULE__{} = state, snapshot) do
    with {:ok, updated} <- persist(state, {:install_snapshot, snapshot}),
         :ok <- write_checkpoint(updated) do
      {:ok, updated}
    end
  end

  @impl true
  def install_state(%__MODULE__{} = state, durable_state),
    do: persist(state, {:install_state, durable_state})

  @impl true
  def close(%__MODULE__{}), do: :ok

  defp persist(state, operation) do
    next_sequence = state.sequence + 1

    with {:ok, memory} <- apply_operation(state.memory, operation),
         :ok <- append_record(state.wal_path, {next_sequence, operation}) do
      {:ok, %{state | memory: memory, sequence: next_sequence}}
    end
  end

  defp replay(records, checkpoint_sequence, memory) do
    Enum.reduce_while(records, {:ok, checkpoint_sequence, memory}, fn
      {sequence, _operation}, {:ok, current, memory} when sequence <= checkpoint_sequence ->
        {:cont, {:ok, max(current, sequence), memory}}

      {sequence, operation}, {:ok, current, memory} when sequence == current + 1 ->
        case apply_operation(memory, operation) do
          {:ok, updated} -> {:cont, {:ok, sequence, updated}}
          {:error, reason} -> {:halt, {:error, {:invalid_wal_operation, sequence, reason}}}
        end

      {sequence, _operation}, {:ok, current, _memory} ->
        {:halt, {:error, {:non_contiguous_wal_sequence, current + 1, sequence}}}
    end)
  end

  defp apply_operation(memory, {:hard_state, hard_state}),
    do: Memory.persist_hard_state(memory, hard_state)

  defp apply_operation(memory, {:append, entries}), do: Memory.append(memory, entries)

  defp apply_operation(memory, {:truncate_suffix, last_op_number}),
    do: Memory.truncate_suffix(memory, last_op_number)

  defp apply_operation(memory, {:commit_number, commit_number}),
    do: Memory.set_commit_number(memory, commit_number)

  defp apply_operation(memory, {:applied, applied_number, client_table}),
    do: Memory.set_applied(memory, applied_number, client_table)

  defp apply_operation(memory, {:snapshot, snapshot}), do: Memory.write_snapshot(memory, snapshot)

  defp apply_operation(memory, {:install_snapshot, snapshot}),
    do: Memory.install_snapshot(memory, snapshot)

  defp apply_operation(memory, {:install_state, durable_state}),
    do: Memory.install_state(memory, durable_state)

  defp apply_operation(_memory, operation), do: {:error, {:unknown_storage_operation, operation}}

  defp append_record(path, term) do
    encoded = encode(term)

    with {:ok, file} <- :file.open(String.to_charlist(path), [:append, :binary, :raw]) do
      result =
        with :ok <- :file.write(file, encoded),
             :ok <- :file.sync(file) do
          :ok
        end

      :ok = :file.close(file)
      result
    end
  end

  defp write_checkpoint(state) do
    payload = {state.sequence, state.memory}
    temporary = state.checkpoint_path <> ".tmp"

    with :ok <- File.write(temporary, encode(payload), [:binary, :sync]),
         :ok <- File.rename(temporary, state.checkpoint_path),
         :ok <- sync_directory(state.directory) do
      :ok
    end
  end

  defp read_checkpoint(state) do
    case File.read(state.checkpoint_path) do
      {:ok, binary} ->
        with {:ok, {sequence, %Memory{} = memory}, consumed} <- decode_one(binary),
             true <- consumed == byte_size(binary) or {:error, :checkpoint_trailing_bytes} do
          {:ok, sequence, memory}
        else
          {:error, reason} -> {:error, {:invalid_checkpoint, reason}}
        end

      {:error, :enoent} ->
        {:ok, 0, state.memory}

      {:error, reason} ->
        {:error, {:checkpoint_read_failed, reason}}
    end
  end

  defp read_wal(path) do
    with {:ok, binary} <- File.read(path) do
      decode_records(binary, [], 0)
    end
  end

  defp decode_records(<<>>, records, valid_bytes),
    do: {:ok, Enum.reverse(records), valid_bytes}

  defp decode_records(binary, records, valid_bytes) do
    case decode_one(binary) do
      {:ok, record, consumed} ->
        <<_record::binary-size(consumed), rest::binary>> = binary
        decode_records(rest, [record | records], valid_bytes + consumed)

      {:error, _tail_reason} ->
        {:ok, Enum.reverse(records), valid_bytes}
    end
  end

  defp encode(term) do
    payload = :erlang.term_to_binary(term, [:deterministic])
    checksum = :erlang.crc32(payload)

    <<@magic, @version, byte_size(payload)::unsigned-big-64, checksum::unsigned-big-32,
      payload::binary>>
  end

  defp decode_one(
         <<@magic, @version, length::unsigned-big-64, checksum::unsigned-big-32, rest::binary>>
       )
       when length <= @max_record_size and byte_size(rest) >= length do
    <<payload::binary-size(length), _tail::binary>> = rest

    if :erlang.crc32(payload) == checksum do
      try do
        {:ok, :erlang.binary_to_term(payload, [:safe]), @header_size + length}
      rescue
        ArgumentError -> {:error, :invalid_term}
      end
    else
      {:error, :checksum_mismatch}
    end
  end

  defp decode_one(_binary), do: {:error, :partial_or_invalid_record}

  defp truncate_tail(path, valid_bytes) do
    with {:ok, stat} <- File.stat(path) do
      if stat.size == valid_bytes do
        :ok
      else
        with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :write, :binary, :raw]),
             {:ok, _position} <- :file.position(file, valid_bytes),
             :ok <- :file.truncate(file),
             :ok <- :file.sync(file) do
          :file.close(file)
        end
      end
    end
  end

  defp validate_identity(expected, recovered) do
    cond do
      expected.configuration_hash != recovered.configuration_hash ->
        {:error, :configuration_hash_mismatch}

      expected.replica_id != recovered.replica_id ->
        {:error, :replica_id_mismatch}

      true ->
        :ok
    end
  end

  defp ensure_file(path) do
    case File.open(path, [:append, :binary]) do
      {:ok, file} -> File.close(file)
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_directory(directory) do
    with {:ok, file} <- :file.open(String.to_charlist(directory), [:read, :directory]) do
      result = :file.sync(file)
      :ok = :file.close(file)
      result
    end
  end
end
