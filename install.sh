#!/usr/bin/env bash
# Zharp Collector — guided installer
# Detects services, prompts for API key, generates config, installs systemd service.
set -euo pipefail

REPO="Byteinbox/zharp-logs-collector"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/zharp-collector"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
ENV_FILE="$CONFIG_DIR/env"
SERVICE_NAME="zharp-collector"

# ── colours ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  BOLD="\033[1m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"
  BLUE="\033[0;34m"; DIM="\033[2m"; NC="\033[0m"
else
  BOLD=""; GREEN=""; YELLOW=""; BLUE=""; DIM=""; NC=""
fi
info()    { echo -e "  ${BLUE}→${NC} $*"; }
ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}!${NC} $*"; }
section() { echo; echo -e "${BOLD}$*${NC}"; echo; }
ask()     { echo -e -n "  ${BOLD}?${NC} $* "; }

confirm() {
  ask "$1 [Y/n]:"
  local ans; read -r ans
  [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
}

# ── platform ──────────────────────────────────────────────────────────────────
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
[[ "$OS" != "linux" && "$OS" != "darwin" ]] && {
  echo "For Windows download from: https://github.com/$REPO/releases/latest" >&2; exit 1; }

# ── helpers ───────────────────────────────────────────────────────────────────
is_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
has_cmd()   { command -v "$1" &>/dev/null; }
file_or_dir_exists() { [[ -e "$1" ]]; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
touch "$TMP/env_extras"     # db passwords written here
touch "$TMP/receivers.yaml" # receiver blocks appended here
touch "$TMP/log_includes"   # one log path per line
LOG_PIPELINE=false
DB_RECEIVER_NAMES=()
EXTRA_RECEIVER_NAMES=()

# ── banner ────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}       Zharp Collector  —  Guided Installer        ${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo -e "  This will detect your services, build a config,"
echo -e "  and start the collector in about 2 minutes."
echo

# ── step 1: api key ───────────────────────────────────────────────────────────
section "Step 1 of 5 — API Key"
echo -e "  Get your key from: ${BLUE}https://app.zharp.io/settings/api-keys${NC}"
echo
ask "Paste your Zharp API key:"
read -r API_KEY
[[ -z "$API_KEY" ]] && { echo "API key is required." >&2; exit 1; }
ok "API key received."

# ── step 2: install binary ────────────────────────────────────────────────────
section "Step 2 of 5 — Download & install binary"

if has_cmd curl; then   FETCH="curl -sSfL"
elif has_cmd wget; then FETCH="wget -qO-"
else echo "curl or wget is required." >&2; exit 1; fi

VERSION="${ZHARP_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  info "Resolving latest release..."
  VERSION=$($FETCH "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/')
fi
[[ -z "$VERSION" ]] && { warn "Could not resolve version. Set ZHARP_VERSION=v1.x.x and retry."; exit 1; }

info "Downloading zharp-collector $VERSION ($OS/$ARCH)..."
ARCHIVE="zharp-collector-${VERSION}-${OS}-${ARCH}.tar.gz"
$FETCH "https://github.com/$REPO/releases/download/$VERSION/$ARCHIVE" -o "$TMP/$ARCHIVE"
tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
install -m 755 "$TMP/zharp-collector-${OS}-${ARCH}" "$INSTALL_DIR/zharp-collector"
ok "Installed → $INSTALL_DIR/zharp-collector"

# ── step 3: detect services ───────────────────────────────────────────────────
section "Step 3 of 5 — Detect running services"
echo -e "  ${DIM}Scanning for nginx, Apache, databases, Docker…${NC}"
echo

# ── host metrics (always on) ──────────────────────────────────────────────────
ok "Host metrics (CPU / memory / disk / network) — always enabled"

# ── docker ────────────────────────────────────────────────────────────────────
if has_cmd docker && docker info &>/dev/null 2>&1; then
  if confirm "Found Docker — monitor container CPU/memory/network per container?"; then
    cat >> "$TMP/receivers.yaml" <<'EOF'

  docker_stats:
    endpoint: unix:///var/run/docker.sock
    collection_interval: 30s
    timeout: 20s
EOF
    EXTRA_RECEIVER_NAMES+=("docker_stats")
    ok "Docker container metrics enabled"
  fi
fi

# ── step 4: log files ─────────────────────────────────────────────────────────
section "Step 4 of 5 — Log files"
echo -e "  We'll check for common log paths. Say Y to tail them, N to skip."
echo

add_log() {
  local label="$1" path="$2" svc="$3"
  if file_or_dir_exists "$path"; then
    if confirm "Found ${label} logs at ${path} — monitor them?"; then
      echo "$path" >> "$TMP/log_includes"
      ok "$label logs added"
    fi
  fi
}

add_log "nginx access"   "/var/log/nginx/access.log"   "nginx"
add_log "nginx error"    "/var/log/nginx/error.log"    "nginx"
add_log "Apache access"  "/var/log/apache2/access.log" "apache"
add_log "Apache access"  "/var/log/httpd/access_log"   "apache"
add_log "syslog"         "/var/log/syslog"             "system"
add_log "auth.log"       "/var/log/auth.log"           "system"
add_log "system messages" "/var/log/messages"          "system"

echo
if confirm "Add custom log paths (app logs, etc.)?"; then
  echo -e "  ${DIM}Glob patterns supported: /var/log/myapp/*.log${NC}"
  echo -e "  ${DIM}Press Enter on a blank line when done.${NC}"
  echo
  while true; do
    ask "Log path (blank to finish):"
    read -r CPATH
    [[ -z "$CPATH" ]] && break
    echo "$CPATH" >> "$TMP/log_includes"
    ok "Added: $CPATH"
  done
fi

if [[ -s "$TMP/log_includes" ]]; then
  LOG_PIPELINE=true
fi

# ── step 5: databases ─────────────────────────────────────────────────────────
section "Step 5 of 5 — Database monitoring"
echo -e "  Database receivers pull metrics directly from your DB (connections,"
echo -e "  query rates, cache hit ratios, replication lag, etc.)."
echo -e "  ${DIM}They need a read-only monitoring user — setup commands are shown below.${NC}"
echo

# ── postgresql ────────────────────────────────────────────────────────────────
if has_cmd psql || is_active postgresql || is_active postgres; then
  if confirm "Found PostgreSQL — monitor it?"; then
    ask "Host [localhost]:"        ; read -r PG_HOST; PG_HOST="${PG_HOST:-localhost}"
    ask "Port [5432]:"             ; read -r PG_PORT; PG_PORT="${PG_PORT:-5432}"
    ask "Monitoring user [zharp_monitor]:" ; read -r PG_USER; PG_USER="${PG_USER:-zharp_monitor}"
    ask "Password:"                ; read -rs PG_PASS; echo
    ask "Database name [postgres]:"; read -r PG_DB;   PG_DB="${PG_DB:-postgres}"
    cat >> "$TMP/receivers.yaml" <<EOF

  postgresql:
    endpoint: ${PG_HOST}:${PG_PORT}
    username: ${PG_USER}
    password: \${env:PG_PASSWORD}
    databases:
      - ${PG_DB}
    collection_interval: 30s
    tls:
      insecure: true
EOF
    echo "PG_PASSWORD=${PG_PASS}" >> "$TMP/env_extras"
    DB_RECEIVER_NAMES+=("postgresql")
    ok "PostgreSQL added"
    echo
    warn "Run once in psql as superuser to create the monitoring user:"
    echo -e "  ${DIM}CREATE USER ${PG_USER} WITH PASSWORD 'your_password';${NC}"
    echo -e "  ${DIM}GRANT pg_monitor TO ${PG_USER};${NC}"
    echo
  fi
fi

# ── mysql ─────────────────────────────────────────────────────────────────────
if has_cmd mysql || is_active mysql || is_active mysqld; then
  if confirm "Found MySQL — monitor it?"; then
    ask "Host [localhost]:"; read -r MY_HOST; MY_HOST="${MY_HOST:-localhost}"
    ask "Port [3306]:"     ; read -r MY_PORT; MY_PORT="${MY_PORT:-3306}"
    ask "Monitoring user [zharp_monitor]:" ; read -r MY_USER; MY_USER="${MY_USER:-zharp_monitor}"
    ask "Password:"        ; read -rs MY_PASS; echo
    cat >> "$TMP/receivers.yaml" <<EOF

  mysql:
    endpoint: ${MY_HOST}:${MY_PORT}
    username: ${MY_USER}
    password: \${env:MYSQL_PASSWORD}
    collection_interval: 30s
EOF
    echo "MYSQL_PASSWORD=${MY_PASS}" >> "$TMP/env_extras"
    DB_RECEIVER_NAMES+=("mysql")
    ok "MySQL added"
    echo
    warn "Run once in MySQL as root to create the monitoring user:"
    echo -e "  ${DIM}CREATE USER '${MY_USER}'@'localhost' IDENTIFIED BY 'your_password';${NC}"
    echo -e "  ${DIM}GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '${MY_USER}'@'localhost';${NC}"
    echo -e "  ${DIM}FLUSH PRIVILEGES;${NC}"
    echo
  fi
fi

# ── redis ─────────────────────────────────────────────────────────────────────
if has_cmd redis-cli || is_active redis || is_active redis-server; then
  if confirm "Found Redis — monitor it?"; then
    ask "Endpoint [localhost:6379]:" ; read -r RD_HOST; RD_HOST="${RD_HOST:-localhost:6379}"
    ask "Password (blank if none):"  ; read -rs RD_PASS; echo
    if [[ -n "$RD_PASS" ]]; then
      cat >> "$TMP/receivers.yaml" <<EOF

  redis:
    endpoint: ${RD_HOST}
    password: \${env:REDIS_PASSWORD}
    collection_interval: 30s
EOF
      echo "REDIS_PASSWORD=${RD_PASS}" >> "$TMP/env_extras"
    else
      cat >> "$TMP/receivers.yaml" <<EOF

  redis:
    endpoint: ${RD_HOST}
    collection_interval: 30s
EOF
    fi
    DB_RECEIVER_NAMES+=("redis")
    ok "Redis added"
  fi
fi

# ── mongodb ───────────────────────────────────────────────────────────────────
if has_cmd mongosh || has_cmd mongo || is_active mongod; then
  if confirm "Found MongoDB — monitor it?"; then
    ask "Endpoint [localhost:27017]:"  ; read -r MG_HOST; MG_HOST="${MG_HOST:-localhost:27017}"
    ask "Monitoring user [zharp_monitor]:" ; read -r MG_USER; MG_USER="${MG_USER:-zharp_monitor}"
    ask "Password:"                    ; read -rs MG_PASS; echo
    cat >> "$TMP/receivers.yaml" <<EOF

  mongodb:
    hosts:
      - endpoint: ${MG_HOST}
    username: ${MG_USER}
    password: \${env:MONGO_PASSWORD}
    collection_interval: 30s
    tls:
      insecure: true
EOF
    echo "MONGO_PASSWORD=${MG_PASS}" >> "$TMP/env_extras"
    DB_RECEIVER_NAMES+=("mongodb")
    ok "MongoDB added"
    echo
    warn "Run once in mongosh as admin to create the monitoring user:"
    echo -e "  ${DIM}db.createUser({ user: '${MG_USER}', pwd: 'your_password', roles: [{ role: 'clusterMonitor', db: 'admin' }] })${NC}"
    echo
  fi
fi

# ── generate config ───────────────────────────────────────────────────────────
section "Generating config → $CONFIG_FILE"
mkdir -p "$CONFIG_DIR"

# Build the filelog receiver block if any log paths were added
FILELOG_BLOCK=""
if [[ "$LOG_PIPELINE" == true ]]; then
  FILELOG_BLOCK="  filelog:
    include:"
  while IFS= read -r logpath; do
    FILELOG_BLOCK+="
      - ${logpath}"
  done < "$TMP/log_includes"
  FILELOG_BLOCK+="
    include_file_path: true
    include_file_name: false
"
fi

# Build extra receivers block (docker, databases)
EXTRA_RECEIVERS=""
if [[ -s "$TMP/receivers.yaml" ]]; then
  EXTRA_RECEIVERS="$(cat "$TMP/receivers.yaml")"
fi

# Build metrics pipeline receivers list
METRICS_RECEIVERS="hostmetrics"
for name in "${EXTRA_RECEIVER_NAMES[@]+"${EXTRA_RECEIVER_NAMES[@]}"}"; do
  METRICS_RECEIVERS+=", $name"
done
for name in "${DB_RECEIVER_NAMES[@]+"${DB_RECEIVER_NAMES[@]}"}"; do
  METRICS_RECEIVERS+=", $name"
done

# Build pipelines section
PIPELINES="  pipelines:"
if [[ "$LOG_PIPELINE" == true ]]; then
  PIPELINES+="
    logs:
      receivers: [filelog]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [zharp]"
fi
PIPELINES+="
    metrics:
      receivers: [$METRICS_RECEIVERS]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [zharp]"

cat > "$CONFIG_FILE" <<EOF
## Zharp Collector config — generated $(date '+%Y-%m-%d %H:%M')
## Edit this file to add more log paths or services, then:
##   sudo systemctl restart zharp-collector
## Full docs: https://github.com/Byteinbox/zharp-logs-collector

extensions:
  health_check:
    endpoint: 0.0.0.0:13133

receivers:
  hostmetrics:
    collection_interval: 60s
    scrapers:
      cpu:
      memory:
      disk:
      network:
      load:

${FILELOG_BLOCK}${EXTRA_RECEIVERS}
processors:
  batch:
    send_batch_size: 500
    timeout: 5s
  memory_limiter:
    limit_mib: 128
    spike_limit_mib: 32
    check_interval: 5s
  resourcedetection:
    detectors: [system, env]
    timeout: 5s

exporters:
  zharp:
    api_key: "\${env:ZHARP_API_KEY}"

service:
  extensions: [health_check]
${PIPELINES}
EOF

ok "Config written"

# ── write env file ────────────────────────────────────────────────────────────
{
  echo "ZHARP_API_KEY=${API_KEY}"
  cat "$TMP/env_extras"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
ok "Credentials written to $ENV_FILE"

# ── systemd (linux only) ──────────────────────────────────────────────────────
if [[ "$OS" == "linux" ]] && has_cmd systemctl; then
  if ! id -u "$SERVICE_NAME" &>/dev/null; then
    useradd --system --no-create-home --shell /sbin/nologin "$SERVICE_NAME"
    usermod -aG adm              "$SERVICE_NAME" 2>/dev/null || true
    usermod -aG systemd-journal  "$SERVICE_NAME" 2>/dev/null || true
    usermod -aG docker           "$SERVICE_NAME" 2>/dev/null || true
  fi
  chown -R "$SERVICE_NAME:$SERVICE_NAME" "$CONFIG_DIR"

  cat > /etc/systemd/system/${SERVICE_NAME}.service <<UNIT
[Unit]
Description=Zharp OpenTelemetry Collector
Documentation=https://github.com/Byteinbox/zharp-logs-collector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_NAME}
ExecStart=${INSTALL_DIR}/zharp-collector --config ${CONFIG_FILE}
EnvironmentFile=${ENV_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  sleep 2

  if is_active "$SERVICE_NAME"; then
    ok "Service is running"
  else
    warn "Service may have failed. Check with: journalctl -fu zharp-collector"
  fi
fi

# ── done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  All done! Zharp Collector is running.${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo -e "  ${BOLD}Config:${NC}   $CONFIG_FILE"
echo -e "  ${BOLD}Secrets:${NC}  $ENV_FILE"
echo
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "  ${DIM}sudo systemctl status  zharp-collector${NC}"
echo -e "  ${DIM}sudo journalctl     -fu zharp-collector${NC}"
echo -e "  ${DIM}sudo nano $CONFIG_FILE${NC}"
echo -e "  ${DIM}sudo systemctl restart zharp-collector${NC}"
echo
echo -e "  Data will appear in your Zharp dashboard within a minute."
echo
