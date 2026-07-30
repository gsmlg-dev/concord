defmodule ViewstampedReplication.StorageTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Log, LogEntry}
  alias ViewstampedReplication.Storage.{File, Memory}

  @identity [configuration_hash: <<1, 2, 3>>, replica_id: 1]
  @max_record_size 256 * 1024 * 1024

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
               applied_number: 1,
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
    assert {:ok, storage} = Memory.install_snapshot(storage, %{last_op_number: 1})

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

  test "memory storage installs a snapshot and its matching protocol state atomically" do
    snapshot = %{last_op_number: 2, state_machine: %{value: 2}}
    assert {:ok, log} = Log.new(2, [entry(3)])
    assert {:ok, storage} = Memory.open(@identity)

    assert {:ok, storage} =
             Memory.install_snapshot_state(storage, snapshot, %{
               view_number: 1,
               last_normal_view: 1,
               status: :normal,
               log: log,
               commit_number: 3,
               applied_number: 2,
               client_table: %{}
             })

    assert {:ok, recovered, _storage} = Memory.recover(storage)
    assert recovered.snapshot == snapshot
    assert recovered.log == log
    assert recovered.commit_number == 3
    assert recovered.applied_number == 2
  end

  @tag :tmp_dir
  test "file storage recovers WAL and checkpoint state", %{tmp_dir: tmp_dir} do
    opts = @identity |> Keyword.put(:path, tmp_dir) |> Keyword.put(:write_version, 2)

    assert {:ok, storage} = File.open(opts)
    assert {:ok, storage} = File.persist_hard_state(storage, %{view_number: 3, status: :normal})
    assert {:ok, storage} = File.append(storage, [entry(1), entry(2)])
    assert {:ok, storage} = File.set_commit_number(storage, 2)

    assert {:ok, storage} =
             File.set_applied(storage, 2, %{
               client: %{request_number: 2, status: :applied, result: :ok}
             })

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
  test "file storage durably initializes a nested directory and WAL", %{tmp_dir: tmp_dir} do
    nested = Path.join([tmp_dir, "new", "nested", "replica"])
    opts = @identity |> Keyword.put(:path, nested) |> Keyword.put(:write_version, 2)

    refute Elixir.File.exists?(nested)
    assert {:ok, storage} = File.open(opts)
    assert Elixir.File.dir?(nested)
    assert Elixir.File.exists?(Path.join(nested, "replica.wal"))
    assert :ok = File.close(storage)

    assert {:ok, reopened} = File.open(opts)
    assert {:ok, %{log: %Log{entries: []}}, _reopened} = File.recover(reopened)
  end

  @tag :tmp_dir
  test "file snapshot-state installation has no crash-visible intermediate state", %{
    tmp_dir: tmp_dir
  } do
    opts = @identity |> Keyword.put(:path, tmp_dir) |> Keyword.put(:write_version, 2)
    wal_path = Path.join(tmp_dir, "replica.wal")
    snapshot = %{last_op_number: 2, state_machine: %{value: 2}}
    assert {:ok, log} = Log.new(2, [entry(3)])
    assert {:ok, storage} = File.open(opts)
    assert {:ok, storage} = File.append(storage, entry(1))
    assert {:ok, storage} = File.set_commit_number(storage, 1)
    wal_before = Elixir.File.read!(wal_path)

    assert {:ok, _installed} =
             File.install_snapshot_state(storage, snapshot, %{
               view_number: 1,
               last_normal_view: 1,
               status: :normal,
               log: log,
               commit_number: 3,
               applied_number: 2,
               client_table: %{}
             })

    # Discard the returned adapter state, as a replica crash would. The atomic
    # checkpoint is sufficient and no separately replayable half-install exists.
    assert Elixir.File.read!(wal_path) == wal_before
    assert {:ok, reopened} = File.open(opts)
    assert {:ok, recovered, _reopened} = File.recover(reopened)
    assert recovered.snapshot == snapshot
    assert recovered.log == log
    assert recovered.commit_number == 3
    assert recovered.applied_number == 2
  end

  @tag :tmp_dir
  test "file storage defaults to rollback-compatible version-one writes", %{tmp_dir: tmp_dir} do
    opts = Keyword.put(@identity, :path, tmp_dir)
    wal_path = Path.join(tmp_dir, "replica.wal")

    assert {:ok, storage} = File.open(opts)
    assert storage.write_version == 1
    assert {:ok, _storage} = File.append(storage, entry(1))
    assert <<"VSRW", 1, _rest::binary>> = Elixir.File.read!(wal_path)
  end

  @tag :tmp_dir
  test "file storage reads a version-one checkpoint and mixed version-one/version-two WAL", %{
    tmp_dir: tmp_dir
  } do
    legacy_opts = Keyword.put(@identity, :path, tmp_dir)
    current_opts = Keyword.put(legacy_opts, :write_version, 2)
    wal_path = Path.join(tmp_dir, "replica.wal")
    checkpoint_path = Path.join(tmp_dir, "checkpoint.vsr")

    assert {:ok, legacy} = File.open(legacy_opts)
    assert {:ok, legacy} = File.append(legacy, entry(1))
    assert {:ok, _legacy} = File.write_snapshot(legacy, :legacy_checkpoint)
    assert <<"VSRW", 1, _rest::binary>> = Elixir.File.read!(checkpoint_path)

    assert {:ok, current} = File.open(current_opts)
    assert {:ok, _recovered, current} = File.recover(current)
    legacy_wal_size = Elixir.File.stat!(wal_path).size
    assert {:ok, _current} = File.append(current, entry(2))

    mixed_wal = Elixir.File.read!(wal_path)
    assert <<_legacy::binary-size(legacy_wal_size), "VSRW", 2, _rest::binary>> = mixed_wal

    assert {:ok, reopened} = File.open(current_opts)

    assert {:ok,
            %{
              log: %Log{entries: [%LogEntry{op_number: 1}, %LogEntry{op_number: 2}]},
              snapshot: :legacy_checkpoint
            }, _reopened} = File.recover(reopened)
  end

  @tag :tmp_dir
  test "file storage rejects unsupported write versions", %{tmp_dir: tmp_dir} do
    opts = @identity |> Keyword.put(:path, tmp_dir) |> Keyword.put(:write_version, 3)

    assert {:error, {:unsupported_write_version, 3}} = File.open(opts)
  end

  @tag :tmp_dir
  test "file recovery truncates an incomplete final WAL record", %{tmp_dir: tmp_dir} do
    opts = @identity |> Keyword.put(:path, tmp_dir) |> Keyword.put(:write_version, 2)
    wal_path = Path.join(tmp_dir, "replica.wal")

    assert {:ok, storage} = File.open(opts)
    assert {:ok, _storage} = File.append(storage, entry(1))
    wal_record = Elixir.File.read!(wal_path)
    valid_size = Elixir.File.stat!(wal_path).size
    partial_record = binary_part(wal_record, 0, byte_size(wal_record) - 1)
    assert :ok = Elixir.File.write(wal_path, partial_record, [:append])
    assert Elixir.File.stat!(wal_path).size > valid_size

    assert {:ok, reopened} = File.open(opts)

    assert {:ok, %{log: %Log{entries: [%LogEntry{op_number: 1}]}}, _reopened} =
             File.recover(reopened)

    assert Elixir.File.stat!(wal_path).size == valid_size
  end

  @tag :tmp_dir
  test "file recovery recognizes every incomplete version-two header boundary", %{
    tmp_dir: tmp_dir
  } do
    opts = @identity |> Keyword.put(:path, tmp_dir) |> Keyword.put(:write_version, 2)
    wal_path = Path.join(tmp_dir, "replica.wal")

    assert {:ok, storage} = File.open(opts)
    assert {:ok, _storage} = File.append(storage, entry(1))
    complete = Elixir.File.read!(wal_path)

    for partial_size <- 1..21 do
      partial = binary_part(complete, 0, partial_size)
      Elixir.File.write!(wal_path, complete <> partial)
      assert {:ok, reopened} = File.open(opts)

      assert {:ok, %{log: %Log{entries: [%LogEntry{op_number: 1}]}}, _reopened} =
               File.recover(reopened)

      assert Elixir.File.read!(wal_path) == complete
    end
  end

  @tag :tmp_dir
  test "file recovery fails closed on a checksum mismatch", %{tmp_dir: tmp_dir} do
    opts = Keyword.put(@identity, :path, tmp_dir)
    wal_path = Path.join(tmp_dir, "replica.wal")

    assert {:ok, storage} = File.open(opts)
    assert {:ok, _storage} = File.append(storage, entry(1))
    wal = Elixir.File.read!(wal_path)
    prefix_size = byte_size(wal) - 1
    <<prefix::binary-size(prefix_size), last_byte>> = wal
    corrupt_wal = <<prefix::binary, Bitwise.bxor(last_byte, 0xFF)>>
    Elixir.File.write!(wal_path, corrupt_wal)

    assert {:ok, reopened} = File.open(opts)
    assert {:error, {:invalid_wal_record, 0, :checksum_mismatch}} = File.recover(reopened)
    assert Elixir.File.read!(wal_path) == corrupt_wal
  end

  @tag :tmp_dir
  test "file recovery fails closed on an unsupported WAL version", %{tmp_dir: tmp_dir} do
    opts = Keyword.put(@identity, :path, tmp_dir)
    wal_path = Path.join(tmp_dir, "replica.wal")

    assert {:ok, storage} = File.open(opts)
    assert {:ok, _storage} = File.append(storage, entry(1))
    <<"VSRW", _version, rest::binary>> = Elixir.File.read!(wal_path)
    unsupported_wal = <<"VSRW", 3, rest::binary>>
    Elixir.File.write!(wal_path, unsupported_wal)

    assert {:ok, reopened} = File.open(opts)

    assert {:error, {:invalid_wal_record, 0, {:unsupported_version, 3}}} =
             File.recover(reopened)

    assert Elixir.File.read!(wal_path) == unsupported_wal
  end

  @tag :tmp_dir
  test "file recovery fails closed when a complete record length is corrupted", %{
    tmp_dir: tmp_dir
  } do
    opts = @identity |> Keyword.put(:path, tmp_dir) |> Keyword.put(:write_version, 2)
    wal_path = Path.join(tmp_dir, "replica.wal")

    assert {:ok, storage} = File.open(opts)
    assert {:ok, _storage} = File.append(storage, entry(1))

    <<"VSRW", 2, length::unsigned-big-64, header_checksum::unsigned-big-32,
      payload_checksum::unsigned-big-32, payload::binary>> = Elixir.File.read!(wal_path)

    corrupt_wal =
      <<"VSRW", 2, length + 1::unsigned-big-64, header_checksum::unsigned-big-32,
        payload_checksum::unsigned-big-32, payload::binary>>

    Elixir.File.write!(wal_path, corrupt_wal)
    assert {:ok, reopened} = File.open(opts)
    assert {:error, {:invalid_wal_record, 0, :header_checksum_mismatch}} = File.recover(reopened)
    assert Elixir.File.read!(wal_path) == corrupt_wal
  end

  @tag :tmp_dir
  test "file recovery returns errors for malformed and inconsistent checkpoints", %{
    tmp_dir: tmp_dir
  } do
    opts = @identity |> Keyword.put(:path, tmp_dir) |> Keyword.put(:write_version, 2)
    checkpoint_path = Path.join(tmp_dir, "checkpoint.vsr")

    assert {:ok, storage} = File.open(opts)

    Elixir.File.write!(checkpoint_path, frame_term(:not_a_checkpoint, 2))
    assert {:error, {:invalid_checkpoint, :invalid_checkpoint_structure}} = File.recover(storage)

    missing_log = Map.delete(storage.memory, :log)
    Elixir.File.write!(checkpoint_path, frame_term({0, missing_log}, 2))
    assert {:error, {:invalid_checkpoint, :invalid_checkpoint_structure}} = File.recover(storage)

    invalid_memory = %{storage.memory | commit_number: 1}
    Elixir.File.write!(checkpoint_path, frame_term({0, invalid_memory}, 2))

    assert {:error, {:invalid_checkpoint, :invalid_checkpoint_commit_number}} =
             File.recover(storage)

    invalid_log_memory = %{storage.memory | log: %Log{base_op_number: :invalid, entries: []}}
    Elixir.File.write!(checkpoint_path, frame_term({0, invalid_log_memory}, 2))
    assert {:error, {:invalid_checkpoint, :invalid_checkpoint_log}} = File.recover(storage)

    Elixir.File.write!(checkpoint_path, frame_term({1, storage.memory}, 2))

    assert {:error, {:invalid_checkpoint, {:sequence_ahead_of_wal, 1, 0}}} =
             File.recover(storage)
  end

  @tag :tmp_dir
  test "file recovery rejects malformed hard state and client records", %{tmp_dir: tmp_dir} do
    opts = @identity |> Keyword.put(:path, tmp_dir) |> Keyword.put(:write_version, 2)
    client_path = Path.join(tmp_dir, "invalid-client")
    missing_client_path = Path.join(tmp_dir, "missing-client")

    assert {:ok, storage} = File.open(opts)

    assert {:ok, invalid_view} =
             File.persist_hard_state(storage, %{
               view_number: :not_an_integer,
               last_normal_view: 0,
               status: :normal
             })

    assert {:ok, _invalid_view} = File.write_snapshot(invalid_view, nil)
    assert {:ok, reopened} = File.open(opts)

    assert {:error, {:invalid_recovered_state, :invalid_view_number}} =
             File.recover(reopened)

    assert {:ok, valid_storage} = File.open(Keyword.put(opts, :path, client_path))

    assert {:ok, invalid_client} =
             File.set_applied(valid_storage, 0, %{
               client: %{request_number: :not_an_integer, status: :pending, result: nil}
             })

    assert {:ok, _invalid_client} = File.write_snapshot(invalid_client, nil)

    assert {:error, {:invalid_recovered_state, :invalid_client_table}} =
             File.recover(invalid_client)

    assert {:ok, missing_client} = File.open(Keyword.put(opts, :path, missing_client_path))
    assert {:ok, missing_client} = File.append(missing_client, entry(1))
    assert {:ok, missing_client} = File.set_commit_number(missing_client, 1)
    assert {:ok, missing_client} = File.set_applied(missing_client, 1, %{})
    assert {:ok, _missing_client} = File.write_snapshot(missing_client, nil)

    assert {:error, {:invalid_recovered_state, :invalid_client_table}} =
             File.recover(missing_client)
  end

  @tag :tmp_dir
  test "file recovery fails closed on incomplete version-one and version-two checkpoints", %{
    tmp_dir: tmp_dir
  } do
    opts = Keyword.put(@identity, :path, tmp_dir)
    checkpoint_path = Path.join(tmp_dir, "checkpoint.vsr")

    assert {:ok, storage} = File.open(opts)

    for version <- [1, 2] do
      complete = frame_term({0, storage.memory}, version)
      incomplete = binary_part(complete, 0, byte_size(complete) - 1)
      Elixir.File.write!(checkpoint_path, incomplete)

      expected_reason =
        if version == 1,
          do: {:ambiguous_legacy_record, :payload},
          else: {:incomplete_record, :payload}

      assert {:error, {:invalid_checkpoint, ^expected_reason}} = File.recover(storage)
      assert Elixir.File.read!(checkpoint_path) == incomplete
    end
  end

  @tag :tmp_dir
  test "file recovery does not truncate a torn tail when replay validation fails", %{
    tmp_dir: tmp_dir
  } do
    opts = @identity |> Keyword.put(:path, tmp_dir) |> Keyword.put(:write_version, 2)
    wal_path = Path.join(tmp_dir, "replica.wal")
    invalid_record = frame_term({1, :unknown_operation}, 2)
    complete_tail = frame_term({2, {:append, [entry(1)]}}, 2)
    torn_tail = binary_part(complete_tail, 0, byte_size(complete_tail) - 1)
    invalid_wal = invalid_record <> torn_tail

    assert {:ok, storage} = File.open(opts)
    Elixir.File.write!(wal_path, invalid_wal)

    assert {:error, {:invalid_wal_operation, 1, {:unknown_storage_operation, :unknown_operation}}} =
             File.recover(storage)

    assert Elixir.File.read!(wal_path) == invalid_wal
  end

  @tag :tmp_dir
  test "file recovery fails closed on a malformed known operation before a torn tail", %{
    tmp_dir: tmp_dir
  } do
    opts = @identity |> Keyword.put(:path, tmp_dir) |> Keyword.put(:write_version, 2)
    wal_path = Path.join(tmp_dir, "replica.wal")
    malformed_operation = {:hard_state, :not_a_map}
    malformed_record = frame_term({1, malformed_operation}, 2)
    complete_tail = frame_term({2, {:append, [entry(1)]}}, 2)
    torn_tail = binary_part(complete_tail, 0, byte_size(complete_tail) - 1)
    invalid_wal = malformed_record <> torn_tail

    assert {:ok, storage} = File.open(opts)
    Elixir.File.write!(wal_path, invalid_wal)

    assert {:error,
            {:invalid_wal_operation, 1, {:malformed_storage_operation, ^malformed_operation}}} =
             File.recover(storage)

    assert Elixir.File.read!(wal_path) == invalid_wal
  end

  @tag :tmp_dir
  test "file recovery reads complete legacy version-one records", %{tmp_dir: tmp_dir} do
    opts = Keyword.put(@identity, :path, tmp_dir)
    wal_path = Path.join(tmp_dir, "replica.wal")
    legacy_wal = frame_term({1, {:append, [entry(1)]}}, 1)

    assert {:ok, _storage} = File.open(opts)
    Elixir.File.write!(wal_path, legacy_wal)
    assert {:ok, reopened} = File.open(opts)

    assert {:ok, %{log: %Log{entries: [%LogEntry{op_number: 1}]}}, _reopened} =
             File.recover(reopened)

    assert Elixir.File.read!(wal_path) == legacy_wal
  end

  @tag :tmp_dir
  test "file recovery fails closed on an ambiguous incomplete legacy record", %{tmp_dir: tmp_dir} do
    opts = Keyword.put(@identity, :path, tmp_dir)
    wal_path = Path.join(tmp_dir, "replica.wal")
    complete = frame_term({1, {:append, [entry(1)]}}, 1)
    incomplete = binary_part(complete, 0, byte_size(complete) - 1)

    assert {:ok, _storage} = File.open(opts)
    Elixir.File.write!(wal_path, incomplete)
    assert {:ok, reopened} = File.open(opts)

    assert {:error, {:invalid_wal_record, 0, {:ambiguous_legacy_record, :payload}}} =
             File.recover(reopened)

    assert Elixir.File.read!(wal_path) == incomplete
  end

  @tag :tmp_dir
  test "file recovery fails closed on invalid WAL magic", %{tmp_dir: tmp_dir} do
    opts = Keyword.put(@identity, :path, tmp_dir)
    wal_path = Path.join(tmp_dir, "replica.wal")
    invalid_wal = <<"NOPE", 1, 0::unsigned-big-64, 0::unsigned-big-32>>

    assert {:ok, _storage} = File.open(opts)
    Elixir.File.write!(wal_path, invalid_wal)

    assert {:ok, reopened} = File.open(opts)
    assert {:error, {:invalid_wal_record, 0, :invalid_magic}} = File.recover(reopened)
    assert Elixir.File.read!(wal_path) == invalid_wal
  end

  @tag :tmp_dir
  test "file recovery fails closed on a complete record containing an invalid term", %{
    tmp_dir: tmp_dir
  } do
    opts = Keyword.put(@identity, :path, tmp_dir)
    wal_path = Path.join(tmp_dir, "replica.wal")
    invalid_wal = frame_payload(<<0, 1, 2, 3>>)

    assert {:ok, _storage} = File.open(opts)
    Elixir.File.write!(wal_path, invalid_wal)

    assert {:ok, reopened} = File.open(opts)
    assert {:error, {:invalid_wal_record, 0, :invalid_term}} = File.recover(reopened)
    assert Elixir.File.read!(wal_path) == invalid_wal
  end

  @tag :tmp_dir
  test "file recovery preserves committed values containing atoms unloaded after a VM restart", %{
    tmp_dir: tmp_dir
  } do
    opts = @identity |> Keyword.put(:path, tmp_dir) |> Keyword.put(:write_version, 2)
    wal_path = Path.join(tmp_dir, "replica.wal")
    atom_name = "vsr_restart_atom_#{System.unique_integer([:positive, :monotonic])}"

    script = """
    name = System.fetch_env!("VSR_TEST_ATOM")
    entry = %{
      __struct__: ViewstampedReplication.LogEntry,
      view_number: 0,
      op_number: 1,
      client_id: :client,
      request_number: 1,
      operation: {:write, %{String.to_atom(name) => "value"}},
      metadata: %{}
    }

    term = {1, {:append, [entry]}}
    IO.write(Base.encode64(:erlang.term_to_binary(term, [:deterministic])))
    """

    elixir = System.find_executable("elixir")
    assert is_binary(elixir)

    assert {encoded, 0} =
             System.cmd(elixir, ["-e", script], env: [{"VSR_TEST_ATOM", atom_name}])

    payload = encoded |> String.trim() |> Base.decode64!()

    assert_raise ArgumentError, fn ->
      :erlang.binary_to_term(payload, [:safe])
    end

    assert {:ok, _storage} = File.open(opts)

    Elixir.File.write!(
      wal_path,
      frame_payload(payload, 2) <> frame_term({2, {:commit_number, 1}}, 2)
    )

    assert {:ok, reopened} = File.open(opts)

    assert {:ok, %{commit_number: 1, log: %Log{entries: [recovered]}}, _reopened} =
             File.recover(reopened)

    assert {:write, value} = recovered.operation

    assert Enum.any?(Map.keys(value), fn key ->
             is_atom(key) and Atom.to_string(key) == atom_name
           end)
  end

  @tag :tmp_dir
  test "file recovery fails closed on a structurally invalid complete record", %{tmp_dir: tmp_dir} do
    opts = Keyword.put(@identity, :path, tmp_dir)
    wal_path = Path.join(tmp_dir, "replica.wal")
    invalid_wal = :not_a_wal_record |> :erlang.term_to_binary([:deterministic]) |> frame_payload()

    assert {:ok, _storage} = File.open(opts)
    Elixir.File.write!(wal_path, invalid_wal)

    assert {:ok, reopened} = File.open(opts)

    assert {:error, {:invalid_wal_record, 0, :invalid_record_structure}} =
             File.recover(reopened)

    assert Elixir.File.read!(wal_path) == invalid_wal
  end

  @tag :tmp_dir
  test "file recovery fails closed on an oversized record", %{tmp_dir: tmp_dir} do
    opts = Keyword.put(@identity, :path, tmp_dir)
    wal_path = Path.join(tmp_dir, "replica.wal")
    oversized_length = 256 * 1024 * 1024 + 1
    header_checksum = :erlang.crc32(<<2, oversized_length::unsigned-big-64>>)

    invalid_wal =
      <<"VSRW", 2, oversized_length::unsigned-big-64, header_checksum::unsigned-big-32,
        0::unsigned-big-32>>

    assert {:ok, _storage} = File.open(opts)
    Elixir.File.write!(wal_path, invalid_wal)

    assert {:ok, reopened} = File.open(opts)

    assert {:error, {:invalid_wal_record, 0, {:record_too_large, ^oversized_length}}} =
             File.recover(reopened)

    assert Elixir.File.read!(wal_path) == invalid_wal
  end

  @tag :tmp_dir
  @tag timeout: 120_000
  test "file storage rejects oversized writes without changing durable state", %{
    tmp_dir: tmp_dir
  } do
    opts = @identity |> Keyword.put(:path, tmp_dir) |> Keyword.put(:write_version, 2)
    wal_path = Path.join(tmp_dir, "replica.wal")
    checkpoint_path = Path.join(tmp_dir, "checkpoint.vsr")
    previous_snapshot = %{last_op_number: 1, state_machine: :previous}

    assert {:ok, storage} = File.open(opts)
    assert {:ok, storage} = File.append(storage, entry(1))
    assert {:ok, storage} = File.set_commit_number(storage, 1)

    assert {:ok, storage} =
             File.set_applied(storage, 1, %{
               client: %{request_number: 1, status: :applied, result: :ok}
             })

    assert {:ok, storage} = File.write_snapshot(storage, previous_snapshot)

    wal_before = Elixir.File.read!(wal_path)
    checkpoint_before = Elixir.File.read!(checkpoint_path)
    oversized = oversized_term()
    oversized_entry = %{entry(2) | operation: {:write, oversized}}

    assert {:error, {:record_too_large, wal_payload_size}} =
             File.append(storage, oversized_entry)

    assert wal_payload_size > @max_record_size
    assert Elixir.File.read!(wal_path) == wal_before
    assert Elixir.File.read!(checkpoint_path) == checkpoint_before

    assert {:ok, compacted_log} = Log.new(1, [])

    assert {:error, {:record_too_large, checkpoint_payload_size}} =
             File.install_snapshot_state(storage, %{state_machine: oversized}, %{
               view_number: 1,
               last_normal_view: 1,
               status: :normal,
               log: compacted_log,
               commit_number: 1,
               applied_number: 1,
               client_table: %{}
             })

    assert checkpoint_payload_size > @max_record_size
    assert Elixir.File.read!(wal_path) == wal_before
    assert Elixir.File.read!(checkpoint_path) == checkpoint_before

    assert {:ok, reopened} = File.open(opts)
    assert {:ok, recovered, _reopened} = File.recover(reopened)
    assert recovered.snapshot == previous_snapshot
    assert recovered.log == storage.memory.log
  end

  @tag :tmp_dir
  test "file recovery rejects configuration identity mismatch", %{tmp_dir: tmp_dir} do
    opts = @identity |> Keyword.put(:path, tmp_dir) |> Keyword.put(:write_version, 2)
    wal_path = Path.join(tmp_dir, "replica.wal")

    assert {:ok, storage} = File.open(opts)
    assert {:ok, _storage} = File.write_snapshot(storage, :checkpoint)
    complete = Elixir.File.read!(wal_path)
    torn_tail = binary_part(complete, 0, byte_size(complete) - 1)
    Elixir.File.write!(wal_path, complete <> torn_tail)
    mismatched_wal = Elixir.File.read!(wal_path)

    assert {:ok, reopened} =
             File.open(
               path: tmp_dir,
               configuration_hash: <<9>>,
               replica_id: 1,
               write_version: 2
             )

    assert {:error, :configuration_hash_mismatch} = File.recover(reopened)
    assert Elixir.File.read!(wal_path) == mismatched_wal
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

  defp oversized_term do
    chunk = :binary.copy(<<0>>, 256 * 1024)
    List.duplicate(chunk, 1024)
  end

  defp frame_term(term, version) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> frame_payload(version)
  end

  defp frame_payload(payload, version \\ 2)

  defp frame_payload(payload, 1) do
    payload_checksum = :erlang.crc32(payload)

    <<"VSRW", 1, byte_size(payload)::unsigned-big-64, payload_checksum::unsigned-big-32,
      payload::binary>>
  end

  defp frame_payload(payload, 2) do
    length = byte_size(payload)
    header_checksum = :erlang.crc32(<<2, length::unsigned-big-64>>)
    payload_checksum = :erlang.crc32(payload)

    <<"VSRW", 2, length::unsigned-big-64, header_checksum::unsigned-big-32,
      payload_checksum::unsigned-big-32, payload::binary>>
  end

  defp cleanup_tmp_dir(tmp_dir) do
    Elixir.File.rm_rf!(tmp_dir)
    Elixir.File.rmdir(Path.dirname(tmp_dir))
    Elixir.File.rmdir(Path.expand("tmp"))
    :ok
  end
end
