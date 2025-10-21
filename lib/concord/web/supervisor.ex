defmodule Concord.Web.Supervisor do
  @moduledoc """
  Supervisor for Concord HTTP API web server.

  Manages the Bandit web server and related web components.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    port = get_port()
    ip = get_ip()

    children = [
      {Bandit, scheme: :http, plug: Concord.Web.Router, ip: ip, port: port}
    ]

    # Make sure we have required plugs available
    :logger.info("Starting Concord HTTP API on #{format_ip(ip)}:#{port}")

    opts = [strategy: :one_for_one, name: Concord.Web.Supervisor]
    Supervisor.init(children, opts)
  end

  defp get_port do
    case System.get_env("CONCORD_API_PORT") do
      nil ->
        Application.get_env(:concord, :api_port, 4000)

      port_str ->
        case Integer.parse(port_str) do
          {port, ""} when port > 0 and port <= 65535 -> port
          _ -> raise "Invalid CONCORD_API_PORT: #{port_str}. Must be 1-65535."
        end
    end
  end

  defp get_ip do
    case System.get_env("CONCORD_API_IP") do
      nil ->
        case Application.get_env(:concord, :api_ip, {127, 0, 0, 1}) do
          {a, b, c, d} = ip when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 -> ip
          :loopback -> {127, 0, 0, 1}
          :any -> {0, 0, 0, 0}
          ip when is_tuple(ip) -> ip
          _ -> raise "Invalid API IP configuration"
        end

      ip_str ->
        case ip_str |> String.to_charlist() |> :inet.parse_address() do
          {:ok, ip} -> ip
          {:error, _} -> raise "Invalid CONCORD_API_IP: #{ip_str}"
        end
    end
  end

  defp format_ip({127, 0, 0, 1}), do: "localhost"
  defp format_ip({0, 0, 0, 0}), do: "0.0.0.0"
  defp format_ip(ip), do: :inet.ntoa(ip) |> to_string()
end