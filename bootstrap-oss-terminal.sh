#!/usr/bin/env bash
# bootstrap-oss-terminal.sh
# Environment setup for QuantumServiceOperationSDNarchitecture

set -eo pipefail

# Detect whether script is sourced or executed directly
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    IS_SOURCED=1
else
    IS_SOURCED=0
fi

echo "=================================================================="
echo "  Bootstrapping QuantumServiceOperationSDNarchitecture Environment"
echo "=================================================================="

# 1. System Requirements Verification
echo "[*] Verifying system prerequisites..."
if ! command -v python3 &> /dev/null; then
    echo "[!] Error: python3 is required but not installed." >&2
    exit 1
fi

# 2. Directory Structure Verification
echo "[*] Verifying project directories..."
mkdir -p src/api/proto src/api/yang src/api/grpc src/api/restconf charm scripts config

# 3. Isolated Virtual Environment Setup
VENV_DIR=".venv"
if [ ! -d "$VENV_DIR" ]; then
    echo "[*] Creating dedicated Python virtual environment in ${VENV_DIR}..."
    python3 -m venv "$VENV_DIR"
else
    echo "[*] Existing virtual environment detected in ${VENV_DIR}."
fi

# Define explicit venv binary paths to ensure isolation
VENV_PYTHON="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"
VENV_PYANG="${VENV_DIR}/bin/pyang"

# 4. Dependency Installation inside Virtual Environment
echo "[*] Upgrading pip and installing dependencies into virtual environment..."
"$VENV_PIP" install --upgrade pip setuptools wheel

if [ -f "requirements.txt" ]; then
    echo "[*] Installing dependencies from requirements.txt..."
    "$VENV_PIP" install -r requirements.txt
else
    echo "[*] Installing default SDN, gRPC, YANG, and Juju stack..."
    "$VENV_PIP" install \
        grpcio \
        grpcio-tools \
        pyang \
        gnoi-client \
        onos-api \
        ops \
        fastapi \
        uvicorn \
        pyyaml
fi

# 5. Compile Protobuf Schemas (gRPC) using Virtual Environment Python
PROTO_DIR="src/api/proto"
GRPC_OUT_DIR="src/api/grpc"

echo "[*] Compiling Protobuf definitions..."
touch "src/__init__.py" "src/api/__init__.py" "${GRPC_OUT_DIR}/__init__.py"

if [ -d "$PROTO_DIR" ] && [ -n "$(ls -A "$PROTO_DIR"/*.proto 2>/dev/null)" ]; then
    for proto_file in "$PROTO_DIR"/*.proto; do
        echo "  -> Compiling ${proto_file}..."
        "$VENV_PYTHON" -m grpc_tools.protoc \
            -I"$PROTO_DIR" \
            --python_out="$GRPC_OUT_DIR" \
            --grpc_python_out="$GRPC_OUT_DIR" \
            "$proto_file"
    done
    echo "[+] gRPC stubs generated successfully in ${GRPC_OUT_DIR}/"
else
    echo "[!] No .proto files found in ${PROTO_DIR}/. Skipping gRPC compilation."
fi

# 6. Validate YANG Schemas using Virtual Environment pyang
YANG_DIR="src/api/yang"

echo "[*] Validating YANG data models..."
if [ -d "$YANG_DIR" ] && [ -n "$(ls -A "$YANG_DIR"/*.yang 2>/dev/null)" ]; then
    for yang_file in "$YANG_DIR"/*.yang; do
        echo "  -> Validating ${yang_file}..."
        "$VENV_PYANG" "$yang_file"
        "$VENV_PYANG" -f tree "$yang_file" -o "${yang_file%.yang}.tree"
    done
    echo "[+] YANG models validated. Tree representations saved in ${YANG_DIR}/"
else
    echo "[!] No .yang files found in ${YANG_DIR}/. Skipping YANG validation."
fi

# 7. Set Executable Permissions for Operational Scripts
if [ -d "scripts" ]; then
    chmod +x scripts/*.py 2>/dev/null || true
fi

# 8. Session Activation
echo "=================================================================="
if [ "$IS_SOURCED" -eq 1 ]; then
    source "${VENV_DIR}/bin/activate"
    echo "[+] Environment bootstrap complete!"
    echo "[+] Virtual environment is ACTIVE in your current terminal session."
else
    echo "[+] Environment bootstrap complete!"
    echo "[!] Activate the isolated environment in your current session by running:"
    echo "        source ${VENV_DIR}/bin/activate"
    echo "    (Or run future setups using: source ./bootstrap-oss-terminal.sh)"
fi
echo "=================================================================="
