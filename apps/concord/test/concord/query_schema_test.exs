defmodule Concord.QuerySchemaTest do
  use ExUnit.Case, async: true

  alias Concord.Engine.VSR.StateMachine, as: VSRStateMachine
  alias Concord.QuerySchema
  alias Concord.StateMachine.Core
  alias ViewstampedReplication.ApplyMetadata

  @metadata %ApplyMetadata{
    group_id: :query_schema,
    view_number: 0,
    op_number: 7,
    client_id: :linearizable_read,
    request_number: 0
  }

  test "accepts every existing query shape with valid arguments" do
    queries = [
      {:get, "key"},
      {:get_with_ttl, "key"},
      :get_all,
      :get_all_with_ttl,
      {:ttl, "key"},
      {:get_many, ["a", "b"]},
      {:prefix_scan, ""},
      :stats,
      :backup_snapshot,
      {:index_lookup, "by-value", %{kind: :admin}},
      :list_indexes,
      {:get_index_extractor, "by-value"},
      {:get_record, "key"},
      {:get, "key", revision: 0},
      :get_revision,
      {:txn_result, "request-id"},
      {:history, "key", from_revision: 1, to_revision: 10, limit: 5},
      {:list, {:prefix, "key/"}, %{limit: 10, keys_only: true, revision: nil}},
      {:list, {:range, "a", "z"}, %{}},
      {:lease_info, 1},
      :list_leases
    ]

    assert Enum.all?(queries, &(QuerySchema.validate(&1) == :ok))
  end

  test "rejects partial Core query shapes before they can raise" do
    malformed_queries = [
      {:get, "key", revision: :latest},
      {:get_many, ["key", :not_a_key]},
      {:history, "key", %{}},
      {:history, "key", from_revision: 2, to_revision: 1},
      {:history, "key", limit: -1},
      {:list, {:prefix, :not_a_binary}, %{limit: 1}},
      {:list, {:range, "z", "a"}, %{limit: 1}},
      {:list, {:prefix, "key"}, %{limit: :all}},
      {:index_lookup, <<255>>, "value"},
      {:lease_info, 0},
      {:future_query, :payload}
    ]

    assert Enum.all?(malformed_queries, fn query ->
             QuerySchema.validate(query) == {:error, :unsupported_query}
           end)
  end

  test "the VSR state-machine read boundary rejects malformed envelopes and queries" do
    state = Core.init()

    assert {:error, :invalid_query_envelope} =
             VSRStateMachine.read(@metadata, {:concord_query, -1, :stats}, state)

    assert {:error, :invalid_query_envelope} =
             VSRStateMachine.read(@metadata, {:other_application, :query}, state)

    assert {:error, :unsupported_query} =
             VSRStateMachine.read(
               @metadata,
               {:concord_query, 1_000, {:history, "key", %{}}},
               state
             )

    assert {:error, {:invalid_query, :function_in_spec}} =
             VSRStateMachine.read(
               @metadata,
               {:concord_query, 1_000, {:index_lookup, "index", fn -> :unsafe end}},
               state
             )
  end

  test "logged compatibility queries reject malformed input without changing state" do
    state = Core.init()

    assert {{:error, :invalid_query_envelope}, ^state} =
             VSRStateMachine.apply(
               @metadata,
               {:concord_query, -1, :stats},
               state
             )

    assert {{:error, :invalid_query_envelope}, ^state} =
             VSRStateMachine.apply(
               @metadata,
               {:concord_query, 1_000, :stats, :unexpected_field},
               state
             )

    assert {{:error, :unsupported_query}, ^state} =
             VSRStateMachine.apply(
               @metadata,
               {:concord_query, 1_000, {:list, {:prefix, :bad}, %{limit: 1}}},
               state
             )
  end
end
