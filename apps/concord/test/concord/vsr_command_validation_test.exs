defmodule Concord.VSRCommandValidationTest do
  use ExUnit.Case, async: true

  alias Concord.Engine.VSR

  test "rejects nested functions before contacting the VSR runtime" do
    assert Process.whereis(VSR) == nil

    command = {:put, "key", %{callback: fn -> :unsafe end}, %{}}

    assert {:error, {:invalid_command, :function_in_spec}} = VSR.command(command)
  end

  test "rejects PIDs, references, and unsafe improper-list tails" do
    assert Process.whereis(VSR) == nil

    assert {:error, {:invalid_command, :pid_in_spec}} =
             VSR.command({:put, "pid", self(), %{}})

    assert {:error, {:invalid_command, :ref_in_spec}} =
             VSR.command({:put, "reference", make_ref(), %{}})

    assert {:error, {:invalid_command, :pid_in_spec}} =
             VSR.command({:put, "improper", [:safe | self()], %{}})
  end

  test "rejects ports with a precise reason" do
    assert Process.whereis(VSR) == nil
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary])

    try do
      assert {:error, {:invalid_command, :port_in_spec}} =
               VSR.command({:put, "port", port, %{}})
    after
      Port.close(port)
    end
  end

  test "safe commands proceed to the VSR runtime unchanged" do
    assert Process.whereis(VSR) == nil

    command = {:put, "key", %{uri: URI.parse("https://example.test"), bits: <<1::size(1)>>}, %{}}

    assert {:error, :cluster_not_ready} = VSR.command(command, timeout: 0)
  end

  test "rejects invalid UTF-8 and oversized index names before replication" do
    assert Process.whereis(VSR) == nil

    assert {:error, :unsupported_command} =
             VSR.command({:create_index, <<255>>, {:identity}})

    assert {:error, :unsupported_command} =
             VSR.command({:create_index, String.duplicate("x", 256), {:identity}})
  end

  test "rejects malformed and unsafe queries before contacting the VSR runtime" do
    assert Process.whereis(VSR) == nil

    assert {:error, :unsupported_query} =
             VSR.query({:history, "key", %{}})

    assert {:error, :unsupported_query} =
             VSR.query({:list, {:prefix, :not_a_binary}, %{limit: 10}})

    assert {:error, :unsupported_query} =
             VSR.query({:get, "key", revision: :latest})

    assert {:error, {:invalid_query, :function_in_spec}} =
             VSR.query({:index_lookup, "index", fn -> :unsafe end})
  end
end
