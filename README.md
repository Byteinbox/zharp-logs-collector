# Zharp Collector

The **Zharp Collector** is an OpenTelemetry-based agent that ships logs, metrics, and traces from your servers and applications to the [Zharp](https://zharp.io) monitoring platform. It is a purpose-built distribution of the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/), pre-packaged with receivers for files, host metrics, Docker, Kubernetes, and databases (PostgreSQL, Redis, MongoDB, MySQL).

---

## What it collects

| Source | What it sends |
|---|---|
| Log files (nginx, app logs, etc.) | Tailed log lines, parsed level + timestamp |
| Host | CPU, memory, disk, network, load |
| Docker | Container CPU, memory, network per container |
| PostgreSQL | Connections, commits, rollbacks, query latency, table stats |
| Redis | Memory, connected clients, keyspace hits/misses, command stats |
| MongoDB | Connections, operations, document counts, replication lag |
| MySQL | Connections, queries, InnoDB buffer pool, table I/O |
| Any OTLP app | Traces, metrics, logs via gRPC (4317) or HTTP (4318) |

---

## Quick install (Linux / macOS)

```bash
curl -sSL https://raw.githubusercontent.com/Byteinbox/zharp-logs-collector/main/install.sh | sudo bash
```

Then edit `/etc/zharp-collector/config.yaml` with your API key and start:

```bash
sudo systemctl start zharp-collector
sudo journalctl -fu zharp-collector
```

---

## Installation guides

### Linux (Ubuntu / Debian / RHEL / Amazon Linux)

**One-liner**

```bash
curl -sSL https://raw.githubusercontent.com/Byteinbox/zharp-logs-collector/main/install.sh | sudo bash
```

The script:
1. Detects your CPU architecture (x86_64 or ARM64)
2. Downloads the correct binary from the latest GitHub Release
3. Installs it to `/usr/local/bin/zharp-collector`
4. Writes a default config to `/etc/zharp-collector/config.yaml`
5. Installs and enables a `systemd` service

**Manual install**

```bash
# x86_64
curl -Lo zharp-collector.tar.gz \
  https://github.com/Byteinbox/zharp-logs-collector/releases/latest/download/zharp-collector-latest-linux-amd64.tar.gz

# ARM64 (Graviton, Ampere, Raspberry Pi 4+)
curl -Lo zharp-collector.tar.gz \
  https://github.com/Byteinbox/zharp-logs-collector/releases/latest/download/zharp-collector-latest-linux-arm64.tar.gz

tar -xzf zharp-collector.tar.gz
sudo install -m 755 zharp-collector-linux-* /usr/local/bin/zharp-collector
sudo mkdir -p /etc/zharp-collector
sudo cp collector-config.yaml /etc/zharp-collector/config.yaml
```

**Edit config**

```bash
sudo nano /etc/zharp-collector/config.yaml
# Set: api_key and endpoint under the zharp: exporter
```

**Run as systemd service**

```bash
sudo tee /etc/systemd/system/zharp-collector.service > /dev/null <<'EOF'
[Unit]
Description=Zharp OpenTelemetry Collector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/zharp-collector --config /etc/zharp-collector/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now zharp-collector
sudo journalctl -fu zharp-collector
```

---

### macOS

**x86_64 (Intel)**

```bash
curl -Lo zharp-collector.tar.gz \
  https://github.com/Byteinbox/zharp-logs-collector/releases/latest/download/zharp-collector-latest-darwin-amd64.tar.gz
tar -xzf zharp-collector.tar.gz
sudo install -m 755 zharp-collector-darwin-amd64 /usr/local/bin/zharp-collector
```

**ARM64 (Apple Silicon — M1/M2/M3/M4)**

```bash
curl -Lo zharp-collector.tar.gz \
  https://github.com/Byteinbox/zharp-logs-collector/releases/latest/download/zharp-collector-latest-darwin-arm64.tar.gz
tar -xzf zharp-collector.tar.gz
sudo install -m 755 zharp-collector-darwin-arm64 /usr/local/bin/zharp-collector
```

**Configure and run**

```bash
mkdir -p ~/.config/zharp-collector
cp collector-config.yaml ~/.config/zharp-collector/config.yaml
# Edit config: set api_key and endpoint
nano ~/.config/zharp-collector/config.yaml

zharp-collector --config ~/.config/zharp-collector/config.yaml
```

**Run as a launchd service (auto-start on login)**

```bash
sudo tee /Library/LaunchDaemons/io.zharp.collector.plist > /dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>io.zharp.collector</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/zharp-collector</string>
    <string>--config</string>
    <string>/etc/zharp-collector/config.yaml</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
EOF

sudo launchctl load /Library/LaunchDaemons/io.zharp.collector.plist
```

---

### Windows

1. Download `zharp-collector-<version>-windows-amd64.zip` from the [releases page](https://github.com/Byteinbox/zharp-logs-collector/releases/latest).
2. Extract the zip.
3. Copy `zharp-collector.exe` to `C:\Program Files\zharp-collector\`
4. Copy `collector-config.yaml` to `C:\ProgramData\zharp-collector\config.yaml`
5. Edit the config with your API key.

**Install as a Windows Service (PowerShell, run as Administrator)**

```powershell
New-Service -Name "ZharpCollector" `
  -BinaryPathName '"C:\Program Files\zharp-collector\zharp-collector.exe" --config "C:\ProgramData\zharp-collector\config.yaml"' `
  -DisplayName "Zharp Collector" `
  -StartupType Automatic `
  -Description "Zharp OpenTelemetry Collector agent"

Start-Service ZharpCollector
Get-Service ZharpCollector
```

---

### Docker

**Run with Docker**

```bash
docker run -d \
  --name zharp-collector \
  --restart unless-stopped \
  -e ZHARP_ENDPOINT=https://api.zharp.io/api/v1 \
  -e ZHARP_API_KEY=your_api_key_here \
  -v /var/log:/var/log:ro \
  -v /proc:/hostfs/proc:ro \
  -v /sys:/hostfs/sys:ro \
  -v /:/hostfs:ro \
  -p 4317:4317 \
  -p 4318:4318 \
  ghcr.io/Byteinbox/zharp-logs-collector:latest
```

**Docker Compose sidecar**

Add the collector as a sidecar in your `docker-compose.yml`:

```yaml
services:
  # --- your application ---
  app:
    image: your-app:latest
    environment:
      OTEL_EXPORTER_OTLP_ENDPOINT: http://zharp-collector:4317
    depends_on:
      - zharp-collector

  # --- zharp collector sidecar ---
  zharp-collector:
    image: ghcr.io/Byteinbox/zharp-logs-collector:latest
    restart: unless-stopped
    environment:
      ZHARP_ENDPOINT: https://api.zharp.io/api/v1
      ZHARP_API_KEY: ${ZHARP_API_KEY}
    volumes:
      - ./zharp-collector.yaml:/etc/zharp-collector/config.yaml:ro
      - /var/log:/var/log:ro
      - /:/hostfs:ro
    ports:
      - "4317:4317"   # OTLP gRPC (for apps to push telemetry)
      - "4318:4318"   # OTLP HTTP
      - "13133:13133" # Health check
```

---

### Kubernetes

The collector runs as a **DaemonSet** — one pod per node — so it can tail logs from all containers on that node and collect host metrics.

**Prerequisites**: `kubectl` configured, `kustomize` installed (or `kubectl` v1.14+).

**1. Create the secret with your credentials**

```bash
kubectl create namespace zharp-system

kubectl create secret generic zharp-collector-secret \
  --namespace zharp-system \
  --from-literal=endpoint=https://api.zharp.io/api/v1 \
  --from-literal=api-key=your_api_key_here
```

**2. Deploy**

```bash
kubectl apply -k https://github.com/Byteinbox/zharp-logs-collector//deploy/kubernetes
```

Or clone and deploy locally:

```bash
git clone https://github.com/Byteinbox/zharp-logs-collector.git
cd zharp-otel-collector

# Update the image tag in deploy/kubernetes/daemonset.yaml if needed
kubectl apply -k deploy/kubernetes/
```

**3. Verify**

```bash
kubectl -n zharp-system get pods
kubectl -n zharp-system logs -l app=zharp-collector --follow
```

**Sidecar pattern (inject OTLP into a pod)**

To receive OTLP from an application pod on the same node, send to the DaemonSet pod on `localhost`:

```yaml
# In your application deployment env vars
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://$(HOST_IP):4317"
- name: HOST_IP
  valueFrom:
    fieldRef:
      fieldPath: status.hostIP
```

---

## Configuration

The collector uses a YAML config file. The minimal setup:

```yaml
receivers:
  filelog:
    include:
      - /var/log/nginx/access.log
    resource:
      service.name: nginx

exporters:
  zharp:
    endpoint: "https://api.zharp.io/api/v1"
    api_key: "YOUR_API_KEY"

service:
  pipelines:
    logs:
      receivers: [filelog]
      exporters: [zharp]
```

The `collector-config.yaml` file included in the release archive is a full example with all receivers configured.

---

## Database monitoring

Database receivers collect metrics by connecting directly to the database. Add credentials in your config:

### PostgreSQL

```yaml
receivers:
  postgresql:
    endpoint: localhost:5432
    username: monitoring_user
    password: ${env:PG_PASSWORD}
    databases:
      - myapp_db
    collection_interval: 30s
    tls:
      insecure: true  # set to false and add ca_file for TLS

service:
  pipelines:
    metrics:
      receivers: [postgresql]
      processors: [batch]
      exporters: [zharp]
```

Metrics collected: active connections, max connections, commits, rollbacks, database size, table bloat, index scans, cache hit ratio.

**Required PostgreSQL user permissions:**

```sql
CREATE USER zharp_monitor WITH PASSWORD 'your_password';
GRANT pg_monitor TO zharp_monitor;
-- For older PostgreSQL (<= 9.6):
GRANT SELECT ON pg_stat_database, pg_stat_user_tables TO zharp_monitor;
```

---

### Redis

```yaml
receivers:
  redis:
    endpoint: localhost:6379
    password: ${env:REDIS_PASSWORD}
    collection_interval: 30s

service:
  pipelines:
    metrics:
      receivers: [redis]
      processors: [batch]
      exporters: [zharp]
```

Metrics collected: connected clients, blocked clients, used memory, keyspace hits/misses, evicted keys, expired keys, commands per second, replication offset.

---

### MongoDB

```yaml
receivers:
  mongodb:
    hosts:
      - endpoint: localhost:27017
    username: zharp_monitor
    password: ${env:MONGO_PASSWORD}
    collection_interval: 30s
    tls:
      insecure: true

service:
  pipelines:
    metrics:
      receivers: [mongodb]
      processors: [batch]
      exporters: [zharp]
```

Metrics collected: connections, operations (insert/query/update/delete), document counts, network bytes, index stats, replication lag, storage size.

**Required MongoDB user:**

```javascript
db.createUser({
  user: "zharp_monitor",
  pwd: "your_password",
  roles: [{ role: "clusterMonitor", db: "admin" }]
})
```

---

### MySQL

```yaml
receivers:
  mysql:
    endpoint: localhost:3306
    username: zharp_monitor
    password: ${env:MYSQL_PASSWORD}
    database: myapp_db
    collection_interval: 30s

service:
  pipelines:
    metrics:
      receivers: [mysql]
      processors: [batch]
      exporters: [zharp]
```

Metrics collected: connections, queries per second, slow queries, InnoDB buffer pool hit rate, table I/O, thread states, replication lag.

**Required MySQL user:**

```sql
CREATE USER 'zharp_monitor'@'localhost' IDENTIFIED BY 'your_password';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'zharp_monitor'@'localhost';
FLUSH PRIVILEGES;
```

---

## Passing secrets safely

Never hard-code credentials in the config file. Use environment variable substitution:

```yaml
exporters:
  zharp:
    api_key: "${env:ZHARP_API_KEY}"
```

On Linux with systemd, put secrets in `/etc/zharp-collector/env`:

```bash
# /etc/zharp-collector/env
ZHARP_API_KEY=your_key_here
PG_PASSWORD=postgres_password
REDIS_PASSWORD=redis_password
```

The systemd unit file (written by the installer) already has `EnvironmentFile=/etc/zharp-collector/env`.

---

## Building from source

Requirements: Go 1.22+, [OCB](https://github.com/open-telemetry/opentelemetry-collector/tree/main/cmd/builder) installed.

```bash
# Install OCB
go install go.opentelemetry.io/collector/cmd/builder@v0.154.0

# Clone and build
git clone https://github.com/Byteinbox/zharp-logs-collector.git
cd zharp-otel-collector

builder --config builder-config.yaml

# The binary is now at ./dist/zharp-collector (or .exe on Windows)
./dist/zharp-collector --config collector-config.yaml
```

To cross-compile for Linux from macOS or Windows:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -C ./dist -ldflags="-s -w" -o ../zharp-collector-linux-amd64 .
```

---

## Health check

The collector exposes a health endpoint at `http://localhost:13133`:

```bash
curl http://localhost:13133
# {"status":"Server available","upSince":"...","uptime":"..."}
```

Use this for Docker health checks, Kubernetes readiness probes, or load balancer health checks.

---

## Support

- **Docs**: [zharp.io/docs](https://zharp.io/docs)
- **Issues**: [GitHub Issues](https://github.com/Byteinbox/zharp-logs-collector/issues)
- **Community**: [zharp.io/discord](https://zharp.io/discord)
