defmodule Concord.Web.TracingPlug do
  @moduledoc """
  Plug for extracting and propagating OpenTelemetry trace context in HTTP requests.

  This plug extracts trace context from incoming HTTP headers (traceparent, tracestate)
  and creates a root span for the HTTP request. It also injects trace context into
  outgoing responses.

  ## Configuration

  Automatically enabled when `tracing_enabled: true` is set in application config.

  ## Supported Headers

  - `traceparent` - W3C Trace Context traceparent header
  - `tracestate` - W3C Trace Context tracestate header
  - `x-b3-traceid` - Zipkin B3 trace ID (fallback)
  - `x-b3-spanid` - Zipkin B3 span ID (fallback)

  ## Usage

  Add to your router pipeline:

      pipeline :api do
        plug Concord.Web.TracingPlug
        plug :accepts, ["json"]
      end
  """

  import Plug.Conn
  require OpenTelemetry.Tracer, as: Tracer

  alias Concord.Tracing

  @behaviour Plug

  # Suppress Dialyzer warnings for functions used conditionally in tracing
  # and for OpenTelemetry opaque types
  @dialyzer {:nowarn_function,
             call: 2, execute_request: 1, set_span_status: 1, inject_trace_context: 1,
             get_header_value: 2, format_peer_ip: 1}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Tracing.enabled?() do
      # Extract trace context from headers
      ctx = :otel_propagator_text_map.extract(conn.req_headers)
      # Suppress opaque type warning - this is correct usage per OTel docs
      _ = :otel_ctx.attach(ctx)

      # Start root HTTP span
      Tracer.with_span "HTTP #{conn.method} #{conn.request_path}" do
        # Set HTTP-specific attributes
        Tracer.set_attributes([
          {"http.method", conn.method},
          {"http.target", conn.request_path},
          {"http.scheme", to_string(conn.scheme)},
          {"http.host", get_header_value(conn, "host")},
          {"http.user_agent", get_header_value(conn, "user-agent")},
          {"net.peer.ip", format_peer_ip(conn.remote_ip)},
          {"net.peer.port", conn.port}
        ])

        # Process request
        conn = execute_request(conn)

        # Set response attributes
        Tracer.set_attributes([
          {"http.status_code", conn.status || 0},
          {"http.response_content_length", get_header_value(conn, "content-length") || "0"}
        ])

        # Set span status based on HTTP status code
        set_span_status(conn.status)

        # Inject trace context into response headers
        inject_trace_context(conn)
      end
    else
      conn
    end
  end

  defp execute_request(conn) do
    # Let the request continue through the pipeline
    conn
  rescue
    e ->
      # Record exception in span
      Tracing.record_exception(e, __STACKTRACE__)
      reraise e, __STACKTRACE__
  end

  defp set_span_status(status) when status >= 500 do
    Tracer.set_status(:error, "HTTP #{status}")
  end

  defp set_span_status(status) when status >= 400 do
    Tracer.set_status(:error, "HTTP #{status}")
  end

  defp set_span_status(_), do: Tracer.set_status(:ok, "")

  defp inject_trace_context(conn) do
    # Get current span context
    span_ctx = Tracer.current_span_ctx()

    if span_ctx != :undefined do
      # Create a carrier map
      carrier = %{}

      # Inject trace context into carrier
      injected = :otel_propagator_text_map.inject(carrier)

      # Add trace headers to response
      Enum.reduce(injected, conn, fn {key, value}, acc ->
        put_resp_header(acc, to_string(key), to_string(value))
      end)
    else
      conn
    end
  end

  defp get_header_value(conn, header_name) do
    case get_req_header(conn, header_name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp format_peer_ip(ip) when is_tuple(ip) do
    ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end

  defp format_peer_ip(ip), do: to_string(ip)
end
