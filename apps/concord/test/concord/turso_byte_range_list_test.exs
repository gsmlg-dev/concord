defmodule Concord.TursoByteRangeListTest do
  use ExUnit.Case, async: false

  alias Concord.KV

  @moduletag :tmp_dir
  @db Concord.Turso.DB

  # UTF-8 keys are stored as SQL TEXT and other binaries as BLOB. Current-state
  # selections must still follow unsigned byte order across both storage classes.
  @inside ["range/a/one", "range/a/two", "range/a/" <> <<0xC3, 0x28>>, "range/a/" <> <<0xFF>>]
  @outside [
    "range/",
    "range/0",
    "range/a",
    "range/a0",
    "range/z/two",
    "range/" <> <<0xFF>>,
    "unrelated"
  ]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ex_turso)
    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    stop_pool()

    start_supervised!(
      {Elixir.Turso, database: Path.join(tmp_dir, "byte_range.db"), name: @db, pool_size: 1}
    )

    on_exit(&stop_pool/0)

    for key <- @inside ++ @outside do
      assert {:ok, _} = KV.put(key, %{key: key}, engine: :turso)
    end

    :ok
  end

  test "binary range and prefix pages select only keys in byte order" do
    prefix = "range/a/"
    expected = Enum.sort(@inside)

    for selector <- [[range: {prefix, prefix <> <<0xFF, 0xFF>>}], [prefix: prefix]],
        keys_only <- [false, true],
        order <- [:asc, :desc] do
      opts = selector ++ [engine: :turso, keys_only: keys_only, order: order, timeout: 5_000]
      ordered = if order == :desc, do: Enum.reverse(expected), else: expected

      assert {:ok, records, %{has_more: false}} = KV.list(opts ++ [limit: 100])
      assert Enum.map(records, & &1.key) == ordered, inspect(opts)

      assert paged_keys(opts, order) == ordered, inspect(opts)
    end
  end

  test "binary upper bounds exclude later text keys" do
    prefix = "range/a/"

    assert {:ok, records, %{has_more: false}} =
             KV.list(engine: :turso, range: {prefix, prefix <> <<255>>}, limit: 100)

    assert Enum.map(records, & &1.key) == Enum.sort(@inside -- ["range/a/" <> <<0xFF>>])
  end

  test "transaction range reads and deletes follow byte order" do
    selector = {:range, "range/a/", "range/a/" <> <<0xFF, 0xFF>>}

    assert {:ok, %Concord.Txn.Result{succeeded: true, responses: [get]}} =
             Concord.Turso.txn(%{
               compare: [],
               success: [{:get, selector, %{limit: 100}}],
               failure: []
             })

    assert {:get, ^selector, %{kvs: kvs}} = get
    assert kvs |> Enum.map(& &1.value.key) |> Enum.sort() == Enum.sort(@inside)

    assert {:ok, %Concord.Txn.Result{succeeded: true}} =
             Concord.Turso.txn(%{compare: [], success: [{:delete, selector, %{}}], failure: []})

    assert {:ok, remaining, %{has_more: false}} =
             KV.list(engine: :turso, range: {"", <<0xFF, 0xFF>>}, limit: 100)

    assert remaining |> Enum.map(& &1.key) |> Enum.sort() == Enum.sort(@outside)
  end

  defp paged_keys(opts, order) do
    {start_key, end_key} =
      case Keyword.fetch(opts, :range) do
        {:ok, range} -> range
        :error -> {Keyword.fetch!(opts, :prefix), Keyword.fetch!(opts, :prefix) <> <<0xFF, 0xFF>>}
      end

    page_keys(Keyword.drop(opts, [:range, :prefix]), start_key, end_key, order, [])
  end

  defp page_keys(opts, start_key, end_key, order, acc) do
    assert {:ok, records, %{has_more: has_more, last_key: last_key}} =
             KV.list(opts ++ [range: {start_key, end_key}, limit: 1])

    acc = acc ++ Enum.map(records, & &1.key)

    cond do
      not has_more -> acc
      order == :asc -> page_keys(opts, last_key <> <<0>>, end_key, order, acc)
      true -> page_keys(opts, start_key, last_key, order, acc)
    end
  end

  defp stop_pool do
    case Process.whereis(@db) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end
end
