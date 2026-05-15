defmodule Concord.KV.RecordTest do
  use ExUnit.Case, async: true

  alias Concord.KV.Record

  describe "struct defaults" do
    test "has correct default values" do
      record = %Record{}
      assert record.value == nil
      assert record.version == 0
      assert record.metadata == %{}
      assert record.expires_at == nil
      assert record.lease_id == nil
      assert record.content_type == nil
    end
  end

  describe "tombstone?/1" do
    test "returns true for version 0" do
      record = %Record{version: 0}
      assert Record.tombstone?(record) == true
    end

    test "returns false for version > 0" do
      record = %Record{version: 1}
      assert Record.tombstone?(record) == false
    end

    test "returns false for version > 1" do
      record = %Record{version: 5}
      assert Record.tombstone?(record) == false
    end
  end

  describe "expired?/2" do
    test "returns false when expires_at is nil" do
      record = %Record{expires_at: nil}
      assert Record.expired?(record, 1_000_000) == false
    end

    test "returns true when past expiration" do
      record = %Record{expires_at: 1000}
      assert Record.expired?(record, 1001) == true
    end

    test "returns false when before expiration" do
      record = %Record{expires_at: 1000}
      assert Record.expired?(record, 999) == false
    end

    test "returns false when exactly at expiration" do
      record = %Record{expires_at: 1000}
      assert Record.expired?(record, 1000) == false
    end
  end

  describe "tombstone/3" do
    test "creates tombstone from existing record" do
      prev = %Record{
        value: "old",
        create_revision: 5,
        mod_revision: 10,
        version: 3
      }

      tombstone = Record.tombstone("key", 15, prev)

      assert tombstone.value == nil
      assert tombstone.version == 0
      assert tombstone.create_revision == 5
      assert tombstone.mod_revision == 15
      assert tombstone.expires_at == nil
      assert tombstone.lease_id == nil
    end

    test "creates tombstone when prev_record is nil" do
      tombstone = Record.tombstone("key", 10, nil)

      assert tombstone.value == nil
      assert tombstone.version == 0
      assert tombstone.create_revision == 10
      assert tombstone.mod_revision == 10
    end
  end
end
