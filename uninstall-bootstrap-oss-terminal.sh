#!/usr/bin/env bash
# uninstall-bootstrap-oss-terminal.sh
# Reverses the environment setup for QuantumServiceOperationSDNarchitecture

set -eo pipefail

echo "=================================================================="
echo "  Uninstalling QuantumServiceOperationSDNarchitecture Environment"
echo "=================================================================="

# 1. Deactivate virtual environment if it is currently active
if [ -n "$VIRTUAL_ENV" ]; then
    echo "[*] Active virtual environment detected. Deactivating..."
    # Deactivate is a shell function, so we suppress errors if it fails in a subshell
    deactivate 2>/dev/null || true 
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
GRPC_OUT_DIR="src/api/grpc"
if [ -d "$GRPC_OUT_DIR" ]; then
    echo "[*] Removing compiled Python gRPC stubs..."
    # Deletes all generated _pb2.py and _pb2_grpc.py files but leaves the directory structure
    find "$GRPC_OUT_DIR" -type f -name "*_pb2*.py" -delete
    echo "  -> Cleaned ${GRPC_OUT_DIR}/"
fi

# 4. Clean compiled YANG tree files
YANG_DIR="src/api/yang"
if [ -d "$YANG_DIR" ]; then
    echo "[*] Removing compiled YANG tree files..."
    find "$YANG_DIR" -type f -name "*.tree" -delete
    echo "  -> Cleaned ${YANG_DIR}/"
fi

# 5. Clean Python cache files recursively
echo "[*] Removing Python cache directories and bytecode..."
find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find . -type f -name "*.py[cod]" -delete 2>/dev/null || true

echo "=================================================================="
echo "[+] Uninstall complete! The repository is back to a clean state."
echo "=================================================================="
