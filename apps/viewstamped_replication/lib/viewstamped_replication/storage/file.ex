defmodule ViewstampedReplication.Storage.File do
  @moduledoc """
  Checksummed write-ahead log and atomic checkpoint storage.

  Recovery ignores WAL records already represented by the checkpoint. An
  incomplete final version-two WAL record is truncated to the last checksummed
  record. Complete records and ambiguous version-one tails that fail validation
  cause recovery to fail without modifying the WAL. Records are local trusted
  state: after their size and checksum are verified, ETF terms are decoded and
  their WAL or checkpoint structure is validated before use. Startup fsyncs
  every newly created directory entry and the WAL entry before the adapter can
  acknowledge replicated writes. WAL records and checkpoints use the same fixed
  256 MiB maximum ETF payload size for both writes and recovery.
  """

  @behaviour ViewstampedReplication.Storage

  alias ViewstampedReplication.{Log, LogEntry}
  alias ViewstampedReplication.Storage.Memory

  @magic "VSRW"
  @legacy_version 1
  @version 2
  @legacy_header_size byte_size(@magic) + 1 + 8 + 4
  @header_size byte_size(@magic) + 1 + 8 + 4 + 4
  @max_record_size 256 * 1024 * 1024
  @wal_name "replica.wal"
  @checkpoint_name "checkpoint.vsr"

  @enforce_keys [:directory, :wal_path, :checkpoint_path, :memory, :write_version]
  defstruct [:directory, :wal_path, :checkpoint_path, :memory, :write_version, sequence: 0]

  @impl true
  def open(opts) do
    with {:ok, configured_directory} <- Keyword.fetch(opts, :path),
         {:ok, write_version} <- write_version(opts),
         {:ok, memory} <- Memory.open(opts),
         {:ok, directory} <- ensure_storage_directory(configured_directory),
         :ok <- ensure_file(Path.join(directory, @wal_name)),
         :ok <- sync_directory(directory) do
      {:ok,
       %__MODULE__{
         directory: directory,
         wal_path: Path.join(directory, @wal_name),
         checkpoint_path: Path.join(directory, @checkpoint_name),
         memory: memory,
         write_version: write_version
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
         :ok <- validate_wal_sequences(records),
         :ok <- validate_checkpoint_sequence(records, checkpoint_sequence),
         {:ok, sequence, recovered_memory} <-
           replay(records, checkpoint_sequence, memory),
         :ok <- validate_identity(state.memory, recovered_memory),
         {:ok, recovered, recovered_memory} <- Memory.recover(recovered_memory),
         :ok <- truncate_tail(state.wal_path, valid_bytes) do
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
    persist_with_checkpoint(state, {:snapshot, snapshot})
  end

  @impl true
  def install_snapshot(%__MODULE__{} = state, snapshot) do
    persist_with_checkpoint(state, {:install_snapshot, snapshot})
  end

  @impl true
  def install_snapshot_state(%__MODULE__{} = state, snapshot, durable_state)
      when is_map(durable_state) do
    with {:ok, memory} <- Memory.install_snapshot_state(state.memory, snapshot, durable_state),
         updated = %{state | memory: memory},
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

    with {:ok, memory} <- apply_operation_safely(state.memory, operation),
         {:ok, encoded} <- encode({next_sequence, operation}, state.write_version),
         :ok <- append_record(state.wal_path, encoded) do
      {:ok, %{state | memory: memory, sequence: next_sequence}}
    end
  end

  defp persist_with_checkpoint(state, operation) do
    next_sequence = state.sequence + 1

    with {:ok, memory} <- apply_operation_safely(state.memory, operation),
         updated = %{state | memory: memory, sequence: next_sequence},
         {:ok, wal_record} <- encode({next_sequence, operation}, state.write_version),
         {:ok, checkpoint} <- encode({next_sequence, memory}, state.write_version),
         :ok <- append_record(state.wal_path, wal_record),
         :ok <- write_checkpoint(updated, checkpoint) do
      {:ok, updated}
    end
  end

  defp replay(records, checkpoint_sequence, memory) do
    Enum.reduce_while(records, {:ok, checkpoint_sequence, memory}, fn
      {sequence, _operation}, {:ok, current, memory} when sequence <= checkpoint_sequence ->
        {:cont, {:ok, max(current, sequence), memory}}

      {sequence, operation}, {:ok, current, memory} when sequence == current + 1 ->
        case apply_operation_safely(memory, operation) do
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

  defp apply_operation_safely(memory, operation) do
    apply_operation(memory, operation)
  rescue
    _error -> {:error, {:malformed_storage_operation, operation}}
  catch
    _kind, _reason -> {:error, {:malformed_storage_operation, operation}}
  end

  defp append_record(path, encoded) do
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

    with {:ok, encoded} <- encode(payload, state.write_version),
         :ok <- write_checkpoint(state, encoded) do
      :ok
    end
  end

  defp write_checkpoint(state, encoded) do
    temporary = state.checkpoint_path <> ".tmp"

    with :ok <- File.write(temporary, encoded, [:binary, :sync]),
         :ok <- File.rename(temporary, state.checkpoint_path),
         :ok <- sync_directory(state.directory) do
      :ok
    end
  end

  defp read_checkpoint(state) do
    case File.read(state.checkpoint_path) do
      {:ok, binary} ->
        with {:ok, payload, consumed} <- decode_one(binary),
             :ok <- validate_checkpoint_size(binary, consumed),
             {:ok, sequence, memory} <- validate_checkpoint_payload(payload) do
          {:ok, sequence, memory}
        else
          {:incomplete, reason} -> {:error, {:invalid_checkpoint, {:incomplete_record, reason}}}
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
        case validate_wal_record(record) do
          :ok ->
            <<_record::binary-size(^consumed), rest::binary>> = binary
            decode_records(rest, [record | records], valid_bytes + consumed)

          {:error, reason} ->
            {:error, {:invalid_wal_record, valid_bytes, reason}}
        end

      {:incomplete, _reason} ->
        {:ok, Enum.reverse(records), valid_bytes}

      {:error, reason} ->
        {:error, {:invalid_wal_record, valid_bytes, reason}}
    end
  end

  defp encode(term, @legacy_version) do
    with :ok <- validate_record_size(:erlang.external_size(term, [:deterministic])) do
      payload = :erlang.term_to_binary(term, [:deterministic])
      payload_checksum = :erlang.crc32(payload)

      {:ok,
       <<@magic, @legacy_version, byte_size(payload)::unsigned-big-64,
         payload_checksum::unsigned-big-32, payload::binary>>}
    end
  end

  defp encode(term, @version) do
    with :ok <- validate_record_size(:erlang.external_size(term, [:deterministic])) do
      payload = :erlang.term_to_binary(term, [:deterministic])
      length = byte_size(payload)
      header_checksum = header_checksum(@version, length)
      payload_checksum = :erlang.crc32(payload)

      {:ok,
       <<@magic, @version, length::unsigned-big-64, header_checksum::unsigned-big-32,
         payload_checksum::unsigned-big-32, payload::binary>>}
    end
  end

  defp validate_record_size(size) when size <= @max_record_size, do: :ok

  defp validate_record_size(size), do: {:error, {:record_too_large, size}}

  defp decode_one(binary) when byte_size(binary) < byte_size(@magic) do
    if binary == binary_part(@magic, 0, byte_size(binary)) do
      {:incomplete, :magic}
    else
      {:error, :invalid_magic}
    end
  end

  defp decode_one(<<magic::binary-size(4), _rest::binary>>) when magic != @magic,
    do: {:error, :invalid_magic}

  defp decode_one(<<@magic>>), do: {:incomplete, :version}

  defp decode_one(<<@magic, @legacy_version, rest::binary>>), do: decode_legacy(rest)
  defp decode_one(<<@magic, @version, rest::binary>>), do: decode_current(rest)

  defp decode_one(<<@magic, version, _rest::binary>>),
    do: {:error, {:unsupported_version, version}}

  defp decode_legacy(rest) when byte_size(rest) < 8,
    do: {:error, {:ambiguous_legacy_record, :length}}

  defp decode_legacy(<<length::unsigned-big-64, _rest::binary>>)
       when length > @max_record_size,
       do: {:error, {:record_too_large, length}}

  defp decode_legacy(<<_length::unsigned-big-64, rest::binary>>) when byte_size(rest) < 4,
    do: {:error, {:ambiguous_legacy_record, :checksum}}

  defp decode_legacy(<<length::unsigned-big-64, _checksum::unsigned-big-32, rest::binary>>)
       when byte_size(rest) < length,
       do: {:error, {:ambiguous_legacy_record, :payload}}

  defp decode_legacy(<<length::unsigned-big-64, checksum::unsigned-big-32, rest::binary>>) do
    decode_payload(rest, length, checksum, @legacy_header_size)
  end

  defp decode_current(rest) when byte_size(rest) < 8, do: {:incomplete, :length}

  defp decode_current(<<_length::unsigned-big-64, rest::binary>>) when byte_size(rest) < 4,
    do: {:incomplete, :header_checksum}

  defp decode_current(
         <<length::unsigned-big-64, encoded_header_checksum::unsigned-big-32, rest::binary>>
       ) do
    cond do
      encoded_header_checksum != header_checksum(@version, length) ->
        {:error, :header_checksum_mismatch}

      length > @max_record_size ->
        {:error, {:record_too_large, length}}

      byte_size(rest) < 4 ->
        {:incomplete, :payload_checksum}

      true ->
        decode_current_payload(rest, length)
    end
  end

  defp decode_current_payload(
         <<_payload_checksum::unsigned-big-32, rest::binary>>,
         length
       )
       when byte_size(rest) < length,
       do: {:incomplete, :payload}

  defp decode_current_payload(
         <<payload_checksum::unsigned-big-32, rest::binary>>,
         length
       ) do
    decode_payload(rest, length, payload_checksum, @header_size)
  end

  defp decode_payload(rest, length, checksum, header_size) do
    <<payload::binary-size(^length), _tail::binary>> = rest

    if :erlang.crc32(payload) == checksum do
      try do
        case :erlang.binary_to_term(payload, [:used]) do
          {term, ^length} -> {:ok, term, header_size + length}
          {_term, _used} -> {:error, :term_trailing_bytes}
        end
      rescue
        ArgumentError -> {:error, :invalid_term}
      end
    else
      {:error, :checksum_mismatch}
    end
  end

  defp header_checksum(version, length) do
    :erlang.crc32(<<version, length::unsigned-big-64>>)
  end

  defp validate_wal_record({sequence, _operation}) when is_integer(sequence) and sequence > 0,
    do: :ok

  defp validate_wal_record(_record), do: {:error, :invalid_record_structure}

  defp validate_checkpoint_size(binary, consumed) do
    if consumed == byte_size(binary), do: :ok, else: {:error, :checkpoint_trailing_bytes}
  end

  defp validate_checkpoint_payload(
         {sequence,
          %Memory{
            configuration_hash: _configuration_hash,
            replica_id: _replica_id,
            hard_state: hard_state,
            log: log,
            commit_number: _commit_number,
            applied_number: _applied_number,
            snapshot: _snapshot,
            client_table: client_table
          } = memory}
       )
       when is_integer(sequence) and sequence >= 0 do
    with {:ok, log} <- validate_checkpoint_log(log),
         :ok <- validate_checkpoint_numbers(memory, log),
         true <- is_map(hard_state) or {:error, :invalid_checkpoint_hard_state},
         true <- is_map(client_table) or {:error, :invalid_checkpoint_client_table} do
      {:ok, sequence, %{memory | log: log}}
    end
  end

  defp validate_checkpoint_payload(_payload), do: {:error, :invalid_checkpoint_structure}

  defp validate_checkpoint_log(%Log{base_op_number: base, entries: entries})
       when is_integer(base) and base >= 0 and is_list(entries) do
    if Enum.all?(entries, &valid_checkpoint_entry?/1),
      do: Log.new(base, entries),
      else: {:error, :invalid_checkpoint_log}
  end

  defp validate_checkpoint_log(_log), do: {:error, :invalid_checkpoint_log}

  defp valid_checkpoint_entry?(%LogEntry{
         view_number: view_number,
         op_number: op_number,
         request_number: request_number,
         metadata: metadata
       }) do
    is_integer(view_number) and view_number >= 0 and is_integer(op_number) and op_number > 0 and
      is_integer(request_number) and request_number >= 0 and is_map(metadata)
  end

  defp valid_checkpoint_entry?(_entry), do: false

  defp validate_checkpoint_numbers(memory, log) do
    base = log.base_op_number
    last = Log.last_op_number(log)

    cond do
      not is_integer(memory.commit_number) or memory.commit_number < base ->
        {:error, :invalid_checkpoint_commit_number}

      memory.commit_number > last ->
        {:error, :invalid_checkpoint_commit_number}

      not is_integer(memory.applied_number) or memory.applied_number < base ->
        {:error, :invalid_checkpoint_applied_number}

      memory.applied_number > memory.commit_number ->
        {:error, :invalid_checkpoint_applied_number}

      true ->
        :ok
    end
  end

  defp validate_wal_sequences(records) do
    records
    |> Enum.reduce_while(0, fn {sequence, _operation}, previous ->
      if sequence == previous + 1,
        do: {:cont, sequence},
        else: {:halt, {:error, {:non_contiguous_wal_sequence, previous + 1, sequence}}}
    end)
    |> case do
      sequence when is_integer(sequence) -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_checkpoint_sequence(_records, 0), do: :ok

  defp validate_checkpoint_sequence(records, checkpoint_sequence) do
    last_sequence =
      case List.last(records) do
        {sequence, _operation} -> sequence
        nil -> 0
      end

    if checkpoint_sequence <= last_sequence do
      :ok
    else
      {:error,
       {:invalid_checkpoint, {:sequence_ahead_of_wal, checkpoint_sequence, last_sequence}}}
    end
  end

  defp write_version(opts) do
    case Keyword.get(opts, :write_version, @legacy_version) do
      version when version in [@legacy_version, @version] -> {:ok, version}
      version -> {:error, {:unsupported_write_version, version}}
    end
  end

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

  defp ensure_storage_directory(directory) when is_binary(directory) do
    directory = Path.expand(directory)

    with {:ok, missing_directories} <- missing_directories(directory),
         :ok <- File.mkdir_p(directory),
         :ok <- sync_created_directory_entries(missing_directories) do
      {:ok, directory}
    end
  end

  defp ensure_storage_directory(_directory), do: {:error, :invalid_storage_path}

  defp missing_directories(directory) do
    case File.stat(directory) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, []}

      {:ok, _not_a_directory} ->
        {:error, :enotdir}

      {:error, :enoent} ->
        parent = Path.dirname(directory)

        if parent == directory do
          {:error, :enoent}
        else
          with {:ok, missing} <- missing_directories(parent) do
            {:ok, missing ++ [directory]}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_created_directory_entries(directories) do
    Enum.reduce_while(directories, :ok, fn directory, :ok ->
      case sync_directory(Path.dirname(directory)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_file(path) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:append, :binary, :raw]) do
      result = :file.sync(file)
      close_result = :file.close(file)

      case result do
        :ok -> close_result
        {:error, _reason} = error -> error
      end
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
