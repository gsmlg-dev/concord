defmodule Concord.TracingTest do
  use ExUnit.Case, async: false

  require Concord.Tracing

  describe "Concord.Tracing" do
    test "enabled?/0 returns configuration value" do
      # Tracing is disabled by default in test environment
      refute Concord.Tracing.enabled?()
    end

    test "with_span/2 executes block when tracing disabled" do
      result =
        Concord.Tracing.with_span "test_span" do
          :ok
        end

      assert result == :ok
    end

    test "set_attribute/2 handles disabled tracing gracefully" do
      assert Concord.Tracing.set_attribute(:test_key, "test_value") == nil
    end

    test "set_attributes/1 handles disabled tracing gracefully" do
      assert Concord.Tracing.set_attributes(%{key1: "value1", key2: "value2"}) == nil
    end

    test "add_event/2 handles disabled tracing gracefully" do
      assert Concord.Tracing.add_event("test_event", %{data: "test"}) == nil
    end

    test "current_trace_id/0 returns nil when tracing disabled" do
      assert Concord.Tracing.current_trace_id() == nil
    end

    test "current_span_id/0 returns nil when tracing disabled" do
      assert Concord.Tracing.current_span_id() == nil
    end

    test "start_span/2 and end_span/1 handle disabled tracing" do
      span = Concord.Tracing.start_span("test", %{key: "value"})
      assert span == nil

      assert Concord.Tracing.end_span(span) == nil
    end
  end
end
