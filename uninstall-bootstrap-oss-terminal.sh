#!/usr/bin/env bash
# uninstall-bootstrap-oss-terminal.sh
# Reverses the environment setup for QuantumServiceOperationSDNarchitecture

set -eo pipefail

echo "=================================================================="
echo "  Uninstalling QuantumServiceOperationSDNarchitecture Environment"
echo "=================================================================="

# 1. Stop and remove persistent RESTCONF systemd service
echo "[*] Tearing down RESTCONF systemd service..."
if systemctl list-unit-files | grep -q quantum-restconf.service; then
    sudo systemctl stop quantum-restconf.service 2>/dev/null || true
    sudo systemctl disable quantum-restconf.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/quantum-restconf.service
    sudo rm -f /usr/local/bin/quantum_restconf_server.py
    sudo systemctl daemon-reload
    echo "  -> Service quantum-restconf.service stopped and removed."
else
    echo "  -> Service quantum-restconf.service not found. Skipping."
fi

# 2. Destroy Juju Controller and Models
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

# 3. Clean kernel network and sysctl configurations
echo "[*] Reverting custom sysctl and network module configurations..."
sudo rm -f /etc/sysctl.d/99-sdn-uonos.conf
sudo rm -f /etc/modules-load.d/sdn-uonos.conf
echo "  -> Removed sysctl and modules auto-load configs."

# 4. Remove isolated virtual environment
VENV_DIR=".venv"
if [ -d "$VENV_DIR" ]; then
    echo "[*] Removing Python virtual environment (${VENV_DIR})..."
    rm -rf "$VENV_DIR"
    echo "  -> Removed ${VENV_DIR}/"
else
    echo "[*] Virtual environment (${VENV_DIR}) not found. Skipping."
fi

# 5. Clean generated gRPC / Protobuf stubs and mock scripts
for STUB_DIR in "src/api/proto" "src/api/grpc" "proto" "hardware-agents/restconf-servers" "hardware-agents/gnoi-targets"; do
    if [ -d "$STUB_DIR" ]; then
        echo "[*] Removing generated stubs and mock servers in ${STUB_DIR}..."
        find "$STUB_DIR" -type f \( -name "*_pb2.py" -o -name "*_pb2_grpc.py" -o -name "mock_*.py" \) -delete
        echo "  -> Cleaned ${STUB_DIR}/"
    fi
done

# 6. Clean compiled YANG tree files
YANG_DIR="src/api/yang"
if [ -d "$YANG_DIR" ]; then
    echo "[*] Removing compiled YANG tree files..."
    find "$YANG_DIR" -type f -name "*.tree" -delete
    echo "  -> Cleaned ${YANG_DIR}/"
fi

# 7. Clean Canonical Juju and Charmcraft build artifacts
echo "[*] Removing local Charmcraft and Juju build artifacts..."
rm -rf .charmcraft/ charm/.charmcraft/ charm/build/ *.charm charm/*.charm

# 8. Clean Python cache files recursively
echo "[*] Removing Python cache directories and bytecode..."
find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find . -type f -name "*.py[cod]" -delete 2>/dev/null || true

# 9. Revoke Execution Permissions from scripts and tests
echo "[*] Removing execution permissions from scripts and tests..."
chmod -x scripts/*.py 2>/dev/null || true
chmod -x scripts/*.sh 2>/dev/null || true
chmod -x tests/*.sh 2>/dev/null || true

echo "=================================================================="
echo "[+] Uninstall complete! Local workspace and infrastructure returned to clean state."
echo "=================================================================="
