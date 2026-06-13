#!/usr/bin/env bash
# Zharp Collector — guided installer
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
  BLUE="\033[0;34m"; CYAN="\033[0;36m"; DIM="\033[2m"; NC="\033[0m"
else
  BOLD=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; DIM=""; NC=""
fi
ok()      { echo -e "  ${GREEN}✓${NC}  $*"; }
info()    { echo -e "  ${BLUE}→${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}!${NC}  $*"; }
dim()     { echo -e "     ${DIM}$*${NC}"; }
section() { echo; echo -e "${BOLD}$*${NC}"; echo; }
hr()      { echo -e "  ${DIM}──────────────────────────────────────────────────${NC}"; }
ask()     { echo -e -n "  ${CYAN}?${NC}  ${BOLD}$*${NC} "; }

# ── platform ──────────────────────────────────────────────────────────────────
_UNAME="$(uname -s)"
OS="$(echo "$_UNAME" | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

# On Windows under Git Bash / MSYS2 / Cygwin, hand off to the PowerShell setup.
if [[ "$_UNAME" =~ MINGW|MSYS|CYGWIN ]]; then
  echo
  echo -e "${BOLD}  Windows detected — launching PowerShell setup...${NC}"
  echo
  PS1_LOCAL="$(dirname "$0")/setup.ps1"
  if [[ -f "$PS1_LOCAL" ]]; then
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$(cygpath -w "$PS1_LOCAL")"
  else
    powershell.exe -ExecutionPolicy Bypass -NoProfile \
      -Command "irm https://raw.githubusercontent.com/$REPO/main/setup.ps1 | iex"
  fi
  exit $?
fi

[[ "$OS" != "linux" && "$OS" != "darwin" ]] && {
  echo "Unsupported OS: $_UNAME" >&2; exit 1; }

has_cmd() { command -v "$1" &>/dev/null; }
is_svc()  { systemctl is-active --quiet "$1" 2>/dev/null; }
path_ok() { [[ -e "$1" ]]; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
touch "$TMP/env_extras"
touch "$TMP/receiver_blocks"
LOG_PATHS=()
ADD_FILELOG=false
METRICS_RECEIVERS=("hostmetrics")

# When piped via `curl | bash`, stdin is the download stream — not the terminal.
# Reopen stdin from /dev/tty so interactive read prompts work correctly.
[ -t 0 ] || exec < /dev/tty

# ── banner ────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}       Zharp Collector  ·  Guided Setup            ${NC}"
echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

# ── step 1: download binary ───────────────────────────────────────────────────
section "1 · Downloading collector"

if has_cmd curl; then   FETCH="curl -sSfL"
elif has_cmd wget; then FETCH="wget -qO-"
else echo "curl or wget is required." >&2; exit 1; fi

VERSION="${ZHARP_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  info "Resolving latest release..."
  VERSION=$($FETCH "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/')
fi
[[ -z "$VERSION" ]] && { warn "Set ZHARP_VERSION=v1.x.x and retry."; exit 1; }

info "Downloading zharp-collector $VERSION ($OS/$ARCH)..."
ARCHIVE="zharp-collector-${VERSION}-${OS}-${ARCH}.tar.gz"
$FETCH "https://github.com/$REPO/releases/download/$VERSION/$ARCHIVE" -o "$TMP/$ARCHIVE"
tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
install -m 755 "$TMP/zharp-collector-${OS}-${ARCH}" "$INSTALL_DIR/zharp-collector"
ok "Installed → $INSTALL_DIR/zharp-collector"

# ── step 2: scan ─────────────────────────────────────────────────────────────
section "2 · Scanning this server..."

ALL_LABELS=()
ALL_TYPES=()
ALL_DETAILS=()
ALL_DETECTED=()

add_option() {
  ALL_LABELS+=("$1")
  ALL_TYPES+=("$2")
  ALL_DETAILS+=("$3")
  ALL_DETECTED+=("$4")
}

if path_ok /var/log/nginx/access.log || is_svc nginx || has_cmd nginx; then
  NPATHS="/var/log/nginx/access.log"
  path_ok /var/log/nginx/error.log && NPATHS+=" + error.log"
  add_option "nginx"           "nginx_log"  "logs at $NPATHS"            "yes"
fi

if path_ok /var/log/apache2/access.log || path_ok /var/log/httpd/access_log \
    || is_svc apache2 || is_svc httpd; then
  APD=$( path_ok /var/log/apache2/access.log && echo /var/log/apache2/ || echo /var/log/httpd/ )
  add_option "Apache"          "apache_log" "logs at $APD"               "yes"
fi

if path_ok /var/log/syslog || path_ok /var/log/messages; then
  add_option "System logs"     "syslog"     "/var/log/syslog, auth.log"  "yes"
fi

if has_cmd psql || is_svc postgresql || is_svc postgres; then
  add_option "PostgreSQL"      "pg"         "detected on localhost:5432"  "yes"
fi

if has_cmd mysql || is_svc mysql || is_svc mysqld || is_svc mariadb; then
  add_option "MySQL / MariaDB" "mysql"      "detected on localhost:3306"  "yes"
fi

if has_cmd redis-cli || is_svc redis || is_svc redis-server; then
  add_option "Redis"           "redis"      "detected on localhost:6379"  "yes"
fi

if has_cmd mongosh || has_cmd mongo || is_svc mongod; then
  add_option "MongoDB"         "mongo"      "detected on localhost:27017" "yes"
fi

if has_cmd docker && docker info &>/dev/null 2>&1; then
  CNT=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
  add_option "Docker"          "docker"     "$CNT container(s) running"   "yes"
fi

type_detected() {
  local t="$1"
  for i in "${!ALL_TYPES[@]}"; do
    [[ "${ALL_TYPES[$i]}" == "$t" ]] && return 0
  done
  return 1
}

type_detected nginx_log  || add_option "nginx logs"      "nginx_log"  "tail nginx access/error log"  "no"
type_detected apache_log || add_option "Apache logs"     "apache_log" "tail Apache access log"       "no"
type_detected syslog     || add_option "System logs"     "syslog"     "/var/log/syslog, auth.log"    "no"
type_detected pg         || add_option "PostgreSQL"      "pg"         "database metrics"             "no"
type_detected mysql      || add_option "MySQL / MariaDB" "mysql"      "database metrics"             "no"
type_detected redis      || add_option "Redis"           "redis"      "in-memory store metrics"      "no"
type_detected mongo      || add_option "MongoDB"         "mongo"      "database metrics"             "no"
type_detected docker     || add_option "Docker"          "docker"     "container metrics"            "no"
add_option "Custom log file" "custom_log" "any log path or glob pattern"  "no"

DONE_INDICES=()

is_done() {
  local idx="$1"
  for d in "${DONE_INDICES[@]+"${DONE_INDICES[@]}"}"; do
    [[ "$d" == "$idx" ]] && return 0
  done
  return 1
}

show_menu() {
  local row=0

  local has_detected=false
  for i in "${!ALL_LABELS[@]}"; do
    [[ "${ALL_DETECTED[$i]}" == "yes" ]] && is_done "$i" && continue
    [[ "${ALL_DETECTED[$i]}" == "yes" ]] && { has_detected=true; break; }
  done

  if $has_detected; then
    echo -e "  ${BOLD}Detected on this server:${NC}"
    hr
    for i in "${!ALL_LABELS[@]}"; do
      [[ "${ALL_DETECTED[$i]}" != "yes" ]] && continue
      is_done "$i" && continue
      row=$(( row + 1 ))
      printf "  ${CYAN}[%d]${NC}  %-24s ${DIM}%s${NC}\n" \
        "$row" "${ALL_LABELS[$i]}" "${ALL_DETAILS[$i]}"
      MENU_MAP[$row]=$i
    done
  fi

  local has_manual=false
  for i in "${!ALL_LABELS[@]}"; do
    [[ "${ALL_DETECTED[$i]}" == "no" ]] && is_done "$i" && continue
    [[ "${ALL_DETECTED[$i]}" == "no" ]] && { has_manual=true; break; }
  done

  if $has_manual; then
    [[ $row -gt 0 ]] && echo
    echo -e "  ${BOLD}Add manually:${NC}"
    hr
    for i in "${!ALL_LABELS[@]}"; do
      [[ "${ALL_DETECTED[$i]}" != "no" ]] && continue
      is_done "$i" && continue
      row=$(( row + 1 ))
      printf "  ${CYAN}[%d]${NC}  %-24s ${DIM}%s${NC}\n" \
        "$row" "${ALL_LABELS[$i]}" "${ALL_DETAILS[$i]}"
      MENU_MAP[$row]=$i
    done
  fi

  MENU_ROWS=$row
}

configure_type() {
  local TYPE="$1"
  echo

  case "$TYPE" in
    nginx_log)
      echo -e "  ${BOLD}nginx — log paths${NC}"
      ask "Access log [/var/log/nginx/access.log]:"
      read -r P; P="${P:-/var/log/nginx/access.log}"
      LOG_PATHS+=("$P")
      ask "Error log  [/var/log/nginx/error.log]  (blank to skip):"
      read -r E
      [[ -n "$E" ]] && LOG_PATHS+=("$E")
      [[ -z "$E" ]] && path_ok /var/log/nginx/error.log && LOG_PATHS+=("/var/log/nginx/error.log")
      ADD_FILELOG=true
      ok "nginx logs configured."
      ;;

    apache_log)
      echo -e "  ${BOLD}Apache — log path${NC}"
      DEFAULT=/var/log/apache2/access.log
      path_ok /var/log/httpd/access_log && DEFAULT=/var/log/httpd/access_log
      ask "Access log [$DEFAULT]:"
      read -r P; P="${P:-$DEFAULT}"
      LOG_PATHS+=("$P")
      ADD_FILELOG=true
      ok "Apache logs configured."
      ;;

    syslog)
      path_ok /var/log/syslog   && LOG_PATHS+=("/var/log/syslog")
      path_ok /var/log/messages && LOG_PATHS+=("/var/log/messages")
      path_ok /var/log/auth.log && LOG_PATHS+=("/var/log/auth.log")
      ADD_FILELOG=true
      ok "System logs configured."
      ;;

    custom_log)
      echo -e "  ${BOLD}Custom log paths${NC}"
      dim "Glob patterns OK: /var/log/myapp/*.log"
      dim "Press Enter on a blank line when done."
      echo
      while true; do
        ask "Log path (blank to finish):"
        read -r P; [[ -z "$P" ]] && break
        LOG_PATHS+=("$P"); ok "Added: $P"
      done
      ADD_FILELOG=true
      ;;

    pg)
      echo -e "  ${BOLD}PostgreSQL${NC}"
      ask "Host   [localhost]:"     ; read -r H;    H="${H:-localhost}"
      ask "Port   [5432]:"          ; read -r PT;   PT="${PT:-5432}"
      ask "User   [zharp_monitor]:" ; read -r U;    U="${U:-zharp_monitor}"
      ask "Password:"               ; read -rs PASS; echo
      ask "Database [postgres]:"    ; read -r DB;   DB="${DB:-postgres}"
      cat >> "$TMP/receiver_blocks" <<EOF

  postgresql:
    endpoint: ${H}:${PT}
    username: ${U}
    password: \${env:PG_PASSWORD}
    databases:
      - ${DB}
    collection_interval: 30s
    tls:
      insecure: true
EOF
      echo "PG_PASSWORD=${PASS}" >> "$TMP/env_extras"
      METRICS_RECEIVERS+=("postgresql")
      ok "PostgreSQL configured."
      echo
      warn "Required — run once as superuser:"
      dim "CREATE USER ${U} WITH PASSWORD 'your_password';"
      dim "GRANT pg_monitor TO ${U};"
      ;;

    mysql)
      echo -e "  ${BOLD}MySQL / MariaDB${NC}"
      ask "Host   [localhost]:"     ; read -r H;    H="${H:-localhost}"
      ask "Port   [3306]:"          ; read -r PT;   PT="${PT:-3306}"
      ask "User   [zharp_monitor]:" ; read -r U;    U="${U:-zharp_monitor}"
      ask "Password:"               ; read -rs PASS; echo
      cat >> "$TMP/receiver_blocks" <<EOF

  mysql:
    endpoint: ${H}:${PT}
    username: ${U}
    password: \${env:MYSQL_PASSWORD}
    collection_interval: 30s
EOF
      echo "MYSQL_PASSWORD=${PASS}" >> "$TMP/env_extras"
      METRICS_RECEIVERS+=("mysql")
      ok "MySQL configured."
      echo
      warn "Required — run once as root:"
      dim "CREATE USER '${U}'@'localhost' IDENTIFIED BY 'your_password';"
      dim "GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '${U}'@'localhost';"
      dim "FLUSH PRIVILEGES;"
      ;;

    redis)
      echo -e "  ${BOLD}Redis${NC}"
      ask "Endpoint [localhost:6379]:" ; read -r EP; EP="${EP:-localhost:6379}"
      ask "Password (blank if none):"  ; read -rs PASS; echo
      if [[ -n "$PASS" ]]; then
        cat >> "$TMP/receiver_blocks" <<EOF

  redis:
    endpoint: ${EP}
    password: \${env:REDIS_PASSWORD}
    collection_interval: 30s
EOF
        echo "REDIS_PASSWORD=${PASS}" >> "$TMP/env_extras"
      else
        cat >> "$TMP/receiver_blocks" <<EOF

  redis:
    endpoint: ${EP}
    collection_interval: 30s
EOF
      fi
      METRICS_RECEIVERS+=("redis")
      ok "Redis configured."
      ;;

    mongo)
      echo -e "  ${BOLD}MongoDB${NC}"
      ask "Endpoint [localhost:27017]:" ; read -r EP; EP="${EP:-localhost:27017}"
      ask "User   [zharp_monitor]:"     ; read -r U;  U="${U:-zharp_monitor}"
      ask "Password:"                   ; read -rs PASS; echo
      cat >> "$TMP/receiver_blocks" <<EOF

  mongodb:
    hosts:
      - endpoint: ${EP}
    username: ${U}
    password: \${env:MONGO_PASSWORD}
    collection_interval: 30s
    tls:
      insecure: true
EOF
      echo "MONGO_PASSWORD=${PASS}" >> "$TMP/env_extras"
      METRICS_RECEIVERS+=("mongodb")
      ok "MongoDB configured."
      echo
      warn "Required — run once in mongosh as admin:"
      dim "db.createUser({ user: '${U}', pwd: 'your_password',"
      dim "  roles: [{ role: 'clusterMonitor', db: 'admin' }] })"
      ;;

    docker)
      cat >> "$TMP/receiver_blocks" <<'EOF'

  docker_stats:
    endpoint: unix:///var/run/docker.sock
    collection_interval: 30s
    timeout: 20s
EOF
      METRICS_RECEIVERS+=("docker_stats")
      ok "Docker container metrics configured."
      ;;
  esac
}

# ── step 3: api key ───────────────────────────────────────────────────────────
section "3 · API Key"
dim "Get yours at: https://zharp.io/settings/api-keys"
echo
ask "Paste your API key:"
read -r API_KEY
[[ -z "$API_KEY" ]] && { echo "API key is required." >&2; exit 1; }
ok "API key saved."

# ── step 4: what to monitor ───────────────────────────────────────────────────
section "4 · What do you want to monitor?"
echo -e "  ${DIM}Host metrics (CPU, memory, disk, network) are always collected.${NC}"
echo

while true; do
  declare -A MENU_MAP=()
  MENU_ROWS=0
  show_menu

  if [[ $MENU_ROWS -eq 0 ]]; then
    ok "All available services configured."
    break
  fi

  echo
  ask "Pick a number to configure, or press Enter to finish:"
  read -r PICK

  [[ -z "$PICK" ]] && break

  if ! [[ "$PICK" =~ ^[0-9]+$ ]] || (( PICK < 1 )) || (( PICK > MENU_ROWS )); then
    warn "Enter a number between 1 and $MENU_ROWS, or press Enter to finish."
    echo; continue
  fi

  REAL_IDX="${MENU_MAP[$PICK]}"
  SELECTED_TYPE="${ALL_TYPES[$REAL_IDX]}"
  SELECTED_LABEL="${ALL_LABELS[$REAL_IDX]}"

  echo
  echo -e "  ${BOLD}Configuring: $SELECTED_LABEL${NC}"
  configure_type "$SELECTED_TYPE"
  DONE_INDICES+=("$REAL_IDX")

  echo
  ask "Monitor another service? [Y/n]:"
  read -r MORE
  [[ "$MORE" =~ ^[Nn] ]] && break
  echo
done

# ── step 5: generate config ───────────────────────────────────────────────────
section "5 · Writing config"
mkdir -p "$CONFIG_DIR"

FILELOG_BLOCK=""
if [[ "$ADD_FILELOG" == true ]] && [[ ${#LOG_PATHS[@]} -gt 0 ]]; then
  FILELOG_BLOCK="  filelog:
    include:"
  for p in "${LOG_PATHS[@]}"; do
    FILELOG_BLOCK+="
      - ${p}"
  done
  FILELOG_BLOCK+="
    include_file_path: true
    include_file_name: false
"
fi

EXTRA_BLOCKS=""
[[ -s "$TMP/receiver_blocks" ]] && EXTRA_BLOCKS="$(cat "$TMP/receiver_blocks")"

PIPELINES="  pipelines:"
if [[ "$ADD_FILELOG" == true ]]; then
  PIPELINES+="
    logs:
      receivers: [filelog]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [zharp]"
fi
printf -v METRICS_LIST '%s, ' "${METRICS_RECEIVERS[@]}"
METRICS_LIST="${METRICS_LIST%, }"
PIPELINES+="
    metrics:
      receivers: [${METRICS_LIST}]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [zharp]"

cat > "$CONFIG_FILE" <<EOF
## Zharp Collector config — generated $(date '+%Y-%m-%d %H:%M')
## To add more: edit this file then run: sudo systemctl restart zharp-collector

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

${FILELOG_BLOCK}${EXTRA_BLOCKS}
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
ok "Config → $CONFIG_FILE"

{ echo "ZHARP_API_KEY=${API_KEY}"; cat "$TMP/env_extras"; } > "$ENV_FILE"
chmod 600 "$ENV_FILE"
ok "Secrets → $ENV_FILE"

# ── step 6: systemd ───────────────────────────────────────────────────────────
if [[ "$OS" == "linux" ]] && has_cmd systemctl; then
  if ! id -u "$SERVICE_NAME" &>/dev/null; then
    useradd --system --no-create-home --shell /sbin/nologin "$SERVICE_NAME"
    usermod -aG adm             "$SERVICE_NAME" 2>/dev/null || true
    usermod -aG systemd-journal "$SERVICE_NAME" 2>/dev/null || true
    usermod -aG docker          "$SERVICE_NAME" 2>/dev/null || true
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
  is_svc "$SERVICE_NAME" \
    && ok "Service started." \
    || warn "Check logs: journalctl -fu zharp-collector"
fi

# ── step 6 (macOS): launchd ───────────────────────────────────────────────────
if [[ "$OS" == "darwin" ]]; then
  PLIST_LABEL="io.zharp.collector"
  PLIST_FILE="/Library/LaunchDaemons/${PLIST_LABEL}.plist"

  # Unload existing service if present
  launchctl list "$PLIST_LABEL" &>/dev/null && launchctl unload -w "$PLIST_FILE" 2>/dev/null || true

  # Build EnvironmentVariables XML block from env file
  ENV_XML=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    # Escape XML special chars in value
    val="${val//&/&amp;}"
    val="${val//</&lt;}"
    val="${val//>/&gt;}"
    val="${val//\"/&quot;}"
    ENV_XML+="        <key>${key}</key>
        <string>${val}</string>
"
  done < "$ENV_FILE"

  cat > "$PLIST_FILE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/zharp-collector</string>
        <string>--config</string>
        <string>${CONFIG_FILE}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
${ENV_XML}    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/zharp-collector.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/zharp-collector.log</string>
</dict>
</plist>
PLIST

  chmod 644 "$PLIST_FILE"
  launchctl load -w "$PLIST_FILE"
  sleep 2

  if launchctl list | grep -q "$PLIST_LABEL"; then
    ok "Service loaded (launchd)."
  else
    warn "Check logs: sudo tail -f /var/log/zharp-collector.log"
    warn "Or: sudo launchctl list $PLIST_LABEL"
  fi
fi

# ── done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}    Done! Zharp Collector is running.${NC}"
echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo -e "  ${BOLD}Config:${NC}  $CONFIG_FILE"
echo -e "  ${BOLD}Secrets:${NC} $ENV_FILE"
echo
if [[ "$OS" == "darwin" ]]; then
  dim "sudo launchctl list io.zharp.collector"
  dim "sudo launchctl unload /Library/LaunchDaemons/io.zharp.collector.plist && sudo launchctl load -w /Library/LaunchDaemons/io.zharp.collector.plist"
  dim "sudo tail -f /var/log/zharp-collector.log"
  dim "sudo nano $CONFIG_FILE"
else
  dim "sudo systemctl status  zharp-collector"
  dim "sudo journalctl     -fu zharp-collector"
  dim "sudo nano $CONFIG_FILE"
  dim "sudo systemctl restart zharp-collector"
fi
echo
echo -e "  Data will appear in your Zharp dashboard within a minute."
echo
