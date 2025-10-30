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
    tls_config = Application.get_env(:concord, :tls, [])
    tls_enabled = Keyword.get(tls_config, :enabled, false)

    bandit_opts =
      if tls_enabled do
        build_https_config(ip, port, tls_config)
      else
        [scheme: :http, plug: Concord.Web.Router, ip: ip, port: port]
      end

    children = [
      {Bandit, bandit_opts}
    ]

    # Make sure we have required plugs available
    protocol = if tls_enabled, do: "HTTPS", else: "HTTP"
    :logger.info("Starting Concord #{protocol} API on #{format_ip(ip)}:#{port}")

    opts = [strategy: :one_for_one, name: Concord.Web.Supervisor]
    Supervisor.init(children, opts)
  end

  defp get_port do
    case System.get_env("CONCORD_API_PORT") do
      nil ->
        Application.get_env(:concord, :api_port, 4000)

      port_str ->
        case Integer.parse(port_str) do
          {port, ""} when port > 0 and port <= 65_535 -> port
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

  defp build_https_config(ip, port, tls_config) do
    certfile = Keyword.get(tls_config, :certfile)
    keyfile = Keyword.get(tls_config, :keyfile)

    unless certfile && keyfile do
      raise """
      TLS is enabled but certificate or key file is missing.
      Please configure :tls :certfile and :keyfile in your config.

      Example:
        config :concord, :tls,
          enabled: true,
          certfile: "priv/cert/selfsigned.pem",
          keyfile: "priv/cert/selfsigned_key.pem"

      To generate self-signed certificates for development:
        mix concord.gen.cert
      """
    end

    # Verify files exist
    unless File.exists?(certfile) do
      raise "TLS certificate file not found: #{certfile}"
    end

    unless File.exists?(keyfile) do
      raise "TLS key file not found: #{keyfile}"
    end

    # Build base HTTPS configuration
    https_opts = [
      scheme: :https,
      plug: Concord.Web.Router,
      ip: ip,
      port: port,
      certfile: certfile,
      keyfile: keyfile
    ]

    # Add optional CA certificate for client verification
    https_opts =
      case Keyword.get(tls_config, :cacertfile) do
        nil ->
          https_opts

        cacertfile when is_binary(cacertfile) ->
          if File.exists?(cacertfile) do
            https_opts ++ [cacertfile: cacertfile, verify: :verify_peer]
          else
            :logger.warning(
              "TLS CA certificate file not found: #{cacertfile}, skipping client verification"
            )

            https_opts
          end

        _ ->
          https_opts
      end

    # Add cipher configuration
    https_opts =
      case Keyword.get(tls_config, :ciphers, :default) do
        :default ->
          # Use secure modern ciphers by default
          https_opts ++
            [
              ciphers: [
                # TLS 1.3 cipher suites (preferred)
                "TLS_AES_256_GCM_SHA384",
                "TLS_AES_128_GCM_SHA256",
                "TLS_CHACHA20_POLY1305_SHA256",
                # TLS 1.2 cipher suites (fallback)
                "ECDHE-RSA-AES256-GCM-SHA384",
                "ECDHE-RSA-AES128-GCM-SHA256"
              ]
            ]

        ciphers when is_list(ciphers) ->
          https_opts ++ [ciphers: ciphers]

        _ ->
          https_opts
      end

    # Add TLS versions
    case Keyword.get(tls_config, :versions, [:"tlsv1.2", :"tlsv1.3"]) do
      versions when is_list(versions) ->
        https_opts ++ [versions: versions]

      _ ->
        https_opts
    end
  end
end
