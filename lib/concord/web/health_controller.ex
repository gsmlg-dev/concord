defmodule Concord.Web.HealthController do
  @moduledoc """
  Health check controller for Concord HTTP API.

  Provides public health endpoints that don't require authentication
  for monitoring and load balancer health checks.
  """

  use Plug.Router
  require Logger

  plug(:match)
  plug(:dispatch)

  get "/health" do
    case check_cluster_health() do
      {:ok, health_data} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "status" => "healthy",
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "cluster" => health_data
          })
        )

      {:error, reason} ->
        Logger.warning("Health check failed: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          503,
          Jason.encode!(%{
            "status" => "unhealthy",
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "error" => %{
              "code" => "CLUSTER_UNAVAILABLE",
              "message" => "Cluster not available"
            }
          })
        )
    end
  end

  defp check_cluster_health() do
    try do
      case Concord.status() do
        {:ok, status} ->
          # Check if cluster has a leader
          cluster_info = get_in(status, [:cluster])
          has_leader = cluster_info && get_in(cluster_info, [:leader]) != nil

          if has_leader do
            {:ok,
             %{
               "status" => get_in(cluster_info, [:status]) || "unknown",
               "nodes" => length(get_in(cluster_info, [:members]) || []),
               "storage" => get_in(status, [:storage]) || %{},
               "leader" => inspect(get_in(cluster_info, [:leader]))
             }}
          else
            {:error, :no_leader}
          end

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error ->
        {:error, error}
    end
  end

  # Fallback for other paths
  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      404,
      Jason.encode!(%{
        "status" => "error",
        "error" => %{
          "code" => "NOT_FOUND",
          "message" => "Health endpoint not found"
        }
      })
    )
  end
end
