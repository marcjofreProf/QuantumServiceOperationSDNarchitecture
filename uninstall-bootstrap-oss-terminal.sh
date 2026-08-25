#!/usr/bin/env bash
# uninstall-bootstrap-oss-terminal.sh
# Reverses the environment setup for QuantumServiceOperationSDNarchitecture

set -eo pipefail

echo "=================================================================="
echo "  Uninstalling QuantumServiceOperationSDNarchitecture Environment"
echo "=================================================================="

# 1. Remove isolated virtual environment
VENV_DIR=".venv"
if [ -d "$VENV_DIR" ]; then
    echo "[*] Removing Python virtual environment (${VENV_DIR})..."
    rm -rf "$VENV_DIR"
    echo "  -> Removed ${VENV_DIR}/"
else
    echo "[*] Virtual environment (${VENV_DIR}) not found. Skipping."
fi

# 2. Clean generated gRPC / Protobuf stubs
for STUB_DIR in "src/api/proto" "src/api/grpc"; do
    if [ -d "$STUB_DIR" ]; then
        echo "[*] Removing compiled Python gRPC stubs in ${STUB_DIR}..."
        find "$STUB_DIR" -type f \( -name "*_pb2.py" -o -name "*_pb2_grpc.py" \) -delete
        echo "  -> Cleaned ${STUB_DIR}/"
    fi
done

# 3. Clean compiled YANG tree files
YANG_DIR="src/api/yang"
if [ -d "$YANG_DIR" ]; then
    echo "[*] Removing compiled YANG tree files..."
    find "$YANG_DIR" -type f -name "*.tree" -delete
    echo "  -> Cleaned ${YANG_DIR}/"
fi

# 4. Clean Canonical Juju and Charmcraft build artifacts
echo "[*] Removing local Charmcraft and Juju build artifacts..."
rm -rf .charmcraft/ charm/.charmcraft/ charm/build/ *.charm

# 5. Clean Python cache files recursively
echo "[*] Removing Python cache directories and bytecode..."
find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find . -type f -name "*.py[cod]" -delete 2>/dev/null || true

# 6. Revoke Execution Permissions from scripts and tests
echo "[*] Removing execution permissions from scripts and tests..."
chmod -x scripts/*.py 2>/dev/null || true
chmod -x scripts/*.sh 2>/dev/null || true
chmod -x tests/*.sh 2>/dev/null || true

echo "=================================================================="
echo "[+] Uninstall complete! Local workspace returned to clean state."
echo "=================================================================="
