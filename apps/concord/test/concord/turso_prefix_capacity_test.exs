defmodule Concord.TursoPrefixCapacityTest do
  use ExUnit.Case, async: false

  alias Concord.{CommandSchema, KV, Turso, Validation}
  alias Concord.KV.Record
  alias Concord.Turso.PrefixReplacement

  @moduletag :tmp_dir

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ex_turso)
    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    settings = [:max_batch_size, :max_command_bytes]
    original = Map.new(settings, &{&1, Application.fetch_env(:concord, &1)})
    stop_pool()

    start_supervised!(
      {Elixir.Turso,
       database: Path.join(tmp_dir, "prefix_capacity.db"), name: Concord.Turso.DB, pool_size: 1}
    )

    on_exit(fn ->
      stop_pool()

      for {key, setting} <- original do
        case setting do
          {:ok, value} -> Application.put_env(:concord, key, value)
          :error -> Application.delete_env(:concord, key)
        end
      end
    end)

    :ok
  end

  test "500 replacements and metadata publish together through full, shrinking and empty rewrites" do
    assert {:ok, %{revision: created}} = KV.put("capacity/001", :original, engine: :turso)
    assert {:ok, _} = KV.put("capacity/stale", :stale, engine: :turso)
    assert {:ok, _} = KV.put("capacity0", :outside, engine: :turso)
    assert {:ok, %{revision: before}} = KV.put("owner", %{generation: 1}, engine: :turso)
    assert {:ok, previous, _} = KV.list(engine: :turso, prefix: "capacity/")

    values =
      for n <- 1..500 do
        {"capacity/" <> String.pad_leading(Integer.to_string(n), 3, "0"), %{turn: n}}
      end

    puts = values ++ [{"owner", %{generation: 2}}]
    assert :erlang.external_size({:replace_prefix, "capacity/", puts, []}) < 64 * 1_024

    assert {:ok, %{succeeded: false, revision: ^before, deleted: 0, written: 0}} =
             Turso.replace_prefix("capacity/", puts,
               compare: [{:mod_revision, "owner", :==, before - 1}]
             )

    assert {:ok, ^previous, _} = KV.list(engine: :turso, prefix: "capacity/")
    assert {:ok, %{generation: 1}} = KV.get("owner", engine: :turso)

    assert {:ok, %{succeeded: true, revision: published, deleted: 1, written: 501}} =
             Turso.replace_prefix("capacity/", puts,
               compress: false,
               compare: [{:mod_revision, "owner", :==, before}]
             )

    assert published == before + 1

    assert {:ok, [retained | added] = records, %{has_more: false}} =
             KV.list(engine: :turso, prefix: "capacity/", limit: 1_000)

    assert Enum.map(records, &{&1.key, &1.value}) == values

    assert %Record{create_revision: ^created, mod_revision: ^published, version: 2} = retained

    assert Enum.all?(added, &(&1.create_revision == published and &1.mod_revision == published))

    assert {:ok, %Record{value: %{generation: 2}, mod_revision: ^published}} =
             KV.get("owner", engine: :turso, metadata: true)

    assert {:ok, ^previous, _} = KV.list(engine: :turso, prefix: "capacity/", revision: before)
    assert {:ok, %{generation: 1}} = KV.get("owner", engine: :turso, revision: before)

    assert {:ok, ^records, _} =
             KV.list(engine: :turso, prefix: "capacity/", revision: published, limit: 1_000)

    assert {:ok, %{succeeded: true, revision: shrunk, deleted: 499, written: 2}} =
             Turso.replace_prefix(
               "capacity/",
               [{"capacity/001", :shrunk}, {"owner", %{generation: 3}}],
               compare: [{:mod_revision, "owner", :==, published}]
             )

    assert shrunk == published + 1

    assert {:ok,
            [
              %Record{
                value: :shrunk,
                create_revision: ^created,
                mod_revision: ^shrunk,
                version: 3
              }
            ],
            _} =
             KV.list(engine: :turso, prefix: "capacity/")

    assert {:ok, ^records, _} =
             KV.list(engine: :turso, prefix: "capacity/", revision: published, limit: 1_000)

    assert {:ok, %{generation: 2}} = KV.get("owner", engine: :turso, revision: published)

    assert {:ok, %{succeeded: true, revision: emptied, deleted: 1, written: 1}} =
             Turso.replace_prefix("capacity/", [{"owner", %{generation: 4}}],
               compare: [{:mod_revision, "owner", :==, shrunk}]
             )

    assert emptied == shrunk + 1
    assert {:ok, [], _} = KV.list(engine: :turso, prefix: "capacity/", revision: emptied)

    assert {:ok, [%Record{value: :shrunk}], _} =
             KV.list(engine: :turso, prefix: "capacity/", revision: shrunk)

    assert {:ok, %{generation: 3}} = KV.get("owner", engine: :turso, revision: shrunk)
    assert {:ok, %{generation: 4}} = KV.get("owner", engine: :turso, revision: emptied)
    assert {:ok, :outside} = KV.get("capacity0", engine: :turso)

    assert {:ok, key_records, _} =
             KV.list(
               engine: :turso,
               prefix: "capacity/",
               revision: published,
               keys_only: true,
               limit: 1_000
             )

    assert key_records == Enum.map(records, &%{&1 | value: nil})
    assert {:ok, %{turn: 500}} = KV.get("capacity/500", engine: :turso, revision: published)
  end

  test "501 puts retain lower item and command caps while generic batches stay at 500" do
    puts = for n <- 1..500, do: {"capacity/#{n}", n}
    publication = puts ++ [{"owner", %{generation: 1}}]
    command = {:replace_prefix, "capacity/", publication, []}
    assert {:ok, ^command} = PrefixReplacement.prepare("capacity/", publication, compress: false)
    assert CommandSchema.max_batch_size() == 500
    assert Validation.max_batch_size() == 500
    assert {:error, :batch_too_large} = Turso.put_many(publication)

    Application.put_env(:concord, :max_batch_size, 1_000)
    assert :ok = PrefixReplacement.validate("capacity/", publication, [])

    assert {:error, :batch_too_large} =
             PrefixReplacement.validate(
               "capacity/",
               publication ++ [{"another-owner", :extra}],
               []
             )

    Application.put_env(:concord, :max_batch_size, 500)
    assert :ok = PrefixReplacement.validate("capacity/", puts, [])
    assert {:error, :batch_too_large} = PrefixReplacement.validate("capacity/", publication, [])
    Application.put_env(:concord, :max_batch_size, 1)
    assert :ok = PrefixReplacement.validate("capacity/", [{"owner", :one}], [])

    assert {:error, :batch_too_large} =
             PrefixReplacement.validate("capacity/", [{"owner", :one}, {"owner2", :two}], [])

    Application.put_env(:concord, :max_batch_size, :invalid)

    assert {:error, :batch_too_large} =
             PrefixReplacement.validate("capacity/", [{"owner", :one}], [])

    Application.delete_env(:concord, :max_batch_size)
    assert :ok = PrefixReplacement.validate("capacity/", publication, [])
    size = :erlang.external_size(command)
    Application.put_env(:concord, :max_command_bytes, size)
    assert :ok = PrefixReplacement.validate("capacity/", publication, [])
    Application.put_env(:concord, :max_command_bytes, size - 1)

    assert {:error, {:invalid_command, :command_too_large}} =
             PrefixReplacement.validate("capacity/", publication, [])
  end

  defp stop_pool do
    case Process.whereis(Concord.Turso.DB) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  catch
    :exit, _reason -> :ok
  end
end
