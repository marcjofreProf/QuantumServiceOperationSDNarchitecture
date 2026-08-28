#!/usr/bin/env bash
# uninstall-bootstrap-oss-terminal.sh
# Reverses the environment setup for QuantumServiceOperationSDNarchitecture

set -eo pipefail

echo "=================================================================="
echo "  Uninstalling QuantumServiceOperationSDNarchitecture Environment"
echo "=================================================================="

# 1. Destroy Juju Controller and Models (NEW)
echo "[*] Tearing down Juju controller and LXD containers..."
if command -v juju &>/dev/null; then
    juju destroy-controller terminal-controller --destroy-all-models --force --yes 2>/dev/null || true
    juju unregister terminal-controller 2>/dev/null || true
    
    # Scrub LXD trust and local credentials to ensure clean slate for future bootstraps
    sudo lxc config trust rm juju 2>/dev/null || true
    lxc config trust rm juju 2>/dev/null || true
    rm -rf ~/.local/share/juju
    echo "  -> Juju controller 'terminal-controller' destroyed."
else
    echo "  -> Juju CLI not found. Skipping controller teardown."
fi

# 2. Remove isolated virtual environment
VENV_DIR=".venv"
if [ -d "$VENV_DIR" ]; then
    echo "[*] Removing Python virtual environment (${VENV_DIR})..."
    rm -rf "$VENV_DIR"
    echo "  -> Removed ${VENV_DIR}/"
else
    echo "[*] Virtual environment (${VENV_DIR}) not found. Skipping."
fi

# 3. Clean generated gRPC / Protobuf stubs
for STUB_DIR in "src/api/proto" "src/api/grpc"; do
    if [ -d "$STUB_DIR" ]; then
        echo "[*] Removing compiled Python gRPC stubs in ${STUB_DIR}..."
        find "$STUB_DIR" -type f \( -name "*_pb2.py" -o -name "*_pb2_grpc.py" \) -delete
        echo "  -> Cleaned ${STUB_DIR}/"
    fi
done

# 4. Clean compiled YANG tree files
YANG_DIR="src/api/yang"
if [ -d "$YANG_DIR" ]; then
    echo "[*] Removing compiled YANG tree files..."
    find "$YANG_DIR" -type f -name "*.tree" -delete
    echo "  -> Cleaned ${YANG_DIR}/"
fi

# 5. Clean Canonical Juju and Charmcraft build artifacts (UPDATED)
echo "[*] Removing local Charmcraft and Juju build artifacts..."
rm -rf .charmcraft/ charm/.charmcraft/ charm/build/ *.charm charm/*.charm

# 6. Clean Python cache files recursively
echo "[*] Removing Python cache directories and bytecode..."
find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find . -type f -name "*.py[cod]" -delete 2>/dev/null || true

# 7. Revoke Execution Permissions from scripts and tests
echo "[*] Removing execution permissions from scripts and tests..."
chmod -x scripts/*.py 2>/dev/null || true
chmod -x scripts/*.sh 2>/dev/null || true
chmod -x tests/*.sh 2>/dev/null || true

echo "=================================================================="
echo "[+] Uninstall complete! Local workspace and infrastructure returned to clean state."
echo "=================================================================="
