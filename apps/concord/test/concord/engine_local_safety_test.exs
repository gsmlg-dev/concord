defmodule Concord.Engine.LocalSafetyTest do
  use ExUnit.Case, async: false

  alias Concord.CommandSchema
  alias Concord.Engine.Local

  setup do
    pid =
      case Process.whereis(Local) do
        nil -> start_supervised!({Local, []})
        pid -> pid
      end

    assert :ok = Local.reset()
    %{pid: pid}
  end

  test "public commands reject unsafe, oversized, and malformed input without applying it", %{
    pid: pid
  } do
    oversized_value = String.duplicate("x", CommandSchema.max_value_bytes() + 1)
    before = :sys.get_state(pid)

    invalid_commands = [
      {{:put, "unsafe", fn -> :unsafe end, %{}}, {:error, {:invalid_command, :function_in_spec}}},
      {{:put, "oversized", oversized_value, %{}}, {:error, {:invalid_command, :value_too_large}}},
      {{:put, "", "malformed", %{}}, {:error, :unsupported_command}}
    ]

    Enum.each(invalid_commands, fn {command, expected} ->
      assert Local.command(command) == expected
      assert_local_unchanged(pid, before)
    end)
  end

  test "direct command calls enforce the same boundary without killing the server", %{pid: pid} do
    oversized_value = String.duplicate("x", CommandSchema.max_value_bytes() + 1)
    before = :sys.get_state(pid)

    invalid_commands = [
      {{:put, "unsafe", self(), %{}}, {:error, {:invalid_command, :pid_in_spec}}},
      {{:put, "oversized", oversized_value, %{}}, {:error, {:invalid_command, :value_too_large}}},
      {{:unknown_command, :payload}, {:error, :unsupported_command}}
    ]

    Enum.each(invalid_commands, fn {command, expected} ->
      assert GenServer.call(pid, {:command, command}) == expected
      assert_local_unchanged(pid, before)
    end)
  end

  test "configured command limit rejects public and direct calls without applying them", %{
    pid: pid
  } do
    previous_limit = Application.fetch_env(:concord, :max_command_bytes)
    on_exit(fn -> restore_env(:max_command_bytes, previous_limit) end)
    Application.put_env(:concord, :max_command_bytes, 64)

    command = {:put, "configured-limit", String.duplicate("x", 128), %{}}
    assert :ok = CommandSchema.validate_emission(command)

    before = :sys.get_state(pid)
    expected = {:error, {:invalid_command, :command_too_large}}

    assert Local.command(command) == expected
    assert_local_unchanged(pid, before)

    assert GenServer.call(pid, {:command, command}) == expected
    assert_local_unchanged(pid, before)
  end

  test "public and direct queries reject unsafe or unsupported input without mutation", %{
    pid: pid
  } do
    assert {:ok, %{revision: 1}} = Local.command({:put, "kept", "value", %{}})
    before = :sys.get_state(pid)

    unsafe_query = {:index_lookup, "by-value", fn -> :unsafe end}
    malformed_query = {:get, ""}

    assert {:error, {:invalid_query, :function_in_spec}} = Local.query(unsafe_query)
    assert_local_unchanged(pid, before)

    assert {:error, :unsupported_query} = Local.query(malformed_query)
    assert_local_unchanged(pid, before)

    assert {:error, {:invalid_query, :function_in_spec}} =
             GenServer.call(pid, {:query, unsafe_query})

    assert_local_unchanged(pid, before)

    assert {:error, :unsupported_query} = GenServer.call(pid, {:query, malformed_query})
    assert_local_unchanged(pid, before)
    assert {:ok, {:ok, "value"}} = Local.query({:get, "kept"})
  end

  test "accepted commands retain Local result shapes and normalize writer-only TTL values", %{
    pid: pid
  } do
    assert {:ok, %{revision: 1}} =
             Local.command({:put, "permanent", "value", %{ttl: :infinity}})

    assert %{applied_index: 1, machine_state: machine_state} = :sys.get_state(pid)
    assert machine_state.current["permanent"].expires_at == nil
    assert {:ok, {:ok, "value"}} = Local.query({:get, "permanent"})
  end

  defp assert_local_unchanged(pid, before) do
    assert Process.alive?(pid)
    assert Process.whereis(Local) == pid
    assert :sys.get_state(pid) == before
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:concord, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:concord, key)
end
