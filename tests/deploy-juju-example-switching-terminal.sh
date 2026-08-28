#!/usr/bin/env bash
# tests/deploy-juju-example-switching-terminal.sh
# Compiles example YANG models and deploys the Juju terminal charm.

set -eo pipefail

# Ensure script executes from the repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

VENV_PYANG=".venv/bin/pyang"
CONTROLLER_NAME="terminal-controller"
MODEL_NAME="terminal-model"
APP_NAME="quantum-terminal"

echo "=================================================================="
echo "  Compiling Example YANG & Deploying Juju Terminal Charm"
echo "=================================================================="

# 1. Compile the example YANG model to generate tree format
echo "[*] Compiling example YANG schema to tree format..."
if [ -f "$VENV_PYANG" ]; then
    "$VENV_PYANG" -f tree src/api/yang/example-quantum-switching-terminal-service.yang -o src/api/yang/example-quantum-switching-terminal-service.tree
else
    pyang -f tree src/api/yang/example-quantum-switching-terminal-service.yang -o src/api/yang/example-quantum-switching-terminal-service.tree
fi

# 2. Safely Build and Package the Charm
echo "[*] Packing the charm with Charmcraft..."
(
    cd charm/
    # Ensure all charm entry points have execution permissions before packing
    chmod +x src/*.py 2>/dev/null || true
    
    # Clean up stale charms to prevent wildcard expansion errors on re-runs
    rm -f *.charm
    charmcraft pack --destructive-mode
    
    # Safely identify and rename the newly packed charm
    PACKED_CHARM=$(ls *.charm | head -n 1)
    mv "$PACKED_CHARM" quantum-terminal.charm
)

# 3. Ensure Target Controller/Model Context is Selected
echo "[*] Selecting target Juju model (${CONTROLLER_NAME}:${MODEL_NAME})..."
if ! timeout 10s juju switch "${CONTROLLER_NAME}:${MODEL_NAME}"; then
    echo "[!] Error: Cannot connect to Juju controller '${CONTROLLER_NAME}'. The API is unresponsive."
    echo "    Run 'juju status' manually to debug, or restart WSL to fix LXD networking."
    exit 1
fi

# 4. Deploy or Refresh the Terminal Charm
echo "[*] Deploying/updating ${APP_NAME} charm..."
# Apply timeout to prevent infinite hangs if Juju loses connection
if timeout 15s juju status 2>&1 | grep -q "$APP_NAME"; then
    echo "  -> Application '$APP_NAME' is already deployed. Refreshing..."
    juju refresh "$APP_NAME" --path=./charm/quantum-terminal.charm --config controller-ip="10.0.0.1"
else
    echo "  -> Deploying fresh instance of '$APP_NAME'..."
    juju deploy ./charm/quantum-terminal.charm "$APP_NAME" --config controller-ip="10.0.0.1"
fi

echo "=================================================================="
echo "[+] Setup complete! Run ./tests/test-juju-example-switching-action.sh to trigger the action."
echo "=================================================================="
