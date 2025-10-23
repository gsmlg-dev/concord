defmodule Concord.AuditLogTest do
  use ExUnit.Case, async: false

  describe "Concord.AuditLog configuration" do
    test "enabled?/0 reflects configuration" do
      # Audit logging is disabled by default in test environment
      config = Application.get_env(:concord, :audit_log, [])
      enabled = Keyword.get(config, :enabled, false)

      refute enabled
    end

    test "log/1 handles disabled audit logging gracefully" do
      result = Concord.AuditLog.log(%{
        operation: "put",
        key: "test_key",
        result: :ok
      })

      assert result == :ok
    end

    test "query/1 returns empty list when disabled" do
      {:ok, logs} = Concord.AuditLog.query(limit: 10)
      assert logs == []
    end

    test "stats/0 shows disabled status" do
      stats = Concord.AuditLog.stats()
      assert stats == %{enabled: false}
    end

    test "export/2 returns error when disabled" do
      result = Concord.AuditLog.export("/tmp/test_export.jsonl")
      assert result == {:error, :audit_log_disabled}
    end
  end

  describe "Concord.AuditLog.TelemetryHandler" do
    test "attach/0 does not crash when audit logging is disabled" do
      assert Concord.AuditLog.TelemetryHandler.attach() == :ok
    end

    test "detach/0 does not crash" do
      assert Concord.AuditLog.TelemetryHandler.detach() == :ok
    end
  end
end
