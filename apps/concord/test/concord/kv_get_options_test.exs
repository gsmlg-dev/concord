defmodule Concord.KVGetOptionsTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Concord.KV.Record

  @moduletag :tmp_dir

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ex_turso)
    :ok
  end

  setup %{engine: engine, tmp_dir: tmp_dir} do
    case engine do
      :local ->
        if Process.whereis(Concord.Engine.Local) == nil do
          start_supervised!({Concord.Engine.Local, []})
        end

        :ok = Concord.Engine.Local.reset()

      :turso ->
        stop_turso_pool()

        start_supervised!(
          {Elixir.Turso,
           database: Path.join(tmp_dir, "get_options.db"), name: Concord.Turso.DB, pool_size: 1}
        )

        on_exit(&stop_turso_pool/0)

      :vsr ->
        :ok = Concord.TestHelper.start_test_cluster()
        on_exit(&Concord.TestHelper.stop_test_cluster/0)
    end

    %{opts: [engine: engine]}
  end

  for engine <- [:local, :turso, :vsr] do
    @tag engine: engine
    test "#{engine}: a non-nil revision returns the historical value even with metadata", %{
      opts: opts
    } do
      for compress <- [false, true] do
        key = "options/#{compress}"
        original = %{text: String.duplicate("original", 500)}

        assert {:ok, %{revision: first}} =
                 KV.put(key, original, opts ++ [metadata: %{generation: 1}, compress: compress])

        assert {:ok, %{revision: second}} =
                 KV.put(key, :later, opts ++ [metadata: %{generation: 2}, compress: compress])

        for metadata <- [false, true] do
          assert {:ok, ^original} =
                   KV.get(key, opts ++ [revision: first, metadata: metadata])
        end

        assert {:ok,
                %Record{
                  value: :later,
                  create_revision: ^first,
                  mod_revision: ^second,
                  version: 2,
                  metadata: %{generation: 2}
                } = current} = KV.get(key, opts ++ [metadata: true])

        assert {:ok, ^current} = KV.get(key, opts ++ [metadata: true, revision: nil])
      end
    end

    @tag engine: engine
    test "#{engine}: historical list Records and selected point values share the captured revision",
         %{
           opts: opts
         } do
      key = "snapshot/a"
      value = %{text: "snapshot"}

      assert {:ok, %{revision: created}} = KV.put(key, :first, opts)

      assert {:ok, %{revision: modified}} =
               KV.put(
                 key,
                 value,
                 opts ++
                   [metadata: %{generation: 2}, content_type: "application/json", ttl: 3_600]
               )

      assert {:ok, %Record{expires_at: expires_at}} = KV.get(key, opts ++ [metadata: true])
      assert {:ok, _} = KV.put("snapshot/b", :deleted_later, opts)
      assert {:ok, revision} = KV.revision(opts)
      assert revision > modified

      assert {:ok, _} = KV.put(key, :later, opts ++ [metadata: %{generation: 3}])
      assert {:ok, _} = KV.delete("snapshot/b", opts)
      assert {:ok, _} = KV.put("snapshot/c", :added_later, opts)

      assert {:ok,
              [
                %Record{
                  value: nil,
                  create_revision: ^created,
                  mod_revision: ^modified,
                  version: 2,
                  expires_at: ^expires_at,
                  content_type: "application/json",
                  metadata: %{generation: 2}
                } = head,
                tail
              ],
              %{has_more: false}} =
               KV.list(opts ++ [prefix: "snapshot/", revision: revision, keys_only: true])

      assert head.key == key
      assert tail.key == "snapshot/b"
      assert {:ok, ^value} = KV.get(head.key, opts ++ [revision: revision])
      assert {:ok, :deleted_later} = KV.get(tail.key, opts ++ [revision: revision])
    end

    @tag engine: engine
    test "#{engine}: metadata does not substitute current Records for absent historical values",
         %{
           opts: opts,
           engine: engine
         } do
      key = "lifecycle/key"
      assert {:ok, _} = KV.put("unrelated/key", :seed, opts)
      assert {:ok, %{revision: created}} = KV.put(key, :original, opts)
      assert {:ok, %{revision: deleted}} = KV.delete(key, opts)
      assert {:ok, _} = KV.put(key, :recreated, opts)

      for revision <- [created - 1, deleted] do
        assert {:error, :not_found} = KV.get(key, opts ++ [revision: revision, metadata: true])
      end

      zero_error = if engine == :turso, do: {:error, :not_found}, else: {:error, {:compacted, 0}}

      for metadata <- [false, true] do
        assert ^zero_error = KV.get(key, opts ++ [revision: 0, metadata: metadata])
      end

      assert {:ok, :original} = KV.get(key, opts ++ [revision: created, metadata: true])
      assert {:ok, %Record{value: :recreated}} = KV.get(key, opts ++ [metadata: true])
    end
  end

  defp stop_turso_pool do
    case Process.whereis(Concord.Turso.DB) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  catch
    :exit, _reason -> :ok
  end
end
