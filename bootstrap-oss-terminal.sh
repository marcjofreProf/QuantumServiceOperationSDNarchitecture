#!/usr/bin/env bash
# bootstrap-oss-terminal.sh
# Environment setup for QuantumServiceOperationSDNarchitecture

set -eo pipefail

echo "=================================================================="
echo "  Bootstrapping QuantumServiceOperationSDNarchitecture Environment"
echo "=================================================================="

# 1. Directory Structure Verification
echo "[*] Verifying project structure..."
mkdir -p src/api/proto src/api/yang src/api/grpc src/api/restconf charm scripts config

# 2. Virtual Environment Provisioning
VENV_DIR=".venv"
if [ ! -d "$VENV_DIR" ]; then
    echo "[*] Creating isolated Python environment in ${VENV_DIR}..."
    python3 -m venv "$VENV_DIR"
else
    echo "[*] Existing environment found in ${VENV_DIR}."
fi

VENV_PYTHON="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"
VENV_PYANG="${VENV_DIR}/bin/pyang"

# 3. Dependency Installation
echo "[*] Upgrading pip and installing dependencies..."
"$VENV_PIP" install --upgrade pip setuptools wheel

if [ -f "requirements.txt" ]; then
    "$VENV_PIP" install -r requirements.txt
else
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

# 4. Compile Protobuf Schemas
PROTO_DIR="src/api/proto"
GRPC_OUT_DIR="src/api/grpc"

echo "[*] Compiling gRPC definitions..."
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
else
    echo "[!] No .proto files found in ${PROTO_DIR}/. Skipping gRPC compilation."
fi

# 5. Validate YANG Schemas
YANG_DIR="src/api/yang"

echo "[*] Validating YANG models..."
if [ -d "$YANG_DIR" ] && [ -n "$(ls -A "$YANG_DIR"/*.yang 2>/dev/null)" ]; then
    for yang_file in "$YANG_DIR"/*.yang; do
        echo "  -> Validating ${yang_file}..."
        "$VENV_PYANG" "$yang_file"
        "$VENV_PYANG" -f tree "$yang_file" -o "${yang_file%.yang}.tree"
    done
else
    echo "[!] No .yang files found in ${YANG_DIR}/. Skipping YANG validation."
fi

# 6. Apply Execution Permissions
echo "[*] Setting execution permissions on scripts..."
chmod +x scripts/*.py 2>/dev/null || true
chmod +x scripts/*.sh 2>/dev/null || true

echo "=================================================================="
echo "[+] Bootstrap complete! Scripts in ./scripts/ are ready to run."
echo "=================================================================="
