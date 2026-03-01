# Production Deployment

Guide for deploying Concord in production with Docker, Kubernetes, security hardening, and operational best practices.

## Production Checklist

- [ ] 2GB RAM minimum per node, 1-2 CPU cores
- [ ] Low-latency network between nodes (<10ms)
- [ ] Firewall rules configured, VPN for external access
- [ ] Telemetry collection and alerting set up
- [ ] Automated backup strategy in place
- [ ] Odd number of nodes (3 or 5) for HA
- [ ] Authentication enabled
- [ ] Persistent data directory configured

## Docker Deployment

### Dockerfile

```dockerfile
FROM elixir:1.15-alpine AS builder

WORKDIR /app
COPY mix.exs mix.lock ./
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only prod

COPY . .
RUN mix compile && mix release --overwrite

FROM alpine:3.18
RUN apk add --no-cache openssl ncurses-libs
WORKDIR /app

COPY --from=builder /app/_build/prod/rel/concord ./
RUN chown -R nobody:nobody /app
USER nobody

EXPOSE 4000 4369 9000-10000
CMD ["bin/concord", "start"]
```

### Docker Compose (3-Node Cluster)

```yaml
version: '3.8'

services:
  concord1:
    image: concord:latest
    hostname: concord1
    environment:
      - NODE_NAME=concord1@concord1
      - COOKIE=${CLUSTER_COOKIE}
      - CONCORD_DATA_DIR=/data
      - CONCORD_AUTH_ENABLED=true
      - RELEASE_DISTRIBUTION=name
      - RELEASE_NODE=concord1@concord1
    volumes:
      - concord1_data:/data
    networks:
      - concord-net
    deploy:
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 1G
    restart: unless-stopped

  concord2:
    image: concord:latest
    hostname: concord2
    environment:
      - NODE_NAME=concord2@concord2
      - COOKIE=${CLUSTER_COOKIE}
      - CONCORD_DATA_DIR=/data
      - CONCORD_AUTH_ENABLED=true
      - RELEASE_DISTRIBUTION=name
      - RELEASE_NODE=concord2@concord2
    volumes:
      - concord2_data:/data
    networks:
      - concord-net
    deploy:
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 1G
    restart: unless-stopped

  concord3:
    image: concord:latest
    hostname: concord3
    environment:
      - NODE_NAME=concord3@concord3
      - COOKIE=${CLUSTER_COOKIE}
      - CONCORD_DATA_DIR=/data
      - CONCORD_AUTH_ENABLED=true
      - RELEASE_DISTRIBUTION=name
      - RELEASE_NODE=concord3@concord3
    volumes:
      - concord3_data:/data
    networks:
      - concord-net
    deploy:
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 1G
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:latest
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    networks:
      - concord-net

volumes:
  concord1_data:
  concord2_data:
  concord3_data:
  prometheus_data:

networks:
  concord-net:
    driver: bridge
```

**Environment file (.env):**
```bash
CLUSTER_COOKIE=your-super-secret-cluster-cookie-here
CONCORD_AUTH_TOKEN=sk_concord_production_token_here
```

## Kubernetes Deployment

### Secrets and Config

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: concord-secrets
type: Opaque
stringData:
  cookie: "your-cluster-cookie"
  authToken: "sk_concord_production_token"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: concord-config
data:
  CONCORD_AUTH_ENABLED: "true"
  CONCORD_TELEMETRY_ENABLED: "true"
  CONCORD_DATA_DIR: "/data"
```

### StatefulSet

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: concord
spec:
  serviceName: concord-headless
  replicas: 3
  selector:
    matchLabels:
      app: concord
  template:
    metadata:
      labels:
        app: concord
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "4000"
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: concord
        image: concord:latest
        ports:
        - name: http
          containerPort: 4000
        - name: epmd
          containerPort: 4369
        - name: dist
          containerPort: 9100
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: NODE_NAME
          value: "concord-$(POD_NAME).concord-headless.default.svc.cluster.local"
        - name: COOKIE
          valueFrom:
            secretKeyRef:
              name: concord-secrets
              key: cookie
        - name: RELEASE_DISTRIBUTION
          value: "name"
        - name: RELEASE_NODE
          value: "$(NODE_NAME)"
        envFrom:
        - configMapRef:
            name: concord-config
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        volumeMounts:
        - name: data
          mountPath: /data
        livenessProbe:
          httpGet:
            path: /health
            port: 4000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 4000
          initialDelaySeconds: 5
          periodSeconds: 5
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: "fast-ssd"
      resources:
        requests:
          storage: "20Gi"
```

### Services

```yaml
apiVersion: v1
kind: Service
metadata:
  name: concord-headless
spec:
  ports:
  - port: 4000
    name: http
  - port: 4369
    name: epmd
  - port: 9100
    name: dist
  clusterIP: None
  selector:
    app: concord
---
apiVersion: v1
kind: Service
metadata:
  name: concord-client
spec:
  ports:
  - port: 4000
    name: http
  selector:
    app: concord
  type: LoadBalancer
```

### Network Policy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: concord-netpol
spec:
  podSelector:
    matchLabels:
      app: concord
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: concord
    ports:
    - protocol: TCP
      port: 4000
    - protocol: TCP
      port: 4369
    - protocol: TCP
      port: 9100
```

## Backup Scripts

### Automated Backup

```bash
#!/bin/bash
set -euo pipefail

BACKUP_DIR="/backup/concord"
DATA_DIR="/var/lib/concord"
DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="concord-backup-${DATE}"

mkdir -p "${BACKUP_DIR}"
tar -czf "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" -C "${DATA_DIR}" .

# Upload to S3 (optional)
if command -v aws &> /dev/null; then
    aws s3 cp "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" \
      "s3://your-backup-bucket/concord/${BACKUP_NAME}.tar.gz"
fi

# Keep 7 days of backups
find "${BACKUP_DIR}" -name "concord-backup-*.tar.gz" -mtime +7 -delete
```

### Recovery

```bash
#!/bin/bash
set -euo pipefail

BACKUP_FILE=$1
DATA_DIR="/var/lib/concord"

# Stop service
systemctl stop concord || docker-compose down

# Restore data
rm -rf "${DATA_DIR}"/*
tar -xzf "$BACKUP_FILE" -C "${DATA_DIR}"

# Fix permissions
chown -R concord:concord "${DATA_DIR}"

# Start service
systemctl start concord || docker-compose up -d
```

## Operational Best Practices

### Monitoring

1. **Watch for leader changes** — Frequent elections indicate instability
2. **Track commit latency** — High latency suggests network issues
3. **Monitor storage size** — Plan for snapshots and cleanup
4. **Alert on quorum loss** — Cluster becomes read-only

### Adding Nodes

```elixir
# 1. Start new node with same cluster_name and cookie
# 2. libcluster discovers it automatically
# 3. Add to Raft cluster:
:ra.add_member({:concord_cluster, :existing@host}, {:concord_cluster, :new@host})
```

### Removing Nodes

```elixir
:ra.remove_member({:concord_cluster, :leader@host}, {:concord_cluster, :old@host})
# Then stop the node
```

## FAQ

### General

**How is Concord different from Redis?**
Concord provides strong consistency through Raft consensus. Redis is eventually consistent. Concord is for distributed coordination; Redis excels at caching.

**Can I use Concord as a primary database?**
No. Concord is in-memory without persistence guarantees. Use it for coordination, configuration, and temporary data.

**What happens when the leader fails?**
Remaining nodes elect a new leader in 1-5 seconds. During election, writes are unavailable but reads may work depending on consistency level.

### Operations

**How many nodes should I run?**
3 for development, 5 for production. Odd numbers prevent split-brain. More than 7 typically hurts performance.

**Why are my writes slow?**
Common causes: high network latency, large values (>1MB), leader under pressure, network partitions.

**How much memory do I need?**
Plan for 2-3x your data size (ETS overhead + snapshots). Monitor with `Concord.status()`.

### Security

**How secure are auth tokens?**
Cryptographically secure random numbers, stored in ETS. Treat like API keys — use HTTPS in production and rotate regularly.

**Can I run on the public internet?**
Not recommended. Use a VPN or place behind a firewall with authentication.

## Troubleshooting

### Cluster Won't Form

1. Check Erlang cookie is identical on all nodes
2. Verify network connectivity: `ping`, `telnet <host> 4369`
3. Use IP addresses if DNS fails: `iex --name n1@192.168.1.10 --cookie secret -S mix`

### Operations Timing Out

1. Increase timeout: `Concord.put("key", "val", timeout: 10_000)`
2. Check cluster health: `Concord.status()`
3. Monitor system resources: `top -p $(pgrep beam)`

### High Memory Usage

1. Check storage: `Concord.status()` → `storage.memory`
2. Clean up temporary data
3. Trigger snapshot: `:ra.trigger_snapshot({:concord_cluster, node()})`

### Authentication Failures

1. Verify config: `Application.get_env(:concord, :auth_enabled)`
2. Recreate token: `mix concord.cluster token create`
3. Ensure token is passed: `Concord.get("key", token: "your_token")`

### Getting Help

- **Logs:** `tail -f /var/log/concord/concord.log`
- **Cluster status:** `mix concord.cluster status`
- **Node connectivity:** `epmd -names`
- **Issues:** [GitHub Issues](https://github.com/gsmlg-dev/concord/issues)

## Use Case Guide

### Recommended Use Cases

| Use Case | Data Size | Update Frequency |
|----------|-----------|------------------|
| Feature Flags | < 1MB | Medium |
| Config Management | < 10MB | Low |
| Service Discovery | < 100MB | High |
| Distributed Locks | < 1MB | Very High |
| Session Storage | < 500MB | High |
| Rate Limiting | < 10MB | Very High |

### Avoid These

- Large blob storage (images, videos) — use S3/MinIO
- Primary database — use PostgreSQL/MongoDB
- Analytics data — use dedicated analytics DB
- Message queue — use RabbitMQ/Kafka
