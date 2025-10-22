defmodule Concord.Prometheus do
  @moduledoc """
  Prometheus metrics exporter for Concord.

  Exposes comprehensive metrics about cluster health, operations, and storage
  in Prometheus format at the `/metrics` endpoint on port 9568 (configurable).

  ## Metrics Exposed

  ### API Operation Metrics
  - `concord_api_*_duration` - Latency summaries for all API operations
  - `concord_api_*_count` - Counters for operation throughput

  ### Raft Operation Metrics
  - `concord_operation_apply_duration` - State machine operation latency
  - `concord_operation_apply_count` - State machine operation count

  ### Cluster Health Metrics
  - `concord_cluster_size` - Number of entries in store
  - `concord_cluster_memory` - Memory usage in bytes
  - `concord_cluster_member_count` - Number of cluster members
  - `concord_cluster_commit_index` - Current Raft commit index
  - `concord_cluster_is_leader` - Leader status (1=leader, 0=follower)

  ### Snapshot Metrics
  - `concord_snapshot_created_size` - Last created snapshot size
  - `concord_snapshot_installed_size` - Last installed snapshot size
  """

  require Logger
  alias Telemetry.Metrics

  @doc """
  Returns metrics definitions for Prometheus export.
  """
  def metrics do
    [
      # API Operation Metrics - Track latency and throughput
      Metrics.summary("concord.api.put.duration",
        unit: {:native, :millisecond},
        description: "Duration of PUT operations",
        tags: [:result, :has_ttl]
      ),
      Metrics.summary("concord.api.get.duration",
        unit: {:native, :millisecond},
        description: "Duration of GET operations",
        tags: [:result, :consistency]
      ),
      Metrics.summary("concord.api.delete.duration",
        unit: {:native, :millisecond},
        description: "Duration of DELETE operations",
        tags: [:result]
      ),
      Metrics.summary("concord.api.get_many.duration",
        unit: {:native, :millisecond},
        description: "Duration of batch GET operations",
        tags: [:result, :consistency, :batch_size]
      ),
      Metrics.summary("concord.api.put_many.duration",
        unit: {:native, :millisecond},
        description: "Duration of batch PUT operations",
        tags: [:result, :batch_size]
      ),
      Metrics.summary("concord.api.delete_many.duration",
        unit: {:native, :millisecond},
        description: "Duration of batch DELETE operations",
        tags: [:result, :batch_size]
      ),
      Metrics.summary("concord.api.touch.duration",
        unit: {:native, :millisecond},
        description: "Duration of TTL extension operations",
        tags: [:result]
      ),
      Metrics.summary("concord.api.touch_many.duration",
        unit: {:native, :millisecond},
        description: "Duration of batch TTL extension operations",
        tags: [:result, :batch_size]
      ),
      Metrics.summary("concord.api.ttl.duration",
        unit: {:native, :millisecond},
        description: "Duration of TTL query operations",
        tags: [:result, :consistency]
      ),
      Metrics.summary("concord.api.get_with_ttl.duration",
        unit: {:native, :millisecond},
        description: "Duration of GET operations with TTL",
        tags: [:result, :consistency]
      ),

      # Operation counters
      Metrics.counter("concord.api.put.count",
        description: "Total number of PUT operations",
        tags: [:result, :has_ttl]
      ),
      Metrics.counter("concord.api.get.count",
        description: "Total number of GET operations",
        tags: [:result, :consistency]
      ),
      Metrics.counter("concord.api.delete.count",
        description: "Total number of DELETE operations",
        tags: [:result]
      ),

      # Raft state machine operation metrics
      Metrics.summary("concord.operation.apply.duration",
        unit: {:native, :millisecond},
        description: "Duration of Raft state machine operations",
        tags: [:operation]
      ),
      Metrics.counter("concord.operation.apply.count",
        description: "Total Raft state machine operations",
        tags: [:operation]
      ),

      # Snapshot metrics
      Metrics.last_value("concord.snapshot.created.size",
        description: "Size of last created snapshot",
        tags: [:node]
      ),
      Metrics.last_value("concord.snapshot.installed.size",
        description: "Size of last installed snapshot",
        tags: [:node]
      ),

      # Cluster health metrics (from poller)
      Metrics.last_value("concord.cluster.size",
        description: "Total number of entries in the store"
      ),
      Metrics.last_value("concord.cluster.memory",
        description: "Memory usage in bytes",
        unit: :byte
      ),
      Metrics.last_value("concord.cluster.member_count",
        description: "Number of cluster members"
      ),
      Metrics.last_value("concord.cluster.commit_index",
        description: "Current Raft commit index"
      ),
      Metrics.last_value("concord.cluster.is_leader",
        description: "Whether this node is the leader (1=yes, 0=no)"
      )
    ]
  end

  @doc """
  Child spec for starting the Prometheus exporter with built-in HTTP server.

  The Prometheus metrics endpoint will be available at:
  http://localhost:9568/metrics (or configured port)
  """
  def child_spec(_opts) do
    metrics_defs = metrics()
    port = Application.get_env(:concord, :prometheus_port, 9568)

    # Use the built-in HTTP server from TelemetryMetricsPrometheus
    {TelemetryMetricsPrometheus, [metrics: metrics_defs, port: port]}
  end
end
