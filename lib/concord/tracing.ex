defmodule Concord.Tracing do
  @moduledoc """
  OpenTelemetry distributed tracing for Concord operations.

  This module provides distributed tracing support using OpenTelemetry,
  allowing you to track requests across the cluster, identify performance
  bottlenecks, and understand service dependencies.

  ## Configuration

      config :concord,
        tracing_enabled: true,
        tracing_exporter: :stdout  # :stdout, :otlp, or :none

  ## Usage

  Tracing is automatically enabled for all Concord API operations when
  `tracing_enabled: true` is set in configuration. You can also manually
  create spans:

      require Concord.Tracing
      Concord.Tracing.with_span "my_operation", %{key: "value"} do
        # Your code here
      end

  ## Trace Propagation

  For HTTP API requests, trace context is automatically extracted from
  standard HTTP headers (traceparent, tracestate) and propagated through
  the cluster.

  ## Integration with Telemetry

  Concord's existing telemetry events are automatically bridged to
  OpenTelemetry spans, providing unified observability across metrics
  and traces.
  """

  require OpenTelemetry.Tracer, as: Tracer
  alias OpenTelemetry.Span

  @doc """
  Executes a function within a new span with the given name and attributes.

  ## Examples

      require Concord.Tracing
      Concord.Tracing.with_span "database_query", %{table: "users"} do
        # Query logic
        {:ok, result}
      end
  """
  defmacro with_span(span_name, attributes \\ quote(do: %{}), do: block) do
    quote do
      if unquote(__MODULE__).enabled?() do
        Tracer.with_span unquote(span_name), %{attributes: unquote(attributes)} do
          unquote(block)
        end
      else
        unquote(block)
      end
    end
  end

  @doc """
  Starts a new span with the given name and attributes.

  Returns the span context. You must call `end_span/1` when done.

  ## Examples

      span_ctx = Concord.Tracing.start_span("operation", %{key: "value"})
      # Do work
      Concord.Tracing.end_span(span_ctx)
  """
  def start_span(span_name, attributes \\ %{}) do
    if enabled?() do
      Tracer.start_span(span_name, %{attributes: attributes})
    else
      nil
    end
  end

  @doc """
  Ends the current span.
  """
  def end_span(span_ctx) do
    if enabled?() and span_ctx do
      Tracer.end_span(span_ctx)
    end
  end

  @doc """
  Sets an attribute on the current span.

  ## Examples

      Concord.Tracing.set_attribute(:user_id, "12345")
      Concord.Tracing.set_attribute("cache.hit", true)
  """
  def set_attribute(key, value) do
    if enabled?() do
      Tracer.set_attribute(key, value)
    end
  end

  @doc """
  Sets multiple attributes on the current span.

  ## Examples

      Concord.Tracing.set_attributes(%{
        user_id: "12345",
        request_size: 1024,
        cache_hit: true
      })
  """
  def set_attributes(attributes) when is_map(attributes) do
    if enabled?() do
      Tracer.set_attributes(Map.to_list(attributes))
    end
  end

  @doc """
  Adds an event to the current span.

  ## Examples

      Concord.Tracing.add_event("cache_miss", %{key: "user:123"})
  """
  def add_event(event_name, attributes \\ %{}) do
    if enabled?() do
      Tracer.add_event(event_name, attributes: Map.to_list(attributes))
    end
  end

  @doc """
  Records an exception on the current span.

  ## Examples

      try do
        risky_operation()
      rescue
        e ->
          Concord.Tracing.record_exception(e, __STACKTRACE__)
          reraise e, __STACKTRACE__
      end
  """
  def record_exception(exception, stacktrace) do
    if enabled?() do
      Tracer.record_exception(exception, stacktrace, [])
      Tracer.set_status(:error, Exception.message(exception))
    end
  end

  @doc """
  Sets the status of the current span.

  Status can be :ok, :error, or :unset.

  ## Examples

      Concord.Tracing.set_status(:ok)
      Concord.Tracing.set_status(:error, "Operation failed")
  """
  def set_status(status, description \\ "") do
    if enabled?() do
      Tracer.set_status(status, description)
    end
  end

  @doc """
  Returns true if OpenTelemetry tracing is enabled.
  """
  def enabled? do
    Application.get_env(:concord, :tracing_enabled, false)
  end

  @doc """
  Gets the current trace ID as a string.

  Returns nil if no active span or tracing is disabled.

  ## Examples

      trace_id = Concord.Tracing.current_trace_id()
      # "a1b2c3d4e5f6789012345678901234ab"
  """
  def current_trace_id do
    if enabled?() do
      case Tracer.current_span_ctx() do
        :undefined -> nil
        span_ctx -> Span.trace_id(span_ctx) |> format_trace_id()
      end
    end
  end

  @doc """
  Gets the current span ID as a string.

  Returns nil if no active span or tracing is disabled.
  """
  def current_span_id do
    if enabled?() do
      case Tracer.current_span_ctx() do
        :undefined -> nil
        span_ctx -> Span.span_id(span_ctx) |> format_span_id()
      end
    end
  end

  # Private helpers

  defp format_trace_id(trace_id) when is_integer(trace_id) do
    trace_id
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(32, "0")
  end

  defp format_span_id(span_id) when is_integer(span_id) do
    span_id
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(16, "0")
  end
end
