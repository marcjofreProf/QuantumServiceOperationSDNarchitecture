#!/usr/bin/env bash
# tests/test-juju-example-switching-action.sh
# Triggers the RESTCONF cross-connect action via the deployed Juju charm.

set -eo pipefail

# 1. Ensure script executes relative to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

CONTROLLER_NAME="terminal-controller"
MODEL_NAME="terminal-model"
APP_NAME="quantum-terminal"

echo "=================================================================="
echo "  Testing Juju Action: create-cross-connect"
echo "=================================================================="

# 2. Switch active context to target model
echo "[*] Selecting model context (${CONTROLLER_NAME}:${MODEL_NAME})..."
juju switch "${CONTROLLER_NAME}:${MODEL_NAME}" 2>/dev/null || juju switch "${MODEL_NAME}" 2>/dev/null || true

# 3. Dynamically discover active application unit
UNIT_NAME=$(juju status --format=line 2>/dev/null | grep -oE "${APP_NAME}/[0-9]+" | head -n 1 || true)
if [ -z "$UNIT_NAME" ]; then
    UNIT_NAME="${APP_NAME}/0"
fi

echo "[*] Triggering create-cross-connect action on ${UNIT_NAME}..."

# 4. Run action and return exact stdout/stderr status
# Added --wait 5m to prevent Juju from prematurely timing out on queued tasks
if ACTION_OUTPUT=$(juju run "$UNIT_NAME" create-cross-connect \
  service-id="example-qservice-opt-01" \
  target-node-ip="10.0.0.254" \
  ingress-port=1 \
  egress-port=2 \
  admin-state="ENABLED" \
  --wait 5m 2>&1); then
    echo "$ACTION_OUTPUT"
    echo "=================================================================="
    echo "[+] Action execution succeeded."
    echo "=================================================================="
else
    echo "$ACTION_OUTPUT"
    echo "=================================================================="
    echo "[!] Juju action failed. Verify unit status with 'juju status'."
    echo "=================================================================="
    exit 1
fi
