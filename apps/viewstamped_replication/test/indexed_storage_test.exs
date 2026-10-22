defmodule ViewstampedReplication.IndexedStorageTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Log, LogEntry, Storage}
  alias ViewstampedReplication.Log.Indexed
  alias ViewstampedReplication.Storage.{File, Memory}

  @identity [configuration_hash: <<4, 5, 6>>, replica_id: :replica]
  @memory_fields [
    :__struct__,
    :configuration_hash,
    :replica_id,
    :hard_state,
    :log,
    :commit_number,
    :applied_number,
    :snapshot,
    :client_table
  ]

  test "memory recovery exports canonical logs and retains an indexed live log" do
    first = entry(1)
    second = entry(2)
    assert {:ok, storage} = Memory.open(@identity)
    assert {:ok, storage} = Memory.append(storage, first)
    assert {:ok, storage} = Memory.set_commit_number(storage, 1)
    assert {:ok, storage} = Memory.set_applied(storage, 1, client_table(1))

    assert {:ok, %{log: %Log{base_op_number: 0, entries: [^first]}} = recovered, live} =
             Memory.recover(storage)

    assert :ok = Storage.validate_recovered(recovered)
    assert %Indexed{base_op_number: 0, last_op_number: 1, entries: %{1 => ^first}} = live.log
    assert {:ok, appended} = Memory.append(live, second)

    assert {:ok, %{log: %Log{entries: [^first, ^second]}}, _live} = Memory.recover(appended)
    assert Log.to_list(live.log) == [first]
  end

  test "memory recovery rejects malformed indexed and unsupported log representations" do
    assert {:ok, storage} = Memory.open(@identity)

    malformed_logs = [
      :invalid,
      %{},
      %Indexed{last_op_number: 1},
      %Indexed{base_op_number: -1},
      %Indexed{last_op_number: 1, entries: %{2 => entry(2)}},
      %Indexed{last_op_number: 1, entries: %{1 => entry(2)}},
      %Indexed{last_op_number: 1, entries: %{1 => entry(1), 2 => entry(2)}},
      %Indexed{last_op_number: 1, entries: %{1 => :not_an_entry}},
      %Indexed{entries: []}
    ]

    for log <- malformed_logs do
      assert {:error, {:invalid_recovered_state, :invalid_log}} =
               Memory.recover(%{storage | log: log})
    end
  end

  @tag :tmp_dir
  test "both checkpoint writers persist only canonical legacy memory and log shapes", %{
    tmp_dir: tmp_dir
  } do
    first = entry(1)
    second = entry(2)
    third = entry(3)

    for version <- [1, 2] do
      path = Path.join(tmp_dir, "checkpoint-writers-#{version}")
      opts = storage_options(path, version)
      snapshot = %{last_op_number: 1, state_machine: %{value: 1}}
      assert {:ok, storage} = File.open(opts)
      assert {:ok, storage} = File.append(storage, first)
      assert {:ok, storage} = File.set_commit_number(storage, 1)
      assert {:ok, storage} = File.set_applied(storage, 1, client_table(1))
      assert {:ok, storage} = File.write_snapshot(storage, snapshot)

      checkpoint_path = Path.join(path, "checkpoint.vsr")
      {sequence, persisted} = canonical_checkpoint(checkpoint_path, version)
      assert sequence == storage.sequence
      assert persisted.log == %Log{base_op_number: 0, entries: [first]}
      assert persisted.snapshot == snapshot
      assert %Indexed{} = storage.memory.log
      wal_path = Path.join(path, "replica.wal")
      wal_before = Elixir.File.read!(wal_path)
      assert {:ok, compacted} = Log.new(1, [second])

      assert {:ok, installed} =
               File.install_snapshot_state(storage, snapshot, %{
                 view_number: 0,
                 last_normal_view: 0,
                 status: :normal,
                 log: compacted,
                 commit_number: 2,
                 applied_number: 2,
                 client_table: client_table(2)
               })

      assert Elixir.File.read!(wal_path) == wal_before
      assert {^sequence, persisted} = canonical_checkpoint(checkpoint_path, version)
      assert persisted.log == compacted
      assert persisted.applied_number == 2
      assert persisted.client_table == client_table(2)
      assert %Indexed{} = installed.memory.log
      assert :ok = File.close(installed)

      assert {:ok, reopened} = File.open(opts)
      assert {:ok, recovered, reopened} = File.recover(reopened)
      assert :ok = Storage.validate_recovered(recovered)
      assert recovered.log == compacted
      assert recovered.snapshot == snapshot
      assert %Indexed{} = reopened.memory.log
      assert {:ok, appended} = File.append(reopened, third)
      assert :ok = File.close(appended)
      assert {:ok, reopened} = File.open(opts)

      assert {:ok, %{log: %Log{base_op_number: 1, entries: [^second, ^third]}}, _reopened} =
               File.recover(reopened)
    end
  end

  @tag :tmp_dir
  test "canonical legacy checkpoints and WAL tails recover without rewriting their format", %{
    tmp_dir: tmp_dir
  } do
    first = entry(1)
    second = entry(2)
    hard_state = %{view_number: 0, last_normal_view: 0, status: :normal}
    snapshot = %{last_op_number: 1, state_machine: %{value: 1}}

    for version <- [1, 2] do
      path = Path.join(tmp_dir, "legacy-input-#{version}")
      opts = storage_options(path, version)
      assert {:ok, _opened} = File.open(opts)

      memory = %Memory{
        configuration_hash: <<4, 5, 6>>,
        replica_id: :replica,
        hard_state: hard_state,
        log: %Log{base_op_number: 0, entries: [first]},
        commit_number: 1,
        applied_number: 1,
        snapshot: snapshot,
        client_table: client_table(1)
      }

      prior_operations = [
        {:hard_state, hard_state},
        {:append, [first]},
        {:commit_number, 1},
        {:applied, 1, client_table(1)},
        {:snapshot, snapshot}
      ]

      tail_operations = [
        {:append, [second]},
        {:commit_number, 2},
        {:applied, 2, client_table(2)}
      ]

      wal =
        (prior_operations ++ tail_operations)
        |> Enum.with_index(1)
        |> Enum.map(fn {operation, sequence} -> frame_term({sequence, operation}, version) end)
        |> IO.iodata_to_binary()

      checkpoint = frame_term({5, memory}, version)
      wal_path = Path.join(path, "replica.wal")
      checkpoint_path = Path.join(path, "checkpoint.vsr")
      Elixir.File.write!(wal_path, wal)
      Elixir.File.write!(checkpoint_path, checkpoint)

      assert {:ok, storage} = File.open(opts)
      assert {:ok, recovered, live} = File.recover(storage)
      assert recovered.log == %Log{base_op_number: 0, entries: [first, second]}
      assert recovered.commit_number == 2
      assert recovered.applied_number == 2
      assert recovered.client_table == client_table(2)
      assert recovered.snapshot == snapshot
      assert :ok = Storage.validate_recovered(recovered)
      assert %Indexed{last_op_number: 2} = live.memory.log
      assert Elixir.File.read!(wal_path) == wal
      assert Elixir.File.read!(checkpoint_path) == checkpoint
    end
  end

  @tag :tmp_dir
  test "runtime indexed logs are rejected as an unsupported persisted checkpoint shape", %{
    tmp_dir: tmp_dir
  } do
    for version <- [1, 2] do
      path = Path.join(tmp_dir, "invalid-persisted-index-#{version}")
      assert {:ok, storage} = File.open(storage_options(path, version))
      assert %Indexed{} = storage.memory.log
      checkpoint_path = Path.join(path, "checkpoint.vsr")
      checkpoint = frame_term({0, storage.memory}, version)
      Elixir.File.write!(checkpoint_path, checkpoint)

      assert {:error, {:invalid_checkpoint, :invalid_checkpoint_log}} = File.recover(storage)
      assert Elixir.File.read!(checkpoint_path) == checkpoint
    end
  end

  defp canonical_checkpoint(path, version) do
    binary = Elixir.File.read!(path)

    payload =
      case {version, binary} do
        {1, <<"VSRW", 1, length::unsigned-big-64, checksum::unsigned-big-32, payload::binary>>} ->
          assert byte_size(payload) == length
          assert :erlang.crc32(payload) == checksum
          payload

        {2,
         <<"VSRW", 2, length::unsigned-big-64, header_checksum::unsigned-big-32,
           checksum::unsigned-big-32, payload::binary>>} ->
          assert byte_size(payload) == length
          assert :erlang.crc32(<<2, length::unsigned-big-64>>) == header_checksum
          assert :erlang.crc32(payload) == checksum
          payload
      end

    assert {sequence, %Memory{log: %Log{} = log} = memory} = :erlang.binary_to_term(payload)
    assert Enum.sort(Map.keys(memory)) == Enum.sort(@memory_fields)
    assert Enum.sort(Map.keys(log)) == Enum.sort([:__struct__, :base_op_number, :entries])
    assert is_list(log.entries)
    {sequence, memory}
  end

  defp frame_term(term, version) do
    payload = :erlang.term_to_binary(term, [:deterministic])
    length = byte_size(payload)
    checksum = :erlang.crc32(payload)

    case version do
      1 ->
        <<"VSRW", 1, length::unsigned-big-64, checksum::unsigned-big-32, payload::binary>>

      2 ->
        header_checksum = :erlang.crc32(<<2, length::unsigned-big-64>>)

        <<"VSRW", 2, length::unsigned-big-64, header_checksum::unsigned-big-32,
          checksum::unsigned-big-32, payload::binary>>
    end
  end

  defp storage_options(path, version),
    do: @identity |> Keyword.put(:path, path) |> Keyword.put(:write_version, version)

  defp client_table(number),
    do: %{client: %{request_number: number, status: :applied, result: :ok}}

  defp entry(number) do
    %LogEntry{
      view_number: 0,
      op_number: number,
      client_id: :client,
      request_number: number,
      operation: {:write, number}
    }
  end
end
