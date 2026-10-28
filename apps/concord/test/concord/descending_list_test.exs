defmodule Concord.DescendingListTest do
  use ExUnit.Case, async: false

  alias Concord.Engine.Local
  alias Concord.KV

  setup %{engine: engine} do
    case engine do
      :local ->
        if is_nil(Process.whereis(Local)), do: start_supervised!({Local, []})
        :ok = Local.reset()

      :vsr ->
        :ok = Concord.TestHelper.start_test_cluster()
        on_exit(&Concord.TestHelper.stop_test_cluster/0)
    end

    :ok
  end

  for engine <- [:local, :vsr] do
    @tag engine: engine
    test "public #{engine} descending pages preserve revision continuity after mutations" do
      engine = unquote(engine)
      keys = ["descending/a", "descending/a" <> <<0>>, "descending/m", "descending/z"]

      for key <- Enum.reverse(keys) do
        assert {:ok, %{revision: _}} =
                 KV.put(key, key, engine: engine, metadata: %{source: "fixture"})
      end

      assert {:ok, revision} = KV.revision(engine: engine)

      assert {:ok, [first], %{has_more: true, last_key: "descending/z"}} =
               KV.list(
                 engine: engine,
                 prefix: "descending/",
                 revision: revision,
                 order: :desc,
                 limit: 1
               )

      assert first.metadata == %{source: "fixture"}
      assert {:ok, %{revision: _}} = KV.delete("descending/m", engine: engine)
      assert {:ok, %{revision: _}} = KV.put("descending/a", "changed", engine: engine)
      assert {:ok, %{revision: _}} = KV.put("descending/y", "new", engine: engine)

      assert {:ok, remaining, %{has_more: false, last_key: "descending/a"}} =
               KV.list(
                 engine: engine,
                 range: {"descending/", first.key},
                 revision: revision,
                 order: :desc,
                 keys_only: true,
                 limit: 3
               )

      assert Enum.map(remaining, & &1.key) == Enum.take(keys, 3) |> Enum.reverse()
      assert Enum.all?(remaining, &is_nil(&1.value))

      assert Enum.all?(
               remaining,
               &(&1.mod_revision <= revision and &1.metadata == %{source: "fixture"})
             )

      assert {:ok, current, _} = KV.list(engine: engine, prefix: "descending/", order: :desc)

      assert Enum.map(current, & &1.key) == [
               "descending/z",
               "descending/y",
               "descending/a" <> <<0>>,
               "descending/a"
             ]

      assert {:ok, ascending, _} = KV.list(engine: engine, prefix: "descending/")
      assert Enum.map(ascending, & &1.key) == Enum.sort(Enum.map(current, & &1.key))

      assert {:error, :invalid_order} =
               KV.list(engine: engine, prefix: "descending/", order: :reverse)

      assert {:error, :unsupported_query} =
               Concord.Engine.query({:list, {:prefix, "descending/"}, %{order: :reverse}},
                 engine: engine
               )
    end
  end
end
