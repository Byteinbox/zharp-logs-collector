#!/usr/bin/env bash
# Zharp Collector installer
# Usage: curl -sSL https://raw.githubusercontent.com/your-org/zharp-otel-collector/main/install.sh | sudo bash
set -euo pipefail

REPO="Byteinbox/zharp-logs-collector"
INSTALL_DIR="/usr/local/bin"
SERVICE_NAME="zharp-collector"
CONFIG_DIR="/etc/zharp-collector"

# ── detect platform ──────────────────────────────────────────────────────────
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *)
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

if [[ "$OS" != "linux" && "$OS" != "darwin" ]]; then
  echo "This script supports Linux and macOS. For Windows, download the .exe from:"
  echo "  https://github.com/$REPO/releases/latest"
  exit 1
fi

# ── resolve latest version ───────────────────────────────────────────────────
if command -v curl &>/dev/null; then
  FETCH="curl -sSfL"
elif command -v wget &>/dev/null; then
  FETCH="wget -qO-"
else
  echo "curl or wget is required" >&2
  exit 1
fi

VERSION="${ZHARP_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  VERSION=$($FETCH "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/')
fi

if [[ -z "$VERSION" ]]; then
  echo "Could not determine latest release version." >&2
  echo "Set ZHARP_VERSION=v1.0.0 to pin a specific version." >&2
  exit 1
fi

echo "Installing zharp-collector $VERSION ($OS/$ARCH)..."

# ── download ─────────────────────────────────────────────────────────────────
ARCHIVE="zharp-collector-${VERSION}-${OS}-${ARCH}.tar.gz"
URL="https://github.com/$REPO/releases/download/$VERSION/$ARCHIVE"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

$FETCH "$URL" -o "$TMP/$ARCHIVE"
tar -xzf "$TMP/$ARCHIVE" -C "$TMP"

# ── install binary ────────────────────────────────────────────────────────────
install -m 755 "$TMP/zharp-collector-${OS}-${ARCH}" "$INSTALL_DIR/zharp-collector"
echo "Binary installed to $INSTALL_DIR/zharp-collector"

# ── install default config (only if not already present) ─────────────────────
mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/config.yaml" ]]; then
  install -m 644 "$TMP/collector-config.yaml" "$CONFIG_DIR/config.yaml"
  echo "Default config written to $CONFIG_DIR/config.yaml"
  echo ""
  echo "  Edit $CONFIG_DIR/config.yaml and set your API key before starting."
else
  echo "Existing config at $CONFIG_DIR/config.yaml left unchanged."
fi

# ── systemd service (Linux only) ─────────────────────────────────────────────
if [[ "$OS" == "linux" ]] && command -v systemctl &>/dev/null; then
  cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Zharp OpenTelemetry Collector
Documentation=https://github.com/$REPO
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/zharp-collector --config $CONFIG_DIR/config.yaml
Restart=on-failure
RestartSec=5s
# Run as the zharp-collector system user if it exists, otherwise root
User=zharp-collector
EnvironmentFile=-/etc/zharp-collector/env

# Resource limits
LimitNOFILE=65536
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

  # Create a dedicated system user if it doesn't exist
  if ! id -u zharp-collector &>/dev/null; then
    useradd --system --no-create-home --shell /sbin/nologin zharp-collector
    # Grant read access to logs
    usermod -aG adm zharp-collector 2>/dev/null || true
    usermod -aG systemd-journal zharp-collector 2>/dev/null || true
  fi

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"

  echo ""
  echo "Systemd service installed. Start with:"
  echo "  sudo systemctl start zharp-collector"
  echo "  sudo journalctl -fu zharp-collector"
else
  echo ""
  echo "Run manually:"
  echo "  zharp-collector --config $CONFIG_DIR/config.yaml"
fi

echo ""
echo "Done. zharp-collector $VERSION installed."
