defmodule Concord.EngineTest do
  use ExUnit.Case, async: false

  setup do
    clear_ets_tables()

    on_exit(fn ->
      clear_ets_tables()
    end)

    :ok
  end

  describe "local API" do
    setup do
      case Process.whereis(Concord.Engine.Local) do
        nil -> start_supervised!({Concord.Engine.Local, []})
        _pid -> Concord.Engine.Local.reset()
      end

      :ok
    end

    test "stores data on the current node without a Raft cluster" do
      assert :ok = Concord.Local.put("local:key", %{value: 1})
      assert {:ok, %{value: 1}} = Concord.Local.get("local:key")

      assert {:error, :cluster_not_ready} = Concord.get("local:key")

      assert {:ok, [{:kv_local, member_node}]} = Concord.Local.members()
      assert member_node == node()

      assert {:ok, %{engine: :kv_local, storage: %{size: 1}, node: current_node}} =
               Concord.Local.status()

      assert current_node == node()
      assert :ets.lookup(:concord_local_store, "local:key") != []
      assert cluster_lookup("local:key") == []
    end

    test "supports the local Concord.KV API" do
      assert {:ok, %{revision: revision}} = Concord.Local.KV.put("local:kv", "value")
      assert revision > 0
      assert {:ok, "value"} = Concord.Local.KV.get("local:kv")

      assert {:ok, result} =
               Concord.Local.KV.create("local:create", %{created: true})

      assert result.succeeded == true
      assert {:ok, %{created: true}} = Concord.Local.KV.get("local:create")
    end

    test "supports local transactions" do
      spec = %{
        compare: [{:exists, "local:txn", :==, false}],
        success: [{:put, "local:txn", "created", %{}}],
        failure: []
      }

      assert {:ok, %{succeeded: true}} = Concord.Local.Txn.commit(spec)
      assert {:ok, "created"} = Concord.Local.KV.get("local:txn")
    end

    test "keeps conditional helper reads on the local engine" do
      assert :ok = Concord.Local.put("local:counter", 1)

      assert :ok =
               Concord.Local.put_if("local:counter", 2, condition: fn current -> current == 1 end)

      assert {:ok, 2} = Concord.Local.get("local:counter")
      assert cluster_lookup("local:counter") == []
    end
  end

  describe "turso API" do
    test "returns an explicit error when the Turso pool is not started" do
      assert {:error, :engine_not_started} = Concord.Turso.put("turso:key", "value")
      assert {:error, :engine_not_started} = Concord.Turso.status()
    end
  end

  defp cluster_lookup(key) do
    case :ets.whereis(:concord_store) do
      :undefined -> []
      _ -> :ets.lookup(:concord_store, key)
    end
  end

  defp clear_ets_tables do
    Enum.each(
      [
        :concord_store,
        :concord_current,
        :concord_history,
        :concord_leases,
        :concord_local_store,
        :concord_local_current,
        :concord_local_history,
        :concord_local_leases
      ],
      fn table ->
        case :ets.whereis(table) do
          :undefined -> :ok
          _ -> :ets.delete_all_objects(table)
        end
      end
    )
  end
end
