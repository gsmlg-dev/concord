defmodule Concord.Web.Router do
  @moduledoc """
  Main router for Concord HTTP API.

  Provides RESTful endpoints for key-value operations,
  bulk operations, TTL management, and cluster monitoring.
  """

  use Plug.Router
  require Logger

  # OpenTelemetry trace context propagation
  plug(Concord.Web.TracingPlug)

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["application/json"]
  )

  plug(:match)
  plug(:dispatch)

  # Public endpoints (no auth required for health checks)
  get "/api/v1/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "status" => "healthy",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "service" => "concord-api"
      })
    )
  end

  # OpenAPI specification endpoint
  get "/api/v1/openapi.json" do
    serve_openapi_spec(conn)
  end

  # Simple Swagger UI endpoint
  get "/api/docs" do
    serve_swagger_ui(conn)
  end

  # Authenticated API endpoints
  forward("/api/v1", to: Concord.Web.AuthenticatedRouter)

  # Private helper functions

  defp serve_openapi_spec(conn) do
    spec_path = Path.join(:code.priv_dir(:concord), "openapi.json")

    case File.read(spec_path) do
      {:ok, spec} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, spec)

      {:error, _} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          500,
          Jason.encode!(%{
            "status" => "error",
            "error" => %{
              "code" => "SPEC_NOT_FOUND",
              "message" => "OpenAPI specification not found"
            }
          })
        )
    end
  end

  defp serve_swagger_ui(conn) do
    html = """
    <!DOCTYPE html>
    <html>
    <head>
      <title>Concord API Documentation</title>
      <link rel="stylesheet" type="text/css" href="https://unpkg.com/swagger-ui-dist@5.10.5/swagger-ui.css" />
      <style>
        html { box-sizing: border-box; overflow: -moz-scrollbars-vertical; overflow-y: scroll; }
        *, *:before, *:after { box-sizing: inherit; }
        body { margin:0; background: #fafafa; }
      </style>
    </head>
    <body>
      <div id="swagger-ui"></div>
      <script src="https://unpkg.com/swagger-ui-dist@5.10.5/swagger-ui-bundle.js"></script>
      <script src="https://unpkg.com/swagger-ui-dist@5.10.5/swagger-ui-standalone-preset.js"></script>
      <script>
        window.onload = function() {
          const ui = SwaggerUIBundle({
            url: '/api/v1/openapi.json',
            dom_id: '#swagger-ui',
            deepLinking: true,
            presets: [
              SwaggerUIBundle.presets.apis,
              SwaggerUIStandalonePreset
            ],
            plugins: [
              SwaggerUIBundle.plugins.DownloadUrl
            ],
            layout: "StandaloneLayout",
            tryItOutEnabled: true
          });
        };
      </script>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  # Catch-all for unknown routes
  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      404,
      Jason.encode!(%{
        "status" => "error",
        "error" => %{
          "code" => "NOT_FOUND",
          "message" => "API endpoint not found"
        }
      })
    )
  end
end
