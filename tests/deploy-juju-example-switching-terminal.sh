#!/usr/bin/env bash
# tests/deploy-juju-example-terminal.sh
# Compiles example YANG models and deploys the Juju terminal charm.

set -e

VENV_PYANG=".venv/bin/pyang"

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

# 2. Build the charm (NEW STEP)
echo "[*] Packing the charm with Charmcraft..."
cd charm/
charmcraft pack --destructive-mode
# Rename the dynamically generated file to exactly what the script expects
mv *.charm quantum-terminal.charm
cd ..

# 3. Deploy the example terminal charm
echo "[*] Deploying quantum-terminal charm..."
juju deploy ./charm/quantum-terminal.charm --config controller-ip="10.0.0.1" || echo "[!] Juju deployment command failed. Ensure your Juju controller is active."

echo "=================================================================="
echo "[+] Setup complete. Run ./tests/test-juju-example-switching-action.sh to trigger the action."
echo "=================================================================="
