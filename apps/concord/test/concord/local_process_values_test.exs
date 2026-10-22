defmodule Concord.LocalProcessValuesTest do
  use ExUnit.Case, async: false

  alias Concord.{CommandSchema, Compression, Validation}
  alias Concord.Engine.Local

  setup do
    case Process.whereis(Local) do
      nil -> start_supervised!({Local, []})
      _pid -> :ok
    end

    assert :ok = Local.reset()
    :ok
  end

  test "local values roundtrip nested process references without changing their identity" do
    pid = self()
    value = %{controller_pid: pid, nested: [{pid, %{pid => [pid | pid]}}]}

    assert :ok = Concord.Local.put("pty:controller", value)
    assert {:ok, ^value} = Concord.Local.get("pty:controller")
    assert {:ok, %{"pty:controller" => ^value}} = Concord.Local.get_all()
  end

  test "compressed local process references remain available through ordinary reads" do
    pid = self()
    value = %{controller_pid: pid, data: String.duplicate("session", 500)}

    assert :ok = Concord.Local.put("pty:compressed", value, compress: true)
    assert {:ok, ^value} = Concord.Local.get("pty:compressed")
    assert {:ok, {:ok, {:compressed, _, _}}} = Local.query({:get, "pty:compressed"})
  end

  test "local conditional updates and deletes compare process references" do
    value = %{controller_pid: self(), state: :attached}
    replacement = %{value | state: :detached}

    assert :ok = Concord.Local.put("pty:conditional", value)
    assert :ok = Concord.Local.put_if("pty:conditional", replacement, expected: value)

    assert {:error, :condition_failed} =
             Concord.Local.delete_if("pty:conditional", expected: value)

    assert :ok = Concord.Local.delete_if("pty:conditional", expected: replacement)
    assert {:error, :not_found} = Concord.Local.get("pty:conditional")
  end

  test "local batches and TTL operations retain process references" do
    pid = self()

    assert {:ok, %{"pty:first" => :ok, "pty:second" => :ok}} =
             Concord.Local.put_many([{"pty:first", pid}, {"pty:second", %{controller_pid: pid}}])

    assert {:ok, ^pid} = Concord.Local.get("pty:first")
    assert :ok = Concord.Local.put_with_ttl("pty:ttl", %{controller_pid: pid}, 60)
    assert {:ok, %{controller_pid: ^pid}} = Concord.Local.get("pty:ttl")
    assert {:ok, ttl} = Concord.Local.ttl("pty:ttl")
    assert ttl in 1..60
    assert :ok = Concord.Local.touch("pty:ttl", 60)
    assert :ok = Concord.Local.delete("pty:ttl")
  end

  test "revisioned local puts retain process references" do
    pid = self()

    assert {:ok, %{revision: 1}} = Concord.Local.KV.put("pty:revisioned", %{controller_pid: pid})
    assert {:ok, %{controller_pid: ^pid}} = Concord.Local.KV.get("pty:revisioned")
  end

  test "direct local commands validate and store original process references" do
    pid = self()
    value = %{controller_pid: pid}

    assert {:ok, :ok} = Local.command({:put, "pty:command", value, nil})
    assert {:ok, ^value} = Concord.Local.get("pty:command")

    assert {:ok, %{revision: 2}} =
             GenServer.call(Local, {:command, {:put, "pty:direct", value, %{}}})

    assert {:ok, ^value} = Concord.Local.get("pty:direct")
  end

  @tag :tmp_dir
  test "local backup export refuses plain and compressed process references", %{tmp_dir: tmp_dir} do
    for compress <- [false, true] do
      assert :ok = Local.reset()
      assert :ok = Concord.Local.put("pty:backup", %{controller_pid: self()}, compress: compress)
      assert {:error, {:invalid_snapshot, :pid_in_spec}} = Local.query(:backup_snapshot)

      assert {:error, {:invalid_snapshot, :pid_in_spec}} =
               Concord.Backup.create(path: tmp_dir, engine: :local)

      assert [] = File.ls!(tmp_dir)
    end
  end

  @tag :tmp_dir
  test "local backup works after removing transient values", %{tmp_dir: tmp_dir} do
    assert :ok = Concord.Local.put("pty:transient", %{controller_pid: self()})
    assert :ok = Concord.Local.put("pty:durable", %{state: :detached})
    assert :ok = Concord.Local.delete("pty:transient")

    assert {:ok, path} = Concord.Backup.create(path: tmp_dir, engine: :local)
    assert {:ok, :valid} = Concord.Backup.verify(path)
    assert :ok = Local.reset()
    assert :ok = Concord.Backup.restore(path, engine: :local)
    assert {:ok, %{state: :detached}} = Concord.Local.get("pty:durable")
    assert {:error, :not_found} = Concord.Local.get("pty:transient")
  end

  @tag :tmp_dir
  test "verified backup files containing process references cannot restore locally", %{
    tmp_dir: tmp_dir
  } do
    for value <- [
          %{controller_pid: self()},
          Compression.compress(%{controller_pid: self()}, force: true)
        ] do
      data = %{
        version: 2,
        kv_data: [{"pty:restore", %{value: value, expires_at: nil}}],
        indexes: %{}
      }

      metadata = %{
        timestamp: DateTime.utc_now(),
        entry_count: 1,
        checksum_scheme: :sha256_deterministic_etf_v1,
        checksum: :crypto.hash(:sha256, :erlang.term_to_binary(data, [:deterministic]))
      }

      path = Path.join(tmp_dir, "process-reference.backup")
      File.write!(path, :erlang.term_to_binary(%{metadata: metadata, data: data}))
      assert {:ok, :valid} = Concord.Backup.verify(path)

      assert {:error, {:invalid_command, :pid_in_spec}} =
               Concord.Backup.restore(path, engine: :local)

      assert {:error, :not_found} = Concord.Local.get("pty:restore")
    end
  end

  test "local admission still rejects other runtime terms and unsafe command metadata" do
    for {value, reason} <- [{fn -> :unsafe end, :function_in_spec}, {make_ref(), :ref_in_spec}] do
      assert {:error, ^reason} =
               Concord.Local.put("pty:unsafe", %{controller: self(), other: value})
    end

    assert {:error, {:invalid_command, :pid_in_spec}} =
             Local.command(
               {:put, "pty:metadata", "value", %{metadata: %{controller_pid: self()}}}
             )

    assert {:error, :not_found} = Concord.Local.get("pty:unsafe")
    assert {:error, :not_found} = Concord.Local.get("pty:metadata")
  end

  test "local admission rejects ports, excessive nesting, and malformed compression" do
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary])

    try do
      assert {:error, :port_in_spec} =
               Concord.Local.put("pty:port", %{controller_pid: self(), port: port})
    after
      Port.close(port)
    end

    deep = Enum.reduce(1..101, self(), fn _, value -> %{nested: value} end)
    assert {:error, :depth_exceeded} = Concord.Local.put("pty:deep", deep)

    assert {:error, :invalid_compressed_value} =
             Concord.Local.put("pty:bad-compressed", {:compressed, :zlib, "invalid"})
  end

  test "replicated and durable public APIs, transactions, and restore remain strict" do
    value = %{controller_pid: self()}

    assert {:error, :pid_in_spec} = Concord.put("pty:cluster", value)
    assert {:error, :pid_in_spec} = Concord.Turso.put("pty:durable", value)
    assert {:error, :pid_in_spec} = Concord.KV.put("pty:cluster-revisioned", value)
    assert {:error, :pid_in_spec} = Validation.validate_value(value)

    for stored <- [value, Compression.compress(value, force: true)] do
      assert {:error, {:invalid_command, :pid_in_spec}} =
               CommandSchema.validate_emission({:put, "pty:cluster-command", stored, %{}})

      assert {:error, {:invalid_command, :pid_in_spec}} =
               Local.command({:restore_backup, [{"pty:restored", {stored, nil}}]})
    end

    assert {:error, :pid_in_spec} =
             Concord.Local.txn(%{success: [{:put, "pty:txn", value, %{}}]})
  end

  test "local values retain configured value-size admission limits" do
    original = Application.fetch_env(:concord, :kv)
    on_exit(fn -> restore_env(:kv, original) end)
    Application.put_env(:concord, :kv, max_value_bytes: 100)

    assert {:error, :value_too_large} =
             Concord.Local.put("pty:large", %{
               controller_pid: self(),
               data: String.duplicate("x", 200)
             })

    assert {:error, :not_found} = Concord.Local.get("pty:large")
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:concord, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:concord, key)
end
