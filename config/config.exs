# config/config.exs
import Config

config :concord,
  cluster_name: :concord_cluster,
  data_dir: "./data",
  auth_enabled: false,
  max_batch_size: 500,
  # Default read consistency level: :eventual, :leader, or :strong
  default_read_consistency: :leader,
  ttl: [
    # 24 hours
    default_seconds: 86_400,
    # 5 minutes
    cleanup_interval_seconds: 300,
    enabled: true
  ],
  # Value compression configuration
  compression: [
    # Enable automatic compression
    enabled: true,
    # :zlib or :gzip
    algorithm: :zlib,
    # Compress values larger than 1KB
    threshold_bytes: 1024,
    # Compression level 0-9 (0=none, 9=max)
    level: 6
  ],
  # HTTP API configuration
  http: [
    # Enable HTTP/HTTPS API server (disabled by default)
    enabled: false,
    # API server port
    port: 4000,
    # API server IP (localhost by default)
    ip: {127, 0, 0, 1}
  ],
  # TLS/HTTPS configuration
  tls: [
    # Enable HTTPS instead of HTTP
    enabled: false,
    # Path to certificate file (PEM format)
    certfile: nil,
    # Path to private key file (PEM format)
    keyfile: nil,
    # Optional: Path to CA certificate file for client verification
    cacertfile: nil,
    # Cipher suite configuration (defaults to secure modern ciphers)
    ciphers: :default,
    # TLS versions to support (default: TLS 1.2 and 1.3)
    versions: [:"tlsv1.2", :"tlsv1.3"]
  ],
  # Prometheus metrics configuration (disabled by default)
  prometheus_enabled: false,
  prometheus_port: 9568,
  # OpenTelemetry distributed tracing configuration
  # Enable distributed tracing
  tracing_enabled: false,
  # :stdout, :otlp, or :none
  tracing_exporter: :stdout,
  # Audit logging configuration
  audit_log: [
    # Enable comprehensive audit logging
    enabled: false,
    # Directory for audit log files
    log_dir: "./audit_logs",
    # Rotate logs at 100MB
    rotation_size_mb: 100,
    # Keep logs for 90 days
    retention_days: 90,
    # Don't log read operations
    log_reads: false,
    # Don't log actual key values (only hashes)
    sensitive_keys: false
  ],
  # Event streaming configuration (Change Data Capture)
  event_stream: [
    # Enable real-time event streaming
    enabled: false,
    # Max events to buffer before back-pressure
    buffer_size: 10_000
  ]

# OpenTelemetry configuration
config :opentelemetry,
  # Span processor configuration
  span_processor: :batch,
  # Traces exporter - stdout for development, otlp for production
  traces_exporter: {:otel_exporter_stdout, []}

config :opentelemetry_exporter,
  # OTLP exporter configuration (when using :otlp)
  otlp_protocol: :grpc,
  otlp_endpoint: "http://localhost:4317",
  otlp_headers: []

config :libcluster,
  topologies: [
    concord: [
      strategy: Cluster.Strategy.Gossip
    ]
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :operation, :node]

import_config "#{config_env()}.exs"
