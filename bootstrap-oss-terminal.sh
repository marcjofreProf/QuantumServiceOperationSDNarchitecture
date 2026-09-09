#!/usr/bin/env bash
# ./bootstrap-oss-terminal.sh
# Environment setup for QuantumServiceOperationSDNarchitecture

set -eo pipefail

echo "=================================================================="
echo "  Bootstrapping QuantumServiceOperationSDNarchitecture Environment"
echo "=================================================================="

# 0. WSL Systemd Verification, Runtime Directory Permissions & DBus
if grep -qi microsoft /proc/version 2>/dev/null || [ -n "$WSL_DISTRO_NAME" ]; then
    echo "[*] Checking WSL systemd configuration..."
    
    WSL_CONF_MODIFIED=false
    
    if ! grep -iq "systemd=true" /etc/wsl.conf 2>/dev/null; then
        echo "[!] systemd is not enabled in /etc/wsl.conf. Auto-configuring now..."
        if ! grep -q "\[boot\]" /etc/wsl.conf 2>/dev/null; then
            echo -e "\n[boot]\nsystemd=true" | sudo tee -a /etc/wsl.conf >/dev/null
        else
            sudo sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
        fi
        WSL_CONF_MODIFIED=true
    fi

    # Check if systemd is actively running as PID 1
    if [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
        echo "=================================================================="
        if [ "$WSL_CONF_MODIFIED" = true ]; then
            echo "[!] CRITICAL: /etc/wsl.conf has been updated to enable systemd."
        else
            echo "[!] CRITICAL: systemd is present in /etc/wsl.conf but NOT active."
        fi
        echo "[!] WSL must be fully restarted from Windows for changes to take effect."
        echo ""
        echo "  Please perform the following steps now:"
        echo "    1. Close this WSL terminal."
        echo "    2. Open Windows PowerShell or Command Prompt."
        echo "    3. Run:  wsl.exe --shutdown"
        echo "    4. Re-open your WSL terminal and rerun this bootstrap script."
        echo "=================================================================="
        exit 1
    else
        echo "  -> systemd is active and running as PID 1."
    fi

    # Ensure root mount propagation is shared for Snap containers in WSL2
    sudo mount --make-rshared / 2>/dev/null || true
    
    # Proactively test and heal Snap mount namespace locks (juju.mnt)
    if command -v juju &>/dev/null; then
        if ! juju version &>/dev/null; then
            echo "[!] Stale Snap mount namespace detected. Self-healing Juju runtime..."
            sudo umount -l /run/snapd/ns/juju.mnt 2>/dev/null || true
            sudo /usr/lib/snapd/snap-discard-ns juju 2>/dev/null || true
            sudo rm -rf /run/snapd/ns/juju* 2>/dev/null || true
            sudo systemctl restart apparmor snapd
            sleep 2
        fi
    fi
fi

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

echo "[*] Verifying system dependencies..."
SYSTEM_DEPS=("libffi-dev" "libyaml-dev" "python3-dev" "python3-setuptools" "python3-wheel" "passwd" "iptables" "apparmor" "apparmor-utils" "util-linux-extra" "openssh-server" "openssh-client")

if ! python3 -c "import ensurepip" &>/dev/null; then
    SYSTEM_DEPS+=("python3-venv")
fi

if ! command -v pip3 &>/dev/null; then
    SYSTEM_DEPS+=("python3-pip")
fi

MISSING_DEPS=()
for pkg in "${SYSTEM_DEPS[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
        MISSING_DEPS+=("$pkg")
    fi
done

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "[!] Missing system packages: ${MISSING_DEPS[*]}"
    echo "[*] Installing missing system packages via apt..."
    sudo apt-get update -y
    sudo apt-get install -y "${MISSING_DEPS[@]}"
else
    echo "  -> All required system dependencies are already installed."
fi

# Ensure AppArmor daemon is running on host
sudo systemctl enable --now apparmor 2>/dev/null || true

# 1b. LXD Group Verification & Session Elevation
echo "[*] Verifying LXD installation and group permissions..."
if ! command -v lxd &>/dev/null; then
    echo "  -> Installing LXD via snap..."
    sudo snap install lxd --channel=latest/stable 2>/dev/null || true
fi

if ! id -nG "$USER" | grep -qw "lxd"; then
    echo "  -> Adding $USER to the lxd group..."
    sudo usermod -aG lxd "$USER"
fi

# Elevate current script execution context to include effective group 'lxd'
if ! id -nG | grep -qw "lxd"; then
    echo "  -> Elevating LXD group session and restarting bootstrap process..."
    exec sudo -E -u "$USER" -g lxd stdbuf -oL -eL bash "$0" "$@"
fi

sudo lxd init --auto 2>/dev/null || true

# 2. Local SSH Check for Juju Unmanaged Controller
echo "[*] Verifying local SSH environment..."

if ! command -v sshd &>/dev/null; then
    echo "[!] OpenSSH server is missing."
    echo "    It should have been installed with the system dependencies."
    exit 1
fi

echo "  -> Ensuring SSH daemon is enabled and running..."
sudo systemctl enable --now ssh 2>/dev/null || sudo systemctl enable --now sshd 2>/dev/null || {
    echo "[!] Failed to start the SSH daemon."
    exit 1
}

# Juju controller is bootstrapped directly on the WSL host using the
# unmanaged/manual provider. No LXD or nested virtualization is required.
JUJU_SSH_KEY="$HOME/.ssh/juju_bootstrap_ed25519"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ ! -f "$JUJU_SSH_KEY" ]; then
    echo "  -> Creating a dedicated SSH key for the local Juju bootstrap..."
    ssh-keygen -q -t ed25519 -N "" -f "$JUJU_SSH_KEY"
fi

touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

if ! grep -Fqx "$(cat "${JUJU_SSH_KEY}.pub")" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
    echo "  -> Authorizing the Juju bootstrap SSH key..."
    cat "${JUJU_SSH_KEY}.pub" >> "$HOME/.ssh/authorized_keys"
fi

echo "  -> Configuring SSH for the local Juju bootstrap..."

touch "$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"

if ! grep -q "^Host 127\.0\.0\.1$" "$HOME/.ssh/config"; then
    cat >> "$HOME/.ssh/config" <<EOF

Host 127.0.0.1
    User $USER
    IdentityFile $JUJU_SSH_KEY
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ControlMaster no
EOF
fi

echo "  -> Testing local SSH connectivity for Juju..."

if ! ssh -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes \
        -o ControlMaster=no \
        -i "$JUJU_SSH_KEY" \
        "$USER@127.0.0.1" true >/dev/null 2>&1; then
    echo "[!] Local SSH connectivity test failed."
    echo "    Juju requires SSH access to the WSL host for the unmanaged controller."
    exit 1
fi

echo "  -> Local SSH connectivity is working."
echo "  -> SSH key configured for Juju: $JUJU_SSH_KEY"

# 3. Canonical Juju & Charmcraft Tooling Check / Auto-Install
echo "[*] Verifying Canonical Juju tooling..."

if ! command -v juju &>/dev/null; then
    echo "[!] Juju CLI not found. Installing via snap..."
    
    if ! command -v snap &>/dev/null; then
        echo "[!] Snap package manager not found."
        exit 1
    fi

    sudo systemctl restart snapd
    sleep 3
    
    if ! sudo snap install juju --channel=3/stable; then
        echo "[!] Failed to install Juju via snap."
        exit 1
    fi
fi

echo "  -> Juju CLI: $(juju --version | awk '{print $1}')"

if ! command -v charmcraft &>/dev/null; then
    echo "[!] Charmcraft not found. Installing via snap..."
    if command -v snap &>/dev/null; then
        sudo snap install charmcraft --classic
    fi
else
    echo "  -> Charmcraft is installed: $(charmcraft --version | awk '{print $1}')"
fi

# 4. Juju Controller & Model Provisioning
echo "[*] Verifying Juju Controller..."
CONTROLLER_NAME="terminal-controller"

# Run the Juju controller directly on the WSL host using Juju's
# unmanaged/manual provider rather than an LXD container or VM.
JUJU_BOOTSTRAP_BASE="ubuntu@24.04"
CLOUD_NAME="terminal-local"

echo "  -> Juju controller bootstrap mode: local WSL host"

# Juju's unmanaged/manual provider connects to an existing machine over SSH.
# Define the WSL host itself as the bootstrap endpoint.
JUJU_CLOUD_FILE="./terminal-local-cloud.yaml"

cat > "$JUJU_CLOUD_FILE" <<EOF
clouds:
  ${CLOUD_NAME}:
    type: manual
    endpoint: ${USER}@127.0.0.1
    regions:
      default: {}
EOF

if juju show-cloud "$CLOUD_NAME" --client &>/dev/null; then
    echo "  -> Local Juju cloud '$CLOUD_NAME' is already registered."
else
    echo "  -> Registering local unmanaged Juju cloud..."
    juju add-cloud "$CLOUD_NAME" --file "$JUJU_CLOUD_FILE" --client || {
        echo "[!] Failed to register the local Juju cloud."
        exit 1
    }
    echo "  -> Local Juju cloud '$CLOUD_NAME' registered successfully."
fi

wait_for_juju_controller() {
    local attempts="${1:-30}"
    local i
    for i in $(seq 1 "$attempts"); do
        if timeout 5s juju switch "$CONTROLLER_NAME" &>/dev/null; then
            return 0
        fi
        echo "     [Waiting for Juju controller API... ($i/$attempts)]"
        sleep 2
    done
    return 1
}

if juju controllers 2>/dev/null | grep -q "$CONTROLLER_NAME"; then
    echo "  -> Found local registration for '$CONTROLLER_NAME'."

    if wait_for_juju_controller 30; then
        echo "  -> Juju controller '$CONTROLLER_NAME' is active and reachable."
    else
        echo "[!] Juju controller '$CONTROLLER_NAME' is still unreachable after waiting."
        echo "    The existing controller has NOT been deleted or re-bootstrapped."
        echo "    Check with: juju status"
        echo "              juju debug-log"
        exit 1
    fi
else
    echo "[!] '$CONTROLLER_NAME' is not registered locally."

    echo "  -> No registered controller found; preparing local Juju bootstrap..."
    juju clouds --client --format yaml
    echo "  -> Bootstrapping local controller on WSL host..."
    echo "     Cloud:      $CLOUD_NAME"
    echo "     Controller: $CONTROLLER_NAME"
    echo "     Host:       127.0.0.1"
    echo "     User:       $USER"
    echo "     SSH key:    $JUJU_SSH_KEY"
    echo
    juju bootstrap --bootstrap-base="$JUJU_BOOTSTRAP_BASE" --bootstrap-constraints="$JUJU_BOOTSTRAP_CONSTRAINTS" localhost "$CONTROLLER_NAME" || {
        echo "[!] Failed to bootstrap Juju controller."
        exit 1
    }
    echo "  -> Juju bootstrap completed successfully."
fi

# The Juju controller runs directly on the WSL host. Its Juju services are
# managed by systemd and therefore follow the WSL systemd lifecycle.
echo "[*] Verifying Juju controller container..."
if ! lxc list 2>/dev/null | grep -q "juju-"; then
    echo "[!] Juju controller LXD container could not be found."
    exit 1
fi

# Check for and switch to the target model
echo "[*] Verifying Juju Model..."
if ! timeout 5s juju switch "${CONTROLLER_NAME}:terminal-model" &>/dev/null; then
    echo "  -> Creating 'terminal-model'..."
    juju add-model terminal-model -c "$CONTROLLER_NAME" || {
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
  ./src/api/proto/terminal_quantum_gnoi_switching.proto 2>/dev/null || true

# =============================================================================
# 11. Final Persistence / Reboot Safety Verification
# =============================================================================
echo "[*] Verifying reboot/power-cycle persistence..."

# The Juju controller runs directly on the WSL host. Verify that systemd is
# active and that Juju controller services are present.
SYSTEMD_ACTIVE=false
if [ "$(ps -p 1 -o comm=)" = "systemd" ]; then
    SYSTEMD_ACTIVE=true
fi

JUJU_SERVICE_FOUND=false
if lxc list 2>/dev/null | grep -q "juju-"; then
    JUJU_SERVICE_FOUND=true
fi

echo "  -> WSL systemd active: $SYSTEMD_ACTIVE"
echo "  -> Juju controller service found: $JUJU_SERVICE_FOUND"
echo "  -> Juju controller: $CONTROLLER_NAME"

echo "=================================================================="
echo "[+] Bootstrap complete! System and local environment ready."
echo "[+] Optional Juju tests available in ./tests/"
echo -e "To view your pods and juju services, run:"
echo -e "  juju status --watch 5s"
echo "=================================================================="
