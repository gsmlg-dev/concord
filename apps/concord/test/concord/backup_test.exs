defmodule Concord.BackupTest do
  use ExUnit.Case, async: false

  alias Concord.Engine
  alias Concord.StateMachine

  @tag :tmp_dir
  test "backups verify and restore in independent VMs with opposite atom histories", %{
    tmp_dir: tmp_dir
  } do
    elixir = System.find_executable("elixir")
    assert is_binary(elixir)
    code_paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])
    fixture = Path.expand("../support/backup_checksum_vm.exs", __DIR__)

    for mode <- ["write", "read"] do
      {output, status} =
        System.cmd(elixir, code_paths ++ [fixture, mode, tmp_dir], stderr_to_stdout: true)

      assert status == 0, output
      assert output =~ "backup checksum #{mode} passed"
    end
  end

  describe "checksum scheme verification" do
    @tag :tmp_dir
    test "rejects corruption and unsupported schemes before restoring", %{tmp_dir: tmp_dir} do
      fields = Map.new(1..1000, &{String.to_atom("backup_integrity_field_#{&1}"), &1})

      data = %{
        version: 2,
        kv_data: [{"integrity", %{value: fields, expires_at: nil}}],
        indexes: %{}
      }

      metadata = %{
        timestamp: DateTime.utc_now(),
        entry_count: 1,
        checksum_scheme: :sha256_deterministic_etf_v1,
        checksum: :crypto.hash(:sha256, :erlang.term_to_binary(data, [:deterministic]))
      }

      backup = %{metadata: metadata, data: data}
      path = Path.join(tmp_dir, "integrity.backup")
      File.write!(path, :erlang.term_to_binary(backup))
      assert {:ok, :valid} = Concord.Backup.verify(path)

      for invalid <- [
            put_in(backup.data.kv_data, []),
            put_in(backup.metadata.checksum, <<0::256>>),
            put_in(backup.metadata.checksum, :crypto.hash(:sha256, :erlang.term_to_binary(data))),
            %{backup | metadata: Map.delete(backup.metadata, :checksum_scheme)}
          ] do
        File.write!(path, :erlang.term_to_binary(invalid))
        assert {:ok, :invalid} = Concord.Backup.verify(path)
        assert {:error, :invalid_backup} = Concord.Backup.restore(path, engine: RejectRestore)
      end

      for scheme <- [:unknown_checksum_scheme, nil] do
        unknown = put_in(backup.metadata.checksum_scheme, scheme)
        File.write!(path, :erlang.term_to_binary(unknown))
        assert {:error, {:unsupported_checksum_scheme, ^scheme}} = Concord.Backup.verify(path)

        assert {:error, {:verification_failed, {:unsupported_checksum_scheme, ^scheme}}} =
                 Concord.Backup.restore(path, engine: RejectRestore)
      end
    end
  end

  describe "Backup V2 format — state machine restore" do
    setup do
      state = StateMachine.init(%{})
      :ets.delete_all_objects(:concord_store)
      {:ok, state: state}
    end

    test "V2 restore_backup restores KV data and indexes", %{state: state} do
      meta = %{index: 1}

      backup_state = %{
        version: 2,
        kv_data: [
          {"key1", %{value: "val1", expires_at: nil}},
          {"key2", %{value: "val2", expires_at: nil}}
        ],
        indexes: %{}
      }

      {_new_state, :ok, _effects} =
        StateMachine.apply_command(meta, {:restore_backup, backup_state}, state)

      # Verify KV data restored
      assert :ets.lookup(:concord_store, "key1") == [{"key1", %{value: "val1", expires_at: nil}}]
      assert :ets.lookup(:concord_store, "key2") == [{"key2", %{value: "val2", expires_at: nil}}]
    end

    test "V2 restore_backup with indexes rebuilds index ETS", %{state: state} do
      meta = %{index: 1}

      # First create an index so we have index state
      {state_with_index, :ok, _} =
        StateMachine.apply_command(meta, {:create_index, "by_email", {:map_get, :email}}, state)

      # Insert a record so the index has data
      {state2, :ok, _} =
        StateMachine.apply_command(
          %{index: 2},
          {:put, "user:1", %{email: "alice@test.com"}, nil},
          state_with_index
        )

      {:concord_kv, current_data} = state2

      # Now simulate a V2 backup restore with index definitions
      backup_state = %{
        version: 2,
        kv_data: [
          {"user:1",
           %{value: :erlang.term_to_binary(%{email: "alice@test.com"}), expires_at: nil}},
          {"user:2", %{value: :erlang.term_to_binary(%{email: "bob@test.com"}), expires_at: nil}}
        ],
        indexes: Map.get(current_data, :indexes, %{})
      }

      {_new_state, :ok, _} =
        StateMachine.apply_command(%{index: 3}, {:restore_backup, backup_state}, state2)

      # Index tables should exist and be rebuilt
      table = Concord.Index.index_table_name("by_email")
      assert :ets.info(table) != :undefined
    end

    test "V1 restore_backup still works (backward compat)", %{state: state} do
      meta = %{index: 1}

      # V1 format: bare list of KV tuples
      kv_entries = [
        {"key1", %{value: "v1", expires_at: nil}},
        {"key2", %{value: "v2", expires_at: nil}}
      ]

      {_new_state, :ok, _effects} =
        StateMachine.apply_command(meta, {:restore_backup, kv_entries}, state)

      # Verify KV data restored
      assert :ets.lookup(:concord_store, "key1") == [{"key1", %{value: "v1", expires_at: nil}}]
      assert :ets.lookup(:concord_store, "key2") == [{"key2", %{value: "v2", expires_at: nil}}]
    end

    test "V2 restore_backup replaces existing state completely", %{state: state} do
      meta = %{index: 1}

      # Pre-populate some data
      :ets.insert(:concord_store, {"old_key", %{value: "old_val", expires_at: nil}})

      # Restore with different data
      backup_state = %{
        version: 2,
        kv_data: [{"new_key", %{value: "new_val", expires_at: nil}}],
        indexes: %{}
      }

      {_new_state, :ok, _effects} =
        StateMachine.apply_command(meta, {:restore_backup, backup_state}, state)

      # Old data should be gone
      assert :ets.lookup(:concord_store, "old_key") == []
      # New data should be present
      assert :ets.lookup(:concord_store, "new_key") == [
               {"new_key", %{value: "new_val", expires_at: nil}}
             ]
    end
  end

  describe "engine-routed VSR backup" do
    setup do
      {:ok, _started} = Application.ensure_all_started(:viewstamped_replication)

      previous_vsr = Application.fetch_env(:concord, :vsr)
      group_id = {:concord_backup_vsr_test, System.unique_integer([:positive, :monotonic])}

      vsr_opts = [
        group_id: group_id,
        replica_id: 1,
        members: [%{id: 1, endpoint: {:local_backup_endpoint, group_id}}],
        transport: :local,
        storage: :memory,
        bootstrap: true,
        retry_timeout: 10,
        client_id: {:concord_backup_vsr_client, group_id}
      ]

      Application.put_env(:concord, :vsr, vsr_opts)

      {:ok, supervisor} = Engine.VSR.Supervisor.start_link(vsr_opts)
      Process.unlink(supervisor)

      on_exit(fn ->
        if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
        restore_env(:vsr, previous_vsr)
      end)

      :ok
    end

    @tag :tmp_dir
    test "creates and restores the V2 logical snapshot through VSR", %{tmp_dir: tmp_dir} do
      assert :ok = Concord.Index.create("backup_by_email", {:map_get, :email})
      assert :ok = Concord.put("backup:user:1", %{email: "saved@example.com"})

      assert {:ok, backup_path} = Concord.Backup.create(path: tmp_dir)
      assert {:ok, :valid} = Concord.Backup.verify(backup_path)

      assert :ok = Concord.delete("backup:user:1")
      assert :ok = Concord.put("backup:after", "not in backup")

      assert :ok = Concord.Backup.restore(backup_path)

      assert {:ok, %{email: "saved@example.com"}} = Concord.get("backup:user:1")
      assert {:error, :not_found} = Concord.get("backup:after")

      assert {:ok, ["backup:user:1"]} =
               Concord.Index.lookup("backup_by_email", "saved@example.com")

      assert {:ok, [%{path: ^backup_path, entry_count: 1}]} = Concord.Backup.list(tmp_dir)
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:concord, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:concord, key)
end
