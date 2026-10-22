defmodule ViewstampedReplication.LogTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Log, LogEntry}
  alias ViewstampedReplication.Log.Indexed

  test "appends and retrieves contiguous entries" do
    first = entry(1)
    second = entry(2)

    assert {:ok, log} = Log.new([first, second])
    assert Log.last_op_number(log) == 2
    assert Log.last(log) == second
    assert {:ok, ^first} = Log.fetch(log, 1)
    assert [^first, ^second] = Log.to_list(log)
  end

  test "rejects gaps and duplicate positions" do
    assert {:error, {:non_contiguous_op_number, 1, 2}} = Log.append(Log.new(), entry(2))

    assert {:ok, log} = Log.append(Log.new(), entry(1))
    assert {:error, {:non_contiguous_op_number, 2, 1}} = Log.append(log, entry(1))
  end

  test "returns and truncates suffixes by operation number" do
    first = entry(1)
    second = entry(2)
    third = entry(3)
    assert {:ok, log} = Log.new([first, second, third])

    assert [^second, ^third] = Log.suffix(log, 1)
    assert [^first] = log |> Log.truncate_suffix(1) |> Log.to_list()
    assert Log.last_op_number(Log.truncate_suffix(log, 0)) == 0
  end

  test "compacts a prefix while preserving absolute operation numbers" do
    assert {:ok, log} = Log.new([entry(1), entry(2), entry(3)])
    assert {:ok, compacted} = Log.compact(log, 2)

    assert %Log{base_op_number: 2, entries: [third]} = compacted
    assert third.op_number == 3
    assert Log.last_op_number(compacted) == 3
    assert Log.fetch(compacted, 1) == :compacted
    assert Log.fetch(compacted, 2) == :compacted
    assert {:ok, ^third} = Log.fetch(compacted, 3)

    assert {:ok, installed} = Log.new(2, [entry(3)])
    assert installed == compacted
  end

  test "indexed logs preserve public log operations without copying the retained prefix" do
    first = entry(11)
    second = entry(12)
    third = entry(13)
    assert {:ok, canonical} = Log.new(10, [first, second])
    indexed = Log.indexed(canonical)
    assert %Indexed{base_op_number: 10, last_op_number: 12} = indexed
    assert Log.canonical(indexed) == canonical
    assert Log.fetch(indexed, 10) == :compacted
    assert Log.fetch(indexed, 14) == :error
    assert Log.fetch!(indexed, 11) == first
    assert Log.last(indexed) == second
    assert Log.last_op_number(indexed) == 12
    assert {:ok, appended} = Log.append(indexed, third)
    assert Log.to_list(appended) == [first, second, third]
    assert Log.to_list(indexed) == [first, second]
    assert Log.suffix(appended, 11) == [second, third]
    assert Log.to_list(Log.truncate_suffix(appended, 11)) == [first]
    assert Log.last_op_number(Log.truncate_suffix(appended, 0)) == 10
    assert {:ok, compacted} = Log.compact(appended, 12)
    assert Log.canonical(compacted) == %Log{base_op_number: 12, entries: [third]}
    assert Log.compact(appended, 9) == {:error, {:snapshot_before_compacted_prefix, 10, 9}}
    assert Log.compact(appended, 14) == {:error, {:snapshot_ahead_of_log, 13, 14}}
    assert Log.append(indexed, first) == {:error, {:non_contiguous_op_number, 13, 11}}
    assert_raise KeyError, fn -> Log.fetch!(indexed, 10) end
    assert_raise KeyError, fn -> Log.fetch!(indexed, 14) end
    assert_raise ArgumentError, fn -> Log.append!(indexed, first) end
    assert Log.canonical(Log.indexed(Log.new())) == Log.new()
    assert Log.last(Log.indexed(Log.new())) == nil
  end

  test "canonical conversion rejects forged indexed bounds, keys and positions" do
    indexed = Log.indexed(%Log{entries: [entry(1), entry(2)]})

    for invalid <- [
          %{indexed | base_op_number: -1},
          %{indexed | last_op_number: 0},
          %{indexed | entries: nil},
          %{indexed | entries: Map.delete(indexed.entries, 1)},
          %{indexed | entries: Map.put(indexed.entries, 3, entry(3))},
          %{indexed | entries: Map.put(indexed.entries, 1, entry(2))},
          %{indexed | entries: %{1 => entry(1), :wrong => entry(2)}}
        ] do
      assert_raise ArgumentError, "invalid indexed log", fn -> Log.canonical(invalid) end
    end
  end

  test "list construction validates entries in a single pass" do
    assert Log.new(3, [entry(4), entry(6)]) == {:error, {:non_contiguous_op_number, 5, 6}}
    assert Log.new([:invalid]) == {:error, {:invalid_log_entry, :invalid}}
  end

  defp entry(op_number) do
    %LogEntry{
      view_number: 0,
      op_number: op_number,
      client_id: :client,
      request_number: op_number,
      operation: {:write, op_number}
    }
  end
end
