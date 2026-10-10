defmodule Turso.NativeStackTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  @tag timeout: 120_000
  test "large balanced CHECK expressions survive native execute, query and reopen", %{
    tmp_dir: tmp_dir
  } do
    probe = Path.join(__DIR__, "support/native_stack_probe.exs")
    fixtures = Path.join(__DIR__, "fixtures/native_stack")
    code_paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    {output, exit_code} =
      System.cmd(
        System.find_executable("elixir"),
        code_paths ++ [probe, fixtures, Path.join(tmp_dir, "balanced_check.db")],
        stderr_to_stdout: true,
        env: [
          {"ERL_FLAGS", nil},
          {"ERL_AFLAGS", nil},
          {"ERL_ZFLAGS", nil},
          {"ELIXIR_ERL_OPTIONS", nil},
          {"ERL_CRASH_DUMP", Path.join(tmp_dir, "erl_crash.dump")}
        ]
      )

    assert exit_code == 0, "native subprocess exited with #{exit_code}:\n#{output}"
    assert output =~ "NATIVE STACK PROBE COMPLETE"
  end
end
