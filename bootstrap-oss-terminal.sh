#!/usr/bin/env bash
# bootstrap-oss-terminal.sh
# Environment setup for QuantumServiceOperationSDNarchitecture

set -eo pipefail

echo "=================================================================="
echo "  Bootstrapping QuantumServiceOperationSDNarchitecture Environment"
echo "=================================================================="

# 0. Fix WSL Runtime Directory Permissions & DBus
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    sudo mkdir -p "$XDG_RUNTIME_DIR"
    sudo chown "$(id -u):$(id -g)" "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
fi

if [ ! -S "$XDG_RUNTIME_DIR/bus" ]; then
    echo "  -> Initializing DBus session to prevent Snap/Juju timeouts..."
    sudo apt-get update -yqq
    sudo apt-get install -yqq dbus-user-session
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    dbus-daemon --session --address="$DBUS_SESSION_BUS_ADDRESS" --fork 2>/dev/null || true
fi

# 1. System Dependency Checks, Time Sync & Fixes
echo "[*] Synchronizing system time (OS clock drift fix)..."
if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null; then
    sudo systemctl restart systemd-timesyncd || true
else
    sudo apt-get update -yqq
    sudo apt-get install -yqq ntpdate
    sudo ntpdate pool.ntp.org 2>/dev/null || true
fi

echo "[*] Verifying system dependencies..."
SYSTEM_DEPS=()

if ! python3 -c "import ensurepip" &>/dev/null; then
    SYSTEM_DEPS+=("python3-venv")
fi

if ! command -v pip3 &>/dev/null; then
    SYSTEM_DEPS+=("python3-pip")
fi

if [ ${#SYSTEM_DEPS[@]} -ne 0 ]; then
    echo "[!] Missing system packages: ${SYSTEM_DEPS[*]}"
    echo "[*] Installing missing system packages via apt..."
    sudo apt-get update -y
    sudo apt-get install -y "${SYSTEM_DEPS[@]}"
fi

# 2. Canonical Juju & Charmcraft Tooling Check / Auto-Install
echo "[*] Verifying Canonical Juju tooling..."
if ! command -v juju &>/dev/null; then
    echo "[!] Juju CLI not found. Installing via snap..."
    if command -v snap &>/dev/null; then
        sudo snap install juju --classic --channel=3/stable
    else
        echo "[!] Snap package manager not found. Please install Juju manually."
    fi
else
    echo "  -> Juju CLI is installed: $(juju --version | awk '{print $1}')"
fi

if ! command -v charmcraft &>/dev/null; then
    echo "[!] Charmcraft not found. Installing via snap..."
    if command -v snap &>/dev/null; then
        sudo snap install charmcraft --classic
    fi
else
    echo "  -> Charmcraft is installed: $(charmcraft --version | awk '{print $1}')"
fi

# 3. LXD Group Check & Session Elevation
echo "[*] Verifying LXD environment & permissions..."
if ! command -v lxd &>/dev/null; then
    echo "  -> LXD is missing. Installing via snap..."
    sudo snap install lxd
fi

if ! id -nG "$USER" | grep -qw "lxd"; then
    echo "  -> Adding $USER to the lxd group..."
    sudo usermod -aG lxd "$USER"
fi

if [ "$(id -gn)" != "lxd" ] && ! id -nG | grep -qw "lxd"; then
    echo "  -> Elevating LXD group session and restarting bootstrap process..."
    exec sg lxd -c "$0 $*"
fi

sudo lxd init --auto || true

# Auto-fix IPv6 routing issues conditionally to avoid unnecessary daemon restarts
echo "  -> Checking LXD bridge network (lxdbr0) configuration..."
LXD_RESTART_NEEDED=false

if [ "$(sudo lxc network get lxdbr0 ipv6.address 2>/dev/null)" != "none" ]; then
    echo "  -> Disabling IPv6 on lxdbr0..."
    sudo lxc network set lxdbr0 ipv6.address none || true
    LXD_RESTART_NEEDED=true
fi

sudo lxc network set lxdbr0 ipv4.address auto || true
sudo lxc network set lxdbr0 ipv4.nat true || true

# Fix WSL2 LXD internet routing (Docker/WSL firewall conflict)
echo "  -> Applying and saving iptables forwarding fix..."
sudo iptables -P FORWARD ACCEPT || true

if ! dpkg -l | grep -qw iptables-persistent; then
    echo "  -> Installing iptables-persistent to make rules survive reboots..."
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq iptables-persistent
fi
sudo netfilter-persistent save >/dev/null 2>&1 || true

if [ "$LXD_RESTART_NEEDED" = true ]; then
    echo "  -> Network changes applied. Restarting LXD daemon..."
    sudo snap restart lxd || true
fi

# Active wait loop for LXD API to prevent Charmcraft/Juju timeouts
echo "  -> Waiting for LXD API to become fully responsive..."
for i in {1..15}; do
    if timeout 3s lxc info &>/dev/null; then
        echo "  -> LXD daemon is ready."
        break
    fi
    echo "     [LXD API unresponsive, retrying in 2s...] ($i/15)"
    sleep 2
done

# 4. Juju Controller & Model Provisioning
echo "[*] Verifying Juju Controller..."

CONTROLLER_NAME="terminal-controller"

if juju controllers 2>&1 | grep -q "$CONTROLLER_NAME"; then
    echo "  -> Found local registration for '$CONTROLLER_NAME'. Testing API connection..."
    CONTROLLER_REACHABLE=false
    
    for i in {1..10}; do
        if timeout 5s juju switch "$CONTROLLER_NAME" &>/dev/null; then
            CONTROLLER_REACHABLE=true
            echo "  -> Juju controller '$CONTROLLER_NAME' is active and reachable."
            break
        fi
        echo "     [Waiting for controller API to respond... ($i/10)]"
        sleep 3
    done

    if [ "$CONTROLLER_REACHABLE" = false ]; then
        echo "[!] '$CONTROLLER_NAME' API unreachable. Force purging stale controller registration..."
        juju kill-controller "$CONTROLLER_NAME" --yes 2>/dev/null || true
        juju unregister "$CONTROLLER_NAME" 2>/dev/null || true
        
        echo "[!] Re-bootstrapping local controller..."
        juju bootstrap localhost "$CONTROLLER_NAME" || {
            echo "[!] Failed to bootstrap Juju controller."
            exit 1
        }
    fi
else
    echo "[!] '$CONTROLLER_NAME' not registered. Bootstrapping local controller..."
    juju bootstrap localhost "$CONTROLLER_NAME" || {
        echo "[!] Failed to bootstrap Juju controller."
        exit 1
    }
fi

# Check for and switch to the target model
echo "[*] Verifying Juju Model..."
if ! timeout 5s juju switch "${CONTROLLER_NAME}:terminal-model" &>/dev/null; then
    echo "  -> Creating 'terminal-model'..."
    juju add-model terminal-model "$CONTROLLER_NAME" || {
        echo "[!] Failed to create model."
        exit 1
    }
else
    echo "  -> 'terminal-model' is already active and selected."
fi

# 5. Directory Structure Verification
echo "[*] Verifying project structure..."
mkdir -p src/api/proto src/api/yang src/api/grpc src/api/restconf charm scripts config tests

# 6. Virtual Environment Provisioning
VENV_DIR=".venv"
if [ -d "$VENV_DIR" ] && [ ! -f "${VENV_DIR}/bin/pip" ]; then
    echo "[!] Incomplete virtual environment detected. Cleaning up..."
    rm -rf "$VENV_DIR"
fi

if [ ! -d "$VENV_DIR" ]; then
    echo "[*] Creating isolated Python environment in ${VENV_DIR}..."
    python3 -m venv "$VENV_DIR"
else
    echo "[*] Existing environment found in ${VENV_DIR}."
fi

VENV_PYTHON="${VENV_DIR}/bin/python3"
VENV_PIP="${VENV_DIR}/bin/pip"
VENV_PYANG="${VENV_DIR}/bin/pyang"

# 7. Dependency Installation
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

# 8. Compile Protobuf Schemas
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

# 9. Validate YANG Schemas
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

# 10. Apply Execution Permissions & Stubs
echo "[*] Setting execution permissions on scripts..."
chmod +x scripts/*.py 2>/dev/null || true
chmod +x scripts/*.sh 2>/dev/null || true
chmod +x tests/*.sh 2>/dev/null || true

echo "[*] Compiling gRPC stubs..."
./.venv/bin/python3 -m grpc_tools.protoc \
  -I./src/api/proto \
  --python_out=./src/api/proto \
  --grpc_python_out=./src/api/proto \
  ./src/api/proto/terminal_quantum_gnoi_switching.proto

echo "=================================================================="
echo "[+] Bootstrap complete! System and local environment ready."
echo "[+] Optional Juju tests available in ./tests/"
echo "=================================================================="
