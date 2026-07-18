defmodule ViewstampedReplication.LogTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Log, LogEntry}

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
