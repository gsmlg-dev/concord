defmodule Concord.AuditLog do
  @moduledoc """
  Comprehensive audit logging for Concord operations.

  Provides an immutable audit trail of all data-modifying operations
  for compliance, security, and debugging purposes. Audit logs are
  append-only and stored in structured JSON format.

  ## Features

  - Immutable append-only log storage
  - Structured JSON format for easy parsing
  - Automatic log rotation and retention
  - Query and export API
  - Minimal performance impact (async writes)
  - Integration with authentication and telemetry

  ## Configuration

      config :concord,
        audit_log: [
          enabled: true,
          log_dir: "./audit_logs",
          rotation_size_mb: 100,      # Rotate at 100MB
          retention_days: 90,          # Keep logs for 90 days
          log_reads: false,            # Don't log read operations
          sensitive_keys: false        # Don't log actual key values
        ]

  ## Audit Log Format

  Each audit log entry is a JSON object with the following fields:

      {
        "timestamp": "2025-10-23T08:30:45.123456Z",
        "event_id": "550e8400-e29b-41d4-a716-446655440000",
        "operation": "put",
        "key": "user:123",  # Only if sensitive_keys: true
        "key_hash": "sha256:abc123...",  # Always present
        "result": "ok",
        "user": "token:sk_concord_...",  # If authenticated
        "node": "node1@127.0.0.1",
        "metadata": {
          "has_ttl": true,
          "ttl_seconds": 3600,
          "compressed": false
        },
        "trace_id": "a1b2c3d4...",  # If tracing enabled
        "span_id": "e5f6g7h8..."
      }

  ## Usage

  Audit logging is automatic for all operations when enabled.
  You can also manually log custom events:

      Concord.AuditLog.log(%{
        operation: "custom_action",
        key: "resource:id",
        result: :ok,
        metadata: %{action: "import", count: 100}
      })

  ## Querying Logs

      # Get recent audit logs
      {:ok, logs} = Concord.AuditLog.query(limit: 100)

      # Filter by operation
      {:ok, logs} = Concord.AuditLog.query(operation: "put", limit: 50)

      # Filter by time range
      {:ok, logs} = Concord.AuditLog.query(
        from: ~U[2025-10-23 00:00:00Z],
        to: ~U[2025-10-23 23:59:59Z]
      )

  ## Compliance

  Audit logs support compliance requirements including:
  - PCI-DSS: Tracking and monitoring all access to cardholder data
  - HIPAA: Audit controls for PHI access
  - GDPR: Data processing activity logs
  - SOC 2: Detailed audit trails for security events
  """

  use GenServer
  require Logger

  alias Concord.Tracing

  @type event :: %{
          timestamp: DateTime.t(),
          event_id: String.t(),
          operation: String.t(),
          key: String.t() | nil,
          key_hash: String.t(),
          result: atom() | String.t(),
          user: String.t() | nil,
          node: atom(),
          metadata: map(),
          trace_id: String.t() | nil,
          span_id: String.t() | nil
        }

  defstruct [:log_file, :log_dir, :current_size, :config]

  ## Public API

  @doc """
  Starts the audit log GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Logs an audit event.

  ## Examples

      Concord.AuditLog.log(%{
        operation: "put",
        key: "user:123",
        result: :ok
      })
  """
  def log(event) when is_map(event) do
    if enabled?() do
      GenServer.cast(__MODULE__, {:log, event})
    end

    :ok
  end

  @doc """
  Queries audit logs with optional filters.

  ## Options

  - `:limit` - Maximum number of entries to return (default: 100)
  - `:operation` - Filter by operation type
  - `:from` - Start datetime (DateTime struct)
  - `:to` - End datetime (DateTime struct)
  - `:user` - Filter by user/token
  - `:result` - Filter by result (`:ok`, `:error`)

  ## Examples

      {:ok, logs} = Concord.AuditLog.query(operation: "put", limit: 50)
  """
  def query(opts \\ []) do
    if enabled?() do
      GenServer.call(__MODULE__, {:query, opts}, 30_000)
    else
      {:ok, []}
    end
  end

  @doc """
  Exports audit logs to a file.

  ## Examples

      :ok = Concord.AuditLog.export("/tmp/audit_export.jsonl")
  """
  def export(path, opts \\ []) do
    if enabled?() do
      GenServer.call(__MODULE__, {:export, path, opts}, 60_000)
    else
      {:error, :audit_log_disabled}
    end
  end

  @doc """
  Manually triggers log rotation.
  """
  def rotate do
    if enabled?() do
      GenServer.call(__MODULE__, :rotate)
    end
  end

  @doc """
  Cleans up old audit logs based on retention policy.
  """
  def cleanup do
    if enabled?() do
      GenServer.call(__MODULE__, :cleanup)
    end
  end

  @doc """
  Returns current audit log statistics.

  ## Examples

      iex> Concord.AuditLog.stats()
      %{
        current_log_size: 45678912,
        total_files: 5,
        oldest_log: ~U[2025-07-23 00:00:00Z],
        entries_today: 1234
      }
  """
  def stats do
    if enabled?() do
      GenServer.call(__MODULE__, :stats)
    else
      %{enabled: false}
    end
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    if enabled?() do
      config = audit_config()
      log_dir = Keyword.get(config, :log_dir, "./audit_logs")

      # Ensure log directory exists
      File.mkdir_p!(log_dir)

      # Open current log file
      log_file = current_log_path(log_dir)
      file = File.open!(log_file, [:append, :utf8])

      # Get current file size
      current_size =
        case File.stat(log_file) do
          {:ok, %{size: size}} -> size
          _ -> 0
        end

      Logger.info("Concord audit logging started: #{log_file}")

      state = %__MODULE__{
        log_file: file,
        log_dir: log_dir,
        current_size: current_size,
        config: config
      }

      # Schedule periodic cleanup
      schedule_cleanup()

      {:ok, state}
    else
      :ignore
    end
  end

  @impl true
  def handle_cast({:log, event}, state) do
    # Build complete audit event
    audit_event = build_audit_event(event)

    # Serialize to JSON
    json_line = Jason.encode!(audit_event) <> "\n"
    json_size = byte_size(json_line)

    # Write to file
    IO.write(state.log_file, json_line)

    # Update size
    new_size = state.current_size + json_size

    # Check if rotation needed
    state =
      if should_rotate?(new_size, state.config) do
        rotate_log(state)
      else
        %{state | current_size: new_size}
      end

    {:noreply, state}
  end

  @impl true
  def handle_call({:query, opts}, _from, state) do
    result = query_logs(state.log_dir, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:export, path, opts}, _from, state) do
    result = export_logs(state.log_dir, path, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:rotate, _from, state) do
    new_state = rotate_log(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:cleanup, _from, state) do
    cleanup_old_logs(state.log_dir, state.config)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = calculate_stats(state)
    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_logs(state.log_dir, state.config)
    schedule_cleanup()
    {:noreply, state}
  end

  ## Private Functions

  defp enabled? do
    audit_config() |> Keyword.get(:enabled, false)
  end

  defp audit_config do
    Application.get_env(:concord, :audit_log, [])
  end

  defp build_audit_event(event) do
    config = audit_config()
    log_sensitive = Keyword.get(config, :sensitive_keys, false)

    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      event_id: generate_event_id(),
      operation: Map.get(event, :operation, "unknown"),
      key: if(log_sensitive, do: Map.get(event, :key), else: nil),
      key_hash: hash_key(Map.get(event, :key)),
      result: Map.get(event, :result, :unknown) |> to_string(),
      user: Map.get(event, :user),
      node: node() |> to_string(),
      metadata: Map.get(event, :metadata, %{}),
      trace_id: get_trace_id(),
      span_id: get_span_id()
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp generate_event_id do
    # Use UUID if available, otherwise fall back to crypto
    if Code.ensure_loaded?(UUID) do
      apply(UUID, :uuid4, [])
    else
      # Fallback if UUID library not available
      :crypto.strong_rand_bytes(16)
      |> Base.encode16(case: :lower)
    end
  end

  defp hash_key(nil), do: nil

  defp hash_key(key) when is_binary(key) do
    :crypto.hash(:sha256, key)
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  defp hash_key(key), do: hash_key(inspect(key))

  defp get_trace_id do
    if function_exported?(Concord.Tracing, :current_trace_id, 0) do
      Tracing.current_trace_id()
    end
  end

  defp get_span_id do
    if function_exported?(Concord.Tracing, :current_span_id, 0) do
      Tracing.current_span_id()
    end
  end

  defp current_log_path(log_dir) do
    date_str = Date.utc_today() |> Date.to_iso8601()
    Path.join(log_dir, "audit_#{date_str}.jsonl")
  end

  defp should_rotate?(size, config) do
    max_size = Keyword.get(config, :rotation_size_mb, 100) * 1_024 * 1_024
    size >= max_size
  end

  defp rotate_log(state) do
    # Close current file
    File.close(state.log_file)

    # Rename current file with timestamp
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    old_path = current_log_path(state.log_dir)
    new_path = String.replace(old_path, ".jsonl", "_#{timestamp}.jsonl")

    File.rename(old_path, new_path)

    # Open new file
    new_log_path = current_log_path(state.log_dir)
    new_file = File.open!(new_log_path, [:append, :utf8])

    Logger.info("Rotated audit log: #{new_path}")

    %{state | log_file: new_file, current_size: 0}
  end

  defp query_logs(log_dir, opts) do
    limit = Keyword.get(opts, :limit, 100)
    operation_filter = Keyword.get(opts, :operation)
    from_time = Keyword.get(opts, :from)
    to_time = Keyword.get(opts, :to)
    user_filter = Keyword.get(opts, :user)
    result_filter = Keyword.get(opts, :result)

    # Get all log files sorted by date
    log_files =
      File.ls!(log_dir)
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.sort(:desc)

    # Read and parse logs
    logs =
      log_files
      |> Enum.flat_map(fn file ->
        Path.join(log_dir, file)
        |> File.stream!()
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Stream.map(&Jason.decode!/1)
        |> Enum.to_list()
      end)
      |> Enum.filter(fn log ->
        matches_filters?(log, operation_filter, from_time, to_time, user_filter, result_filter)
      end)
      |> Enum.take(limit)

    {:ok, logs}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp matches_filters?(log, operation, from_time, to_time, user, result) do
    operation_match = is_nil(operation) or log["operation"] == operation
    user_match = is_nil(user) or log["user"] == user
    result_match = is_nil(result) or log["result"] == to_string(result)

    time_match =
      case {from_time, to_time} do
        {nil, nil} ->
          true

        {from, nil} ->
          log_time = parse_timestamp(log["timestamp"])
          DateTime.compare(log_time, from) in [:gt, :eq]

        {nil, to} ->
          log_time = parse_timestamp(log["timestamp"])
          DateTime.compare(log_time, to) in [:lt, :eq]

        {from, to} ->
          log_time = parse_timestamp(log["timestamp"])

          DateTime.compare(log_time, from) in [:gt, :eq] and
            DateTime.compare(log_time, to) in [:lt, :eq]
      end

    operation_match and user_match and result_match and time_match
  end

  defp parse_timestamp(iso8601_string) do
    case DateTime.from_iso8601(iso8601_string) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp export_logs(log_dir, export_path, opts) do
    {:ok, logs} = query_logs(log_dir, opts)

    # Write to export file
    File.write!(export_path, Enum.map(logs, &Jason.encode!/1) |> Enum.join("\n"))

    Logger.info("Exported #{length(logs)} audit log entries to #{export_path}")
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp cleanup_old_logs(log_dir, config) do
    retention_days = Keyword.get(config, :retention_days, 90)
    cutoff_date = Date.utc_today() |> Date.add(-retention_days)

    File.ls!(log_dir)
    |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
    |> Enum.each(fn file ->
      file_path = Path.join(log_dir, file)

      case File.stat(file_path) do
        {:ok, %{mtime: mtime}} ->
          file_date = mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_date()

          if Date.compare(file_date, cutoff_date) == :lt do
            File.rm(file_path)
            Logger.info("Deleted old audit log: #{file}")
          end

        _ ->
          :ok
      end
    end)
  rescue
    e -> Logger.error("Error cleaning up audit logs: #{Exception.message(e)}")
  end

  defp calculate_stats(state) do
    total_size =
      File.ls!(state.log_dir)
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.map(fn file ->
        case File.stat(Path.join(state.log_dir, file)) do
          {:ok, %{size: size}} -> size
          _ -> 0
        end
      end)
      |> Enum.sum()

    %{
      enabled: true,
      current_log_size: state.current_size,
      total_size: total_size,
      log_dir: state.log_dir
    }
  end

  defp schedule_cleanup do
    # Run cleanup every 24 hours
    Process.send_after(self(), :cleanup, :timer.hours(24))
  end
end
