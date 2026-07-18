defmodule ViewstampedReplication.DataStructuresTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{ApplyMetadata, LogEntry, Reply, Request}

  test "request and log entry metadata default to empty maps" do
    request = %Request{client_id: :client, request_number: 4, operation: {:put, :key, :value}}

    entry = %LogEntry{
      view_number: 2,
      op_number: 7,
      client_id: request.client_id,
      request_number: request.request_number,
      operation: request.operation
    }

    assert %Request{metadata: %{}} = request
    assert %LogEntry{metadata: %{}} = entry
  end

  test "reply identifies the view and client request" do
    assert %Reply{
             view_number: 2,
             client_id: :client,
             request_number: 4,
             result: :ok
           } = %Reply{view_number: 2, client_id: :client, request_number: 4, result: :ok}
  end

  test "apply metadata keeps entry metadata separate from protocol fields" do
    metadata = %ApplyMetadata{
      group_id: :group,
      view_number: 2,
      op_number: 7,
      client_id: :client,
      request_number: 4,
      entry_metadata: %{trace_id: "trace"}
    }

    assert %ApplyMetadata{group_id: :group, entry_metadata: %{trace_id: "trace"}} = metadata
  end
end
