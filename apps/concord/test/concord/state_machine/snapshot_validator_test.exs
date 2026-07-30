defmodule Concord.StateMachine.SnapshotValidatorTest do
  use ExUnit.Case, async: true

  alias Concord.KV.Record
  alias Concord.StateMachine.Core.State
  alias Concord.StateMachine.SnapshotValidator
  alias Concord.Txn.Result

  test "accepts a complete current state with coherent derived data" do
    record = %{record(2) | lease_id: 1}

    state = %State{
      store: %{"key" => %{value: "value", expires_at: nil}},
      current: %{"key" => record},
      history: %{{"key", 2} => record},
      leases: %{
        1 => %{id: 1, ttl: 30, expires_at: 1_030, granted_at: 1, keys: ["key"]}
      },
      indexes: %{"by-value" => {:identity}},
      index_entries: %{"by-value" => %{"value" => ["key"]}},
      requests: %{
        "request" => %{
          request_hash: :crypto.hash(:sha256, "request"),
          revision: 2,
          result: %Result{succeeded: true, revision: 2, responses: []},
          cached_at: 3
        }
      },
      command_count: 3,
      revision: 2,
      compact_revision: 1,
      next_lease_id: 2
    }

    assert :ok = SnapshotValidator.validate_v4(state)
  end

  test "legacy validation admits historical indexes while current validation rejects them" do
    state = %State{
      representation: :legacy,
      indexes: %{atom_name: fn value -> value end},
      index_entries: %{atom_name: %{}}
    }

    assert :ok = SnapshotValidator.validate_legacy_v4(state)

    assert {:error, {:invalid_index_definition, :atom_name}} =
             SnapshotValidator.validate_v4(state)
  end

  test "rejects runtime-identity index names" do
    unsafe_name = self()

    assert {:error, {:invalid_index_definition, ^unsafe_name}} =
             SnapshotValidator.validate_v4(%State{
               indexes: %{unsafe_name => {:identity}},
               index_entries: %{unsafe_name => %{}}
             })
  end

  test "rejects missing state and nested record fields" do
    missing_state_field = %State{} |> Map.delete(:requests)
    missing_record_field = record(1) |> Map.delete(:metadata)

    assert {:error, {:missing_field, :state, :requests}} =
             SnapshotValidator.validate_v4(missing_state_field)

    assert {:error, {:missing_field, :record, :metadata}} =
             SnapshotValidator.validate_v4(%{
               %State{revision: 1}
               | current: %{"key" => missing_record_field}
             })
  end

  test "rejects malformed leases and request-cache entries" do
    malformed_lease = %{id: 1, ttl: 10, expires_at: 20, keys: []}

    assert {:error, {:missing_field, :lease, :granted_at}} =
             SnapshotValidator.validate_v4(%{
               %State{revision: 1, next_lease_id: 2}
               | leases: %{1 => malformed_lease}
             })

    malformed_request = %{
      request_hash: <<0::256>>,
      revision: 0,
      result: %Result{succeeded: true, revision: 0, responses: :not_a_list},
      cached_at: 0
    }

    assert {:error, :invalid_transaction_result} =
             SnapshotValidator.validate_v4(%{
               %State{}
               | requests: %{"request" => malformed_request}
             })
  end

  test "rejects an index-entry bucket whose value does not map to a list" do
    state = %State{
      indexes: %{"x" => {:identity}},
      index_entries: %{"x" => %{value: :not_a_list}}
    }

    assert {:error, {:invalid_index_keys, "x", :value}} =
             SnapshotValidator.validate_v4(state)
  end

  test "rejects contradictory current/store, lease, index, and revision relations" do
    record = record(1)

    assert {:error, {:store_current_mismatch, "key"}} =
             SnapshotValidator.validate_v4(%State{
               revision: 1,
               store: %{"key" => %{value: "store", expires_at: nil}},
               current: %{"key" => %{record | value: "current"}}
             })

    assert {:error, {:lease_membership_mismatch, "key"}} =
             SnapshotValidator.validate_v4(%State{
               revision: 1,
               next_lease_id: 2,
               store: %{"key" => %{value: "value", expires_at: nil}},
               current: %{"key" => record},
               leases: %{
                 1 => %{id: 1, ttl: 30, expires_at: 30, granted_at: 1, keys: ["key"]}
               }
             })

    assert {:error, :index_entries_mismatch} =
             SnapshotValidator.validate_v4(%State{
               store: %{"key" => "value"},
               current: %{"key" => record},
               revision: 1,
               indexes: %{"by-value" => {:identity}},
               index_entries: %{"by-value" => %{"wrong" => ["key"]}}
             })

    assert {:error, :revision_exceeds_state} =
             SnapshotValidator.validate_v4(%State{
               store: %{"key" => %{value: "value", expires_at: nil}},
               current: %{"key" => %{record | mod_revision: 2}},
               revision: 1
             })
  end

  test "is total over arbitrary terms" do
    arbitrary_terms = [nil, :state, 1, [], {}, fn -> :ok end, %{}, %{__struct__: State}]

    for term <- arbitrary_terms do
      assert {:error, _reason} = SnapshotValidator.validate_v4(term)
    end
  end

  defp record(revision) do
    %Record{
      value: "value",
      create_revision: 1,
      mod_revision: revision,
      version: 1,
      expires_at: nil,
      lease_id: nil,
      content_type: nil,
      metadata: %{}
    }
  end
end
