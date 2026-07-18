defmodule ViewstampedReplication.StorageTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Log, LogEntry}
  alias ViewstampedReplication.Storage.{File, Memory}

  @identity [configuration_hash: <<1, 2, 3>>, replica_id: 1]

  setup context do
    on_exit(fn ->
      if tmp_dir = context[:tmp_dir], do: cleanup_tmp_dir(tmp_dir)
    end)

    :ok
  end

  test "memory storage enforces a contiguous log and monotonic commit number" do
    assert {:ok, storage} = Memory.open(@identity)
    assert {:ok, storage} = Memory.append(storage, [entry(1), entry(2)])
    assert {:ok, storage} = Memory.set_commit_number(storage, 1)
    assert {:error, :commit_number_decreased} = Memory.set_commit_number(storage, 0)
    assert {:error, :cannot_truncate_committed_entry} = Memory.truncate_suffix(storage, 0)
    assert {:ok, storage} = Memory.truncate_suffix(storage, 1)

    assert {:ok, recovered, _storage} = Memory.recover(storage)

    assert %{log: %Log{base_op_number: 0, entries: [%LogEntry{op_number: 1}]}, commit_number: 1} =
             recovered
  end

  test "install_state atomically replaces uncommitted state" do
    assert {:ok, storage} = Memory.open(@identity)
    assert {:ok, log} = Log.new([entry(1)])

    assert {:ok, storage} =
             Memory.install_state(storage, %{
               view_number: 2,
               last_normal_view: 1,
               status: :normal,
               log: log,
               commit_number: 1,
               client_table: %{client: %{request_number: 1, status: :applied, result: :ok}}
             })

    assert {:ok, recovered, _storage} = Memory.recover(storage)

    assert %{
             hard_state: %{view_number: 2, last_normal_view: 1, status: :normal},
             log: %Log{base_op_number: 0, entries: [%LogEntry{op_number: 1}]},
             commit_number: 1,
             client_table: %{client: %{result: :ok}}
           } = recovered
  end

  test "install_state preserves compacted absolute operation numbers" do
    assert {:ok, storage} = Memory.open(@identity)
    assert {:ok, log} = Log.new([entry(1), entry(2)])
    assert {:ok, compacted} = Log.compact(log, 1)

    assert {:ok, storage} =
             Memory.install_state(storage, %{
               log: compacted,
               commit_number: 2,
               applied_number: 1,
               client_table: %{}
             })

    assert {:ok, storage} = Memory.append(storage, entry(3))
    assert {:ok, %{log: recovered_log}, _storage} = Memory.recover(storage)

    assert %Log{base_op_number: 1, entries: [%LogEntry{op_number: 2}, %LogEntry{op_number: 3}]} =
             recovered_log
  end

  @tag :tmp_dir
  test "file storage recovers WAL and checkpoint state", %{tmp_dir: tmp_dir} do
    opts = Keyword.put(@identity, :path, tmp_dir)

    assert {:ok, storage} = File.open(opts)
    assert {:ok, storage} = File.persist_hard_state(storage, %{view_number: 3, status: :normal})
    assert {:ok, storage} = File.append(storage, [entry(1), entry(2)])
    assert {:ok, storage} = File.set_commit_number(storage, 2)

    assert {:ok, storage} =
             File.write_snapshot(storage, %{last_op_number: 2, state_machine: %{value: 7}})

    assert :ok = File.close(storage)
    assert {:ok, reopened} = File.open(opts)
    assert {:ok, recovered, _reopened} = File.recover(reopened)

    assert %{
             hard_state: %{view_number: 3, status: :normal},
             log: %Log{
               base_op_number: 0,
               entries: [%LogEntry{op_number: 1}, %LogEntry{op_number: 2}]
             },
             commit_number: 2,
             snapshot: %{last_op_number: 2, state_machine: %{value: 7}}
           } = recovered
  end

  @tag :tmp_dir
  test "file recovery truncates a partial or corrupt WAL tail", %{tmp_dir: tmp_dir} do
    opts = Keyword.put(@identity, :path, tmp_dir)
    wal_path = Path.join(tmp_dir, "replica.wal")

    assert {:ok, storage} = File.open(opts)
    assert {:ok, _storage} = File.append(storage, entry(1))
    valid_size = Elixir.File.stat!(wal_path).size
    assert :ok = Elixir.File.write(wal_path, <<0, 1, 2, 3, 4>>, [:append])
    assert Elixir.File.stat!(wal_path).size > valid_size

    assert {:ok, reopened} = File.open(opts)

    assert {:ok, %{log: %Log{entries: [%LogEntry{op_number: 1}]}}, _reopened} =
             File.recover(reopened)

    assert Elixir.File.stat!(wal_path).size == valid_size
  end

  @tag :tmp_dir
  test "file recovery rejects a checksummed record with a corrupt payload", %{tmp_dir: tmp_dir} do
    opts = Keyword.put(@identity, :path, tmp_dir)
    wal_path = Path.join(tmp_dir, "replica.wal")

    assert {:ok, storage} = File.open(opts)
    assert {:ok, _storage} = File.append(storage, entry(1))
    wal = Elixir.File.read!(wal_path)
    prefix_size = byte_size(wal) - 1
    <<prefix::binary-size(prefix_size), last_byte>> = wal
    Elixir.File.write!(wal_path, <<prefix::binary, Bitwise.bxor(last_byte, 0xFF)>>)

    assert {:ok, reopened} = File.open(opts)

    assert {:ok, %{log: %Log{base_op_number: 0, entries: []}}, _reopened} =
             File.recover(reopened)

    assert Elixir.File.stat!(wal_path).size == 0
  end

  @tag :tmp_dir
  test "file recovery rejects configuration identity mismatch", %{tmp_dir: tmp_dir} do
    opts = Keyword.put(@identity, :path, tmp_dir)

    assert {:ok, storage} = File.open(opts)
    assert {:ok, _storage} = File.write_snapshot(storage, :checkpoint)
    assert {:ok, reopened} = File.open(path: tmp_dir, configuration_hash: <<9>>, replica_id: 1)
    assert {:error, :configuration_hash_mismatch} = File.recover(reopened)
  end

  defp entry(op_number) do
    %LogEntry{
      view_number: 0,
      op_number: op_number,
      client_id: :client,
      request_number: op_number,
      operation: {:write, op_number}
    }
  end

  defp cleanup_tmp_dir(tmp_dir) do
    Elixir.File.rm_rf!(tmp_dir)
    Elixir.File.rmdir(Path.dirname(tmp_dir))
    Elixir.File.rmdir(Path.expand("tmp"))
    :ok
  end
end
