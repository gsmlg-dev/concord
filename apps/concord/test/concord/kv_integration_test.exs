defmodule Concord.KV.IntegrationTest do
  use ExUnit.Case, async: false

  alias Concord.KV.Record

  setup do
    :ok = Concord.TestHelper.start_test_cluster()

    on_exit(fn ->
      Concord.TestHelper.stop_test_cluster()
    end)

    :ok
  end

  # Helper to run a Ra query using the correct MFA format
  defp ra_query(query_term) do
    mfa = {Concord.StateMachine, :query, [query_term]}

    case :ra.leader_query({:concord_cluster, node()}, mfa) do
      {:ok, {{_, _}, result}, _} -> result
      {:ok, result, _} -> result
      error -> error
    end
  end

  describe "v2 put with map opts" do
    test "put returns revision info" do
      result = Concord.put("v2_key", "value1")
      assert result == :ok

      # Verify the record was created in concord_current
      case :ets.lookup(:concord_current, "v2_key") do
        [{"v2_key", %Record{} = rec}] ->
          assert rec.version == 1
          assert rec.mod_revision > 0
          assert rec.create_revision > 0
          assert rec.create_revision == rec.mod_revision

        _ ->
          flunk("Record not found in concord_current")
      end
    end

    test "put updates version on overwrite" do
      Concord.put("ver_key", "v1")
      Concord.put("ver_key", "v2")

      case :ets.lookup(:concord_current, "ver_key") do
        [{"ver_key", %Record{} = rec}] ->
          assert rec.version == 2

        _ ->
          flunk("Record not found")
      end
    end

    test "put preserves create_revision on update" do
      Concord.put("cr_key", "v1")

      [{_, rec1}] = :ets.lookup(:concord_current, "cr_key")
      create_rev = rec1.create_revision

      Concord.put("cr_key", "v2")

      [{_, rec2}] = :ets.lookup(:concord_current, "cr_key")
      assert rec2.create_revision == create_rev
      assert rec2.mod_revision > create_rev
    end

    test "revision is monotonically increasing" do
      Concord.put("r1", "a")
      [{_, rec1}] = :ets.lookup(:concord_current, "r1")

      Concord.put("r2", "b")
      [{_, rec2}] = :ets.lookup(:concord_current, "r2")

      assert rec2.mod_revision > rec1.mod_revision
    end
  end

  describe "v2 delete with tombstones" do
    test "delete creates tombstone in history" do
      Concord.put("del_key", "value")
      [{_, rec}] = :ets.lookup(:concord_current, "del_key")
      put_rev = rec.mod_revision

      Concord.delete("del_key")

      # Key should be gone from current
      assert :ets.lookup(:concord_current, "del_key") == []

      # Original record should be in history
      case :ets.lookup(:concord_history, {"del_key", put_rev}) do
        [{_, %Record{version: v}}] -> assert v == 1
        _ -> flunk("Original record not in history at revision #{put_rev}")
      end

      # Tombstone should be in history
      history_entries =
        :ets.select(:concord_history, [
          {{{"del_key", :"$1"}, :"$2"}, [{:>, :"$1", put_rev}], [:"$2"]}
        ])

      assert length(history_entries) == 1
      [tombstone] = history_entries
      assert Record.tombstone?(tombstone)
    end

    test "delete of non-existent key is no-op" do
      result = Concord.delete("never_existed")
      assert result == :ok
    end
  end

  describe "v2 query: get_record" do
    test "returns full Record struct" do
      Concord.put("rec_key", "hello")

      result = ra_query({:get_record, "rec_key"})
      assert {:ok, %Record{} = rec} = result
      assert rec.version == 1
      assert rec.mod_revision > 0
    end

    test "returns error for missing key" do
      result = ra_query({:get_record, "no_such_key"})
      assert result == {:error, :not_found}
    end
  end

  describe "v2 query: get_revision" do
    test "returns current cluster revision" do
      Concord.put("rev_test", "value")

      result = ra_query(:get_revision)
      assert {:ok, rev} = result
      assert is_integer(rev) and rev > 0
    end
  end

  describe "v2 history in ETS" do
    test "put creates history entries on update" do
      Concord.put("hist_key", "v1")
      [{_, rec1}] = :ets.lookup(:concord_current, "hist_key")
      rev1 = rec1.mod_revision

      Concord.put("hist_key", "v2")

      # Previous version should be in history
      case :ets.lookup(:concord_history, {"hist_key", rev1}) do
        [{_, %Record{version: 1}}] -> :ok
        _ -> flunk("Previous record not found in history at revision #{rev1}")
      end
    end
  end

  describe "v2 list query" do
    test "list by prefix returns matching records" do
      Concord.put("/items/1", "a")
      Concord.put("/items/2", "b")
      Concord.put("/items/3", "c")
      Concord.put("/other/1", "d")

      result = ra_query({:list, {:prefix, "/items/"}, %{limit: 100}})
      assert {:ok, records, meta} = result
      assert length(records) == 3
      assert meta.has_more == false
    end

    test "list with limit returns has_more" do
      for i <- 1..5, do: Concord.put("/pg/#{i}", "v#{i}")

      result = ra_query({:list, {:prefix, "/pg/"}, %{limit: 2}})
      assert {:ok, records, meta} = result
      assert length(records) == 2
      assert meta.has_more == true
    end
  end
end
