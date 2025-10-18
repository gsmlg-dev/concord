defmodule Concord.TelemetryTest do
  use ExUnit.Case, async: false

  test "telemetry events are emitted for operations" do
    test_pid = self()

    :telemetry.attach(
      "test-handler",
      [:concord, :api, :put],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    Concord.put("telemetry_test", "value")

    assert_receive {:telemetry, [:concord, :api, :put], measurements, metadata}, 1000
    assert is_integer(measurements.duration)
    assert metadata.result in [:ok, :error]

    :telemetry.detach("test-handler")
  end
end
