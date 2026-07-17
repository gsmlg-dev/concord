defmodule Concord.TxnIntegrationTest do
  use ExUnit.Case, async: false

  alias Concord.KV.Record
  alias Concord.Txn
  alias Concord.Txn.Result

  setup do
    :ok = Concord.TestHelper.start_test_cluster()

    on_exit(fn ->
      Concord.TestHelper.stop_test_cluster()
    end)

    :ok
  end

  describe "txn: basic commit" do
    test "empty transaction succeeds" do
      result = Txn.commit(%{compare: [], success: [], failure: []})

      assert {:ok, %Result{succeeded: true}} = result
    end

    test "unconditional put in success branch" do
      result =
        Txn.commit(%{
          compare: [],
          success: [{:put, "txn_k1", "hello", %{}}],
          failure: []
        })

      assert {:ok, %Result{succeeded: true, responses: responses}} = result
      assert length(responses) == 1
      assert {:put, "txn_k1", %{prev_kv: nil}} = hd(responses)

      # Verify the key was written
      assert {:ok, "hello"} = Concord.get("txn_k1")
    end

    test "returns revision" do
      {:ok, %Result{revision: rev}} =
        Txn.commit(%{
          compare: [],
          success: [{:put, "txn_rev", "v", %{}}],
          failure: []
        })

      assert is_integer(rev) and rev > 0
    end
  end

  describe "txn: compare predicates" do
    test "exists compare — key exists" do
      Concord.put("exists_key", "value")

      {:ok, result} =
        Txn.commit(%{
          compare: [{:exists, "exists_key", :==, true}],
          success: [{:get, {:key, "exists_key"}, %{}}],
          failure: []
        })

      assert result.succeeded == true
    end

    test "exists compare — key does not exist" do
      {:ok, result} =
        Txn.commit(%{
          compare: [{:exists, "no_key", :==, false}],
          success: [{:put, "no_key", "created", %{}}],
          failure: []
        })

      assert result.succeeded == true
      assert {:ok, "created"} = Concord.get("no_key")
    end

    test "exists compare fails → runs failure branch" do
      {:ok, result} =
        Txn.commit(%{
          compare: [{:exists, "ghost", :==, true}],
          success: [{:put, "ghost", "should_not_exist", %{}}],
          failure: []
        })

      assert result.succeeded == false
      assert {:error, :not_found} = Concord.get("ghost")
    end

    test "version compare" do
      Concord.put("vk", "v1")
      Concord.put("vk", "v2")

      {:ok, result} =
        Txn.commit(%{
          compare: [{:version, "vk", :==, 2}],
          success: [{:put, "vk", "v3", %{}}],
          failure: []
        })

      assert result.succeeded == true
    end

    test "mod_revision compare" do
      Concord.put("mr_key", "value")
      [{_, rec}] = :ets.lookup(:concord_current, "mr_key")

      {:ok, result} =
        Txn.commit(%{
          compare: [{:mod_revision, "mr_key", :==, rec.mod_revision}],
          success: [{:put, "mr_key", "updated", %{}}],
          failure: []
        })

      assert result.succeeded == true
    end

    test "value compare" do
      Concord.put("val_cmp", "expected")

      {:ok, result} =
        Txn.commit(%{
          compare: [{:value, "val_cmp", :==, "expected"}],
          success: [{:put, "val_cmp", "new", %{}}],
          failure: []
        })

      assert result.succeeded == true
      assert {:ok, "new"} = Concord.get("val_cmp")
    end

    test "multiple compares — all must pass (AND semantics)" do
      Concord.put("multi_a", "a")
      Concord.put("multi_b", "b")

      {:ok, result} =
        Txn.commit(%{
          compare: [
            {:exists, "multi_a", :==, true},
            {:exists, "multi_b", :==, true},
            {:exists, "multi_c", :==, false}
          ],
          success: [{:put, "multi_c", "c", %{}}],
          failure: []
        })

      assert result.succeeded == true
    end

    test "multiple compares — one fails → failure branch" do
      Concord.put("mc_a", "a")

      {:ok, result} =
        Txn.commit(%{
          compare: [
            {:exists, "mc_a", :==, true},
            {:exists, "mc_missing", :==, true}
          ],
          success: [{:put, "mc_bad", "should_not_exist", %{}}],
          failure: []
        })

      assert result.succeeded == false
      assert {:error, :not_found} = Concord.get("mc_bad")
    end
  end

  describe "txn: operations" do
    test "get operation returns records" do
      Concord.put("get_op", "hello")

      {:ok, result} =
        Txn.commit(%{
          compare: [],
          success: [{:get, {:key, "get_op"}, %{}}],
          failure: []
        })

      assert result.succeeded == true
      [{:get, {:key, "get_op"}, %{kvs: kvs, count: count}}] = result.responses
      assert count == 1
      assert length(kvs) == 1
    end

    test "get missing key returns empty" do
      {:ok, result} =
        Txn.commit(%{
          compare: [],
          success: [{:get, {:key, "no_op"}, %{}}],
          failure: []
        })

      [{:get, {:key, "no_op"}, %{kvs: [], count: 0}}] = result.responses
    end

    test "put with prev_kv" do
      Concord.put("prev_k", "old")

      {:ok, result} =
        Txn.commit(%{
          compare: [],
          success: [{:put, "prev_k", "new", %{prev_kv: true}}],
          failure: []
        })

      [{:put, "prev_k", %{prev_kv: prev}}] = result.responses
      assert %Record{} = prev
      assert prev.version == 1
    end

    test "delete operation" do
      Concord.put("del_op", "victim")

      {:ok, result} =
        Txn.commit(%{
          compare: [],
          success: [{:delete, {:key, "del_op"}, %{}}],
          failure: []
        })

      [{:delete, {:key, "del_op"}, %{deleted: 1}}] = result.responses
      assert {:error, :not_found} = Concord.get("del_op")
    end

    test "delete by prefix" do
      Concord.put("/batch/1", "a")
      Concord.put("/batch/2", "b")
      Concord.put("/batch/3", "c")
      Concord.put("/keep/1", "x")

      {:ok, result} =
        Txn.commit(%{
          compare: [],
          success: [{:delete, {:prefix, "/batch/"}, %{}}],
          failure: []
        })

      [{:delete, {:prefix, "/batch/"}, %{deleted: deleted}}] = result.responses
      assert deleted == 3
      assert {:error, :not_found} = Concord.get("/batch/1")
      assert {:ok, "x"} = Concord.get("/keep/1")
    end

    test "multi-op transaction" do
      {:ok, result} =
        Txn.commit(%{
          compare: [],
          success: [
            {:put, "m1", "v1", %{}},
            {:put, "m2", "v2", %{}},
            {:get, {:key, "m1"}, %{}}
          ],
          failure: []
        })

      assert result.succeeded == true
      assert length(result.responses) == 3

      # Read-your-writes: get m1 should see the value we just put
      {:get, {:key, "m1"}, %{kvs: kvs}} = Enum.at(result.responses, 2)
      assert length(kvs) == 1
    end
  end

  describe "txn: create-if-absent pattern" do
    test "creates key when absent" do
      {:ok, result} =
        Txn.commit(%{
          compare: [{:exists, "atomic_create", :==, false}],
          success: [{:put, "atomic_create", "created!", %{}}],
          failure: [{:get, {:key, "atomic_create"}, %{}}]
        })

      assert result.succeeded == true
      assert {:ok, "created!"} = Concord.get("atomic_create")
    end

    test "fails when key already exists" do
      Concord.put("atomic_create2", "existing")

      {:ok, result} =
        Txn.commit(%{
          compare: [{:exists, "atomic_create2", :==, false}],
          success: [{:put, "atomic_create2", "overwrite", %{}}],
          failure: [{:get, {:key, "atomic_create2"}, %{}}]
        })

      assert result.succeeded == false
      assert {:ok, "existing"} = Concord.get("atomic_create2")
    end
  end

  describe "txn: validation" do
    test "rejects spec with functions" do
      result =
        Txn.commit(%{
          compare: [],
          success: [{:put, "k", fn -> :bad end, %{}}],
          failure: []
        })

      assert {:error, :function_in_spec} = result
    end

    test "rejects invalid compare field" do
      result =
        Txn.commit(%{
          compare: [{:bad, "k", :==, true}],
          success: [],
          failure: []
        })

      assert {:error, {:invalid_txn, _}} = result
    end
  end
end
