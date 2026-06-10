#!/usr/bin/env bash
# E2E Observability Agent — VM installer (DEV one-liner; no register API, no CDN)
#
# The public register API and object-store CDN are not deployed yet, so this
# variant takes a PRE-MINTED token (from LogGroupService.CreateLogGroup) and
# pulls the binary from the repo's public GitHub Release.
#
# Usage:
#   E2E_TOKEN=sk_xxx \
#   E2E_LOG_GROUP=logs.<customer>.<resource>.vm \
#   E2E_PROJECT_ID=<project_id> \
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/daksh-e2e/otel-collector/test/install-dev.sh)"
set -euo pipefail

RELEASE_TAG="v0.1.0-dev"
REPO="daksh-e2e/otel-collector"
BRANCH="test"
RELEASE_BASE="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
CONFIG_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/samples/vm-config.yaml"

BINARY_PATH="/usr/local/bin/e2e-otelcol"
CONFIG_DIR="/etc/e2e-otel-collector"
DATA_DIR="/var/lib/e2e-otel-collector"
SERVICE_NAME="e2e-otel-collector"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

info()  { echo "[e2e-install] $*"; }
error() { echo "[e2e-install] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ]            || error "Run as root."
command -v curl >/dev/null      || error "curl required."
command -v systemctl >/dev/null || error "systemd required."
[ -n "${E2E_TOKEN:-}" ]         || error "E2E_TOKEN not set (mint via CreateLogGroup)."
[ -n "${E2E_LOG_GROUP:-}" ]     || error "E2E_LOG_GROUP not set."
[ -n "${E2E_PROJECT_ID:-}" ]    || error "E2E_PROJECT_ID not set."

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) error "Unsupported arch: $(uname -m)" ;;
esac

info "Downloading binary (${ARCH}) from release ${RELEASE_TAG}..."
curl -fsSL --progress-bar -o "${BINARY_PATH}.tmp" \
  "${RELEASE_BASE}/e2e-otel-collector-linux-${ARCH}" \
  || error "Binary download failed from ${RELEASE_BASE}."
chmod +x "${BINARY_PATH}.tmp"; mv "${BINARY_PATH}.tmp" "${BINARY_PATH}"

mkdir -p "${CONFIG_DIR}" "${DATA_DIR}/tmp"
chmod 755 "${CONFIG_DIR}"; chmod 700 "${DATA_DIR}"

info "Fetching config..."
curl -fsSL -o "${CONFIG_DIR}/config.yaml" "${CONFIG_URL}" || error "Config download failed."
chmod 644 "${CONFIG_DIR}/config.yaml"

host_name=$(hostname -f 2>/dev/null || hostname)
cat > "${CONFIG_DIR}/env" <<EOF
E2E_TOKEN=${E2E_TOKEN}
HOST_NAME=${host_name}
E2E_LOG_GROUP=${E2E_LOG_GROUP}
E2E_PROJECT_ID=${E2E_PROJECT_ID}
EOF
chmod 600 "${CONFIG_DIR}/env"

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=E2E Observability Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=${CONFIG_DIR}/env
ExecStart=${BINARY_PATH} --config=${CONFIG_DIR}/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

echo ""
echo " E2E agent installed. Host: ${host_name}  Log group: ${E2E_LOG_GROUP}"
echo " Status: systemctl status ${SERVICE_NAME}   Logs: journalctl -u ${SERVICE_NAME} -f"
