defmodule Concord.AuditLog.TelemetryHandler do
  @moduledoc """
  Telemetry handler that automatically creates audit log entries from
  Concord operations.

  This module attaches to Concord's telemetry events and creates
  structured audit log entries for all data-modifying operations.

  ## Events Audited

  - `[:concord, :api, :put]` - Key creation/update operations
  - `[:concord, :api, :delete]` - Key deletion operations
  - `[:concord, :api, :put_many]` - Bulk insert operations
  - `[:concord, :api, :delete_many]` - Bulk delete operations
  - `[:concord, :api, :touch]` - TTL extension operations

  Read operations (get, get_many) are not audited by default unless
  `log_reads: true` is set in configuration.
  """

  require Logger

  alias Concord.AuditLog

  @audit_events [
    [:concord, :api, :put],
    [:concord, :api, :delete],
    [:concord, :api, :put_many],
    [:concord, :api, :delete_many],
    [:concord, :api, :touch],
    [:concord, :api, :touch_many]
  ]

  @read_events [
    [:concord, :api, :get],
    [:concord, :api, :get_many]
  ]

  @doc """
  Attaches telemetry handlers for audit logging.

  Called automatically during application startup when audit logging
  is enabled.
  """
  def attach do
    if enabled?() do
      # Attach write operation handlers
      :telemetry.attach_many(
        "concord-audit-log-handler",
        @audit_events,
        &handle_event/4,
        nil
      )

      # Attach read operation handlers if configured
      if log_reads?() do
        :telemetry.attach_many(
          "concord-audit-log-read-handler",
          @read_events,
          &handle_event/4,
          nil
        )
      end

      Logger.info("Concord audit logging telemetry handler attached")
    end

    :ok
  end

  @doc """
  Detaches telemetry handlers.
  """
  def detach do
    if enabled?() do
      :telemetry.detach("concord-audit-log-handler")

      if log_reads?() do
        :telemetry.detach("concord-audit-log-read-handler")
      end
    end

    :ok
  end

  ## Private Functions

  defp enabled? do
    config() |> Keyword.get(:enabled, false)
  end

  defp log_reads? do
    config() |> Keyword.get(:log_reads, false)
  end

  defp config do
    Application.get_env(:concord, :audit_log, [])
  end

  # Telemetry event handler
  defp handle_event(event_name, _measurements, metadata, _config) do
    operation = extract_operation(event_name)

    # Build audit event
    audit_event = %{
      operation: operation,
      key: extract_key(metadata),
      result: extract_result(metadata),
      user: extract_user(),
      metadata: extract_metadata(metadata)
    }

    # Log to audit log
    AuditLog.log(audit_event)
  end

  defp extract_operation([:concord, :api, operation | _rest]) do
    Atom.to_string(operation)
  end

  defp extract_key(metadata) do
    # For single operations, use the key
    # For batch operations, use a summary
    cond do
      Map.has_key?(metadata, :key) ->
        metadata.key

      Map.has_key?(metadata, :count) ->
        "batch_operation:#{metadata.count}_items"

      true ->
        nil
    end
  end

  defp extract_result(metadata) do
    Map.get(metadata, :result, :unknown)
  end

  defp extract_user do
    # Try to extract user/token from Process dictionary
    # This would be set by the Auth module during authentication
    case Process.get(:concord_auth_token) do
      nil -> nil
      token -> "token:#{String.slice(token, 0..15)}..."
    end
  end

  defp extract_metadata(metadata) do
    # Extract relevant metadata while excluding internal details
    metadata
    |> Map.take([:has_ttl, :ttl_seconds, :compressed, :consistency, :count])
    |> Enum.into(%{})
  end
end
