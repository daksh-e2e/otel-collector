#!/usr/bin/env bash
# E2E Observability Agent — VM installer (DEV / manual path)
#
# Use this when the public register API (obs.e2enetworks.net) and the CDN are
# not yet deployed. It takes a token you minted directly against the cluster
# (LogGroupService.CreateLogGroup) and a binary you already copied to the VM.
#
# Usage (run as root ON THE VM):
#   E2E_TOKEN=sk_xxx \
#   E2E_LOG_GROUP=logs.infra.vm.<id> \
#   E2E_PROJECT_ID=<project_id> \
#   BINARY_SRC=/tmp/e2e-otel-collector-linux-amd64 \
#   CONFIG_SRC=/tmp/vm-config.yaml \
#     bash install-vm-dev.sh
set -euo pipefail

BINARY_NAME="e2e-otelcol"
BINARY_PATH="/usr/local/bin/${BINARY_NAME}"
CONFIG_DIR="/etc/e2e-otel-collector"
DATA_DIR="/var/lib/e2e-otel-collector"
SERVICE_NAME="e2e-otel-collector"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

BINARY_SRC="${BINARY_SRC:-/tmp/e2e-otel-collector-linux-amd64}"
CONFIG_SRC="${CONFIG_SRC:-/tmp/vm-config.yaml}"

info()  { echo "[e2e-install] $*"; }
error() { echo "[e2e-install] ERROR: $*" >&2; exit 1; }

# ── Preflight ──────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ]                || error "Run as root."
command -v systemctl >/dev/null     || error "systemd required."
[ -n "${E2E_TOKEN:-}" ]             || error "E2E_TOKEN not set (mint via CreateLogGroup)."
[ -n "${E2E_LOG_GROUP:-}" ]         || error "E2E_LOG_GROUP not set."
[ -n "${E2E_PROJECT_ID:-}" ]        || error "E2E_PROJECT_ID not set."
[ -f "${BINARY_SRC}" ]              || error "Binary not found at ${BINARY_SRC} (scp it first)."
[ -f "${CONFIG_SRC}" ]             || error "Config not found at ${CONFIG_SRC} (scp samples/vm-config.yaml)."

# ── Install binary ─────────────────────────────────────────────────────────
info "Installing binary -> ${BINARY_PATH}"
install -m 0755 "${BINARY_SRC}" "${BINARY_PATH}"

# ── Dirs + config + env ────────────────────────────────────────────────────
mkdir -p "${CONFIG_DIR}" "${DATA_DIR}/tmp"
chmod 755 "${CONFIG_DIR}"; chmod 700 "${DATA_DIR}"

install -m 0644 "${CONFIG_SRC}" "${CONFIG_DIR}/config.yaml"

host_name=$(hostname -f 2>/dev/null || hostname)
info "Writing env -> ${CONFIG_DIR}/env (host=${host_name})"
cat > "${CONFIG_DIR}/env" <<EOF
E2E_TOKEN=${E2E_TOKEN}
HOST_NAME=${host_name}
E2E_LOG_GROUP=${E2E_LOG_GROUP}
E2E_PROJECT_ID=${E2E_PROJECT_ID}
EOF
chmod 600 "${CONFIG_DIR}/env"

# ── systemd unit ───────────────────────────────────────────────────────────
info "Installing systemd unit"
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
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " E2E agent installed (dev path)"
echo " Host:      ${host_name}"
echo " Log group: ${E2E_LOG_GROUP}"
echo " Status:    systemctl status ${SERVICE_NAME}"
echo " Logs:      journalctl -u ${SERVICE_NAME} -f"
echo " Health:    curl -s http://localhost:13133"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
