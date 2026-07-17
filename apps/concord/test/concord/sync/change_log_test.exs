defmodule Concord.Sync.ChangeLogTest do
  use ExUnit.Case, async: false

  alias Concord.Sync.{ChangeLog, Event}

  setup do
    ChangeLog.ensure_table()
    :ets.delete_all_objects(:concord_change_log)
    :ok
  end

  describe "append/1" do
    test "stores events in table" do
      events = [
        %Event{type: :put, key: "k1", revision: 1, record: nil, prev_record: nil},
        %Event{type: :put, key: "k2", revision: 2, record: nil, prev_record: nil}
      ]

      assert :ok = ChangeLog.append(events)
      assert :ets.info(:concord_change_log, :size) == 2
    end
  end

  describe "changes/3" do
    test "returns events in revision range" do
      for i <- 1..5 do
        ChangeLog.append([
          %Event{type: :put, key: "k#{i}", revision: i, record: nil, prev_record: nil}
        ])
      end

      results = ChangeLog.changes(2, 4)
      assert length(results) == 3
      revisions = Enum.map(results, & &1.revision)
      assert revisions == [2, 3, 4]
    end

    test "returns empty list for no matches" do
      assert ChangeLog.changes(100, 200) == []
    end

    test "respects limit" do
      for i <- 1..10 do
        ChangeLog.append([
          %Event{type: :put, key: "k#{i}", revision: i, record: nil, prev_record: nil}
        ])
      end

      results = ChangeLog.changes(1, 10, limit: 3)
      assert length(results) == 3
    end
  end

  describe "earliest_revision/0" do
    test "returns 0 for empty log" do
      assert ChangeLog.earliest_revision() == 0
    end

    test "returns first revision" do
      ChangeLog.append([
        %Event{type: :put, key: "k", revision: 5, record: nil, prev_record: nil}
      ])

      ChangeLog.append([
        %Event{type: :put, key: "k", revision: 10, record: nil, prev_record: nil}
      ])

      assert ChangeLog.earliest_revision() == 5
    end
  end

  describe "compact/1" do
    test "removes events before keep_revision" do
      for i <- 1..10 do
        ChangeLog.append([
          %Event{type: :put, key: "k#{i}", revision: i, record: nil, prev_record: nil}
        ])
      end

      deleted = ChangeLog.compact(5)
      assert deleted == 4

      assert ChangeLog.earliest_revision() == 5
      remaining = ChangeLog.changes(1, 10)
      assert length(remaining) == 6
    end
  end
end
