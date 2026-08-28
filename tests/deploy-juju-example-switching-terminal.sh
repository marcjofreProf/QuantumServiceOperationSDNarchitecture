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
    
    # ---------------------------------------------------------
    # CRITICAL FIX: Juju requires execution bits and a shebang
    # ---------------------------------------------------------
    if [ -f "src/charm.py" ]; then
        # 1. Guarantee execution permissions
        chmod +x src/*.py 2>/dev/null || true
        
        # 2. Inject standard Python3 shebang if it is missing
        if ! head -n 1 src/charm.py | grep -q "^#!"; then
            echo "  -> Injecting missing Python shebang into src/charm.py"
            sed -i '1s/^/#!\/usr\/bin\/env python3\n/' src/charm.py
        fi
    fi
    
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

# Check if application exists and is in an error state
if juju status "$APP_NAME" 2>/dev/null | grep -E -q "error"; then
    echo "  -> Application '$APP_NAME' is in an error state. Purging before redeploy..."
    juju remove-application "$APP_NAME" --force --no-wait 2>/dev/null || true
    sleep 5
fi

# Apply timeout to prevent infinite hangs if Juju loses connection
if timeout 15s juju status 2>&1 | grep -q "$APP_NAME"; then
    echo "  -> Application '$APP_NAME' is already deployed. Refreshing..."
    juju refresh "$APP_NAME" --path=./charm/quantum-terminal.charm --config controller-ip="10.0.0.1"
else
    echo "  -> Deploying fresh instance of '$APP_NAME'..."
    juju deploy ./charm/quantum-terminal.charm "$APP_NAME" --config controller-ip="10.0.0.1"
fi

# 5. Wait for Machine and Application Readiness
echo "[*] Waiting for ${APP_NAME} to become active (this may take a few minutes)..."
while true; do
    STATUS_OUT=$(juju status "$APP_NAME" 2>/dev/null || true)
    
    # Check if the unit has reached the active state
    if echo "$STATUS_OUT" | grep -E -q "${APP_NAME}/[0-9]+.*active"; then
        echo "  -> Application '${APP_NAME}' is fully active and ready."
        break
    fi
    
    # Guard against error states to prevent infinite looping
    if echo "$STATUS_OUT" | grep -E -q "${APP_NAME}/[0-9]+.*error"; then
        echo "[!] Application '${APP_NAME}' encountered an error during deployment."
        echo "    Run 'juju debug-log --replay' for detailed Python tracebacks."
        break
    fi
    
    echo "  -> Provisioning machines and allocating units... (checking again in 10s)"
    sleep 10
done

echo "=================================================================="
echo "[+] Setup complete! Run ./tests/test-juju-example-switching-action.sh to trigger the action."
echo "=================================================================="
