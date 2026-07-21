defmodule Concord.TursoEngineTest do
  use ExUnit.Case, async: false

  alias Concord.KV.Record

  @moduletag :tmp_dir

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:db_connection)
    {:ok, _} = Application.ensure_all_started(:ex_turso)
    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    stop_turso_pool()

    db_path = Path.join(tmp_dir, "concord_turso.db")
    start_supervised!({Elixir.Turso, database: db_path, name: Concord.Turso.DB, pool_size: 1})

    on_exit(fn -> stop_turso_pool() end)

    %{db_path: db_path}
  end

  test "runs migrations idempotently and reports status" do
    assert :ok = Concord.Turso.Migrations.migrate()
    assert :ok = Concord.Turso.Migrations.migrate()

    assert {:ok, %{engine: :turso, storage: %{size: 0, revision: 0}, node: node}} =
             Concord.Turso.status()

    assert node == node()
  end

  test "stores, reads, deletes, and isolates values from the VSR engine" do
    key = unique_key("crud")

    assert :ok = Concord.Turso.put(key, %{source: :turso})
    assert {:ok, %{source: :turso}} = Concord.Turso.get(key)
    assert Concord.get(key) in [{:error, :cluster_not_ready}, {:error, :not_found}]

    assert :ok = Concord.Turso.delete(key)
    assert {:error, :not_found} = Concord.Turso.get(key)
  end

  test "supports TTL, touch, and batch APIs" do
    prefix = unique_key("batch")
    a = prefix <> ":a"
    b = prefix <> ":b"

    assert :ok = Concord.Turso.put_with_ttl(a, "a", 60)
    assert {:ok, ttl} = Concord.Turso.ttl(a)
    assert ttl > 0

    assert :ok = Concord.Turso.touch(a, 120)
    assert {:ok, touched_ttl} = Concord.Turso.ttl(a)
    assert touched_ttl > ttl

    assert {:ok, %{^a => :ok, ^b => :ok}} = Concord.Turso.put_many([{a, "a2"}, {b, "b"}])
    assert {:ok, %{^a => {:ok, "a2"}, ^b => {:ok, "b"}}} = Concord.Turso.get_many([a, b])
    assert {:ok, [{^a, "a2"}, {^b, "b"}]} = Concord.Turso.prefix_scan(prefix)
    assert {:ok, %{^a => :ok, ^b => :ok}} = Concord.Turso.delete_many([a, b])
  end

  test "supports revisioned KV reads, history, and list" do
    key = unique_key("kv")

    assert {:ok, %{revision: rev1}} = Concord.KV.put(key, "v1", engine: :turso)

    assert {:ok, %{revision: rev2, prev_kv: %Record{value: "v1"}}} =
             Concord.KV.put(key, "v2", engine: :turso, prev_kv: true)

    assert rev2 > rev1
    assert {:ok, "v1"} = Concord.KV.get(key, engine: :turso, revision: rev1)

    assert {:ok, %Record{value: "v2", version: 2, mod_revision: ^rev2}} =
             Concord.KV.get(key, engine: :turso, metadata: true)

    assert {:ok, [%Record{value: "v1"}, %Record{value: "v2"}]} =
             Concord.KV.history(key, engine: :turso)

    assert {:ok, [%{key: ^key, value: "v2"}], %{has_more: false, last_key: ^key}} =
             Concord.KV.list(engine: :turso, prefix: key)
  end

  test "supports transactions" do
    key = unique_key("txn")

    spec = %{
      compare: [{:exists, key, :==, false}],
      success: [{:put, key, "created", %{}}],
      failure: [{:get, {:key, key}, %{}}]
    }

    assert {:ok, %Concord.Txn.Result{succeeded: true, revision: rev}} =
             Concord.Turso.txn(spec)

    assert rev > 0
    assert {:ok, "created"} = Concord.KV.get(key, engine: :turso)

    assert {:ok,
            %Concord.Txn.Result{succeeded: false, responses: [{:get, {:key, ^key}, %{count: 1}}]}} =
             Concord.Turso.txn(spec)
  end

  test "persists and resolves idempotent transaction results" do
    key = unique_key("idempotent-txn")
    request_key = unique_key("request")

    spec = %{
      compare: [],
      success: [{:put, key, "first", %{}}],
      failure: []
    }

    assert {:ok, %Concord.Txn.Result{} = first} =
             Concord.Turso.txn(spec, idempotency_key: request_key)

    assert {:ok, ^first} = Concord.Turso.txn(spec, idempotency_key: request_key)
    assert {:ok, ^first} = Concord.Txn.resolve(request_key, engine: :turso)

    conflicting = put_in(spec, [:success], [{:put, key, "second", %{}}])

    assert {:error, :idempotency_conflict} =
             Concord.Turso.txn(conflicting, idempotency_key: request_key)

    assert {:ok, "first"} = Concord.Turso.get(key)
  end

  test "returns explicit errors for unsupported Turso operations" do
    assert {:error, {:unsupported_operation, :turso, :create_index}} =
             Concord.Index.create("turso-idx", {:identity}, engine: :turso)

    assert {:error, {:unsupported_operation, :turso, :grant_lease}} =
             Concord.Lease.grant(60, engine: :turso)
  end

  defp unique_key(prefix) do
    "test:turso:#{prefix}:#{System.unique_integer([:positive, :monotonic])}"
  end

  defp stop_turso_pool do
    case Process.whereis(Concord.Turso.DB) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  catch
    :exit, _ -> :ok
  end
end
