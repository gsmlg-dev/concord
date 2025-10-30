defmodule Mix.Tasks.Concord.Gen.Cert do
  @moduledoc """
  Generates self-signed TLS certificates for development and testing.

  This task creates a self-signed certificate and private key suitable for
  local development. **Do NOT use these certificates in production!**

  ## Usage

      $ mix concord.gen.cert
      $ mix concord.gen.cert --out priv/cert

  ## Options

    * `--out` - Output directory for certificates (default: priv/cert)
    * `--host` - Hostname for the certificate (default: localhost)
    * `--days` - Certificate validity in days (default: 365)

  ## Files Generated

    * `selfsigned.pem` - Certificate file
    * `selfsigned_key.pem` - Private key file

  ## Configuration

  After generating certificates, configure Concord to use them:

      # config/dev.exs
      config :concord, :tls,
        enabled: true,
        certfile: "priv/cert/selfsigned.pem",
        keyfile: "priv/cert/selfsigned_key.pem"

  ## Production Certificates

  For production, use properly signed certificates from a Certificate Authority:

    * Let's Encrypt (free, automated)
    * Commercial CA (Digicert, GlobalSign, etc.)
    * Internal CA for private networks

  """
  use Mix.Task

  @shortdoc "Generates self-signed TLS certificates for development"

  @default_out_dir "priv/cert"
  @default_host "localhost"
  @default_days 365

  @impl Mix.Task
  def run(args) do
    {opts, _remaining, _invalid} =
      OptionParser.parse(args,
        strict: [out: :string, host: :string, days: :integer]
      )

    out_dir = Keyword.get(opts, :out, @default_out_dir)
    host = Keyword.get(opts, :host, @default_host)
    days = Keyword.get(opts, :days, @default_days)

    Mix.shell().info("Generating self-signed certificate...")
    Mix.shell().info("  Host: #{host}")
    Mix.shell().info("  Valid for: #{days} days")
    Mix.shell().info("  Output directory: #{out_dir}")
    Mix.shell().info("")

    # Create output directory
    File.mkdir_p!(out_dir)

    cert_file = Path.join(out_dir, "selfsigned.pem")
    key_file = Path.join(out_dir, "selfsigned_key.pem")

    # Check if files already exist
    if File.exists?(cert_file) or File.exists?(key_file) do
      unless Mix.shell().yes?("Certificates already exist. Overwrite?") do
        Mix.shell().info("Aborted.")
        System.halt(0)
      end
    end

    # Generate private key and certificate using openssl
    # We use openssl because it's widely available and well-tested
    generate_certificate(cert_file, key_file, host, days)

    Mix.shell().info("")
    Mix.shell().info("✓ Certificates generated successfully!")
    Mix.shell().info("")
    Mix.shell().info("Certificate: #{cert_file}")
    Mix.shell().info("Private key: #{key_file}")
    Mix.shell().info("")
    Mix.shell().info("To enable HTTPS, add to your config:")
    Mix.shell().info("")
    Mix.shell().info("  config :concord, :tls,")
    Mix.shell().info("    enabled: true,")
    Mix.shell().info("    certfile: \"#{cert_file}\",")
    Mix.shell().info("    keyfile: \"#{key_file}\"")
    Mix.shell().info("")
    Mix.shell().info("⚠️  WARNING: These are self-signed certificates for development only!")
    Mix.shell().info("   Do NOT use in production. Use proper CA-signed certificates.")
    Mix.shell().info("")
  end

  defp generate_certificate(cert_file, key_file, host, days) do
    # Generate private key (RSA 2048-bit)
    Mix.shell().info("Generating RSA private key...")

    {_, 0} =
      System.cmd("openssl", [
        "genrsa",
        "-out",
        key_file,
        "2048"
      ])

    # Generate self-signed certificate
    Mix.shell().info("Generating self-signed certificate...")

    {_, 0} =
      System.cmd("openssl", [
        "req",
        "-new",
        "-x509",
        "-key",
        key_file,
        "-out",
        cert_file,
        "-days",
        "#{days}",
        "-subj",
        "/CN=#{host}",
        "-addext",
        "subjectAltName=DNS:#{host},DNS:*.#{host},IP:127.0.0.1"
      ])

    # Set permissions (private key should be read-only by owner)
    File.chmod!(key_file, 0o600)
    File.chmod!(cert_file, 0o644)
  rescue
    e in ErlangError ->
      Mix.shell().error("")
      Mix.shell().error("Error generating certificates:")
      Mix.shell().error("#{inspect(e)}")
      Mix.shell().error("")
      Mix.shell().error("This task requires 'openssl' to be installed.")
      Mix.shell().error("")
      Mix.shell().error("Installation:")
      Mix.shell().error("  macOS:   brew install openssl")
      Mix.shell().error("  Ubuntu:  sudo apt-get install openssl")
      Mix.shell().error("  Windows: choco install openssl")
      Mix.shell().error("")
      System.halt(1)
  end
end
