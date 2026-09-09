#!/usr/bin/env bash
# ./uninstall-bootstrap-oss-terminal.sh
# Reverses the environment setup for QuantumServiceOperationSDNarchitecture

set -eo pipefail

echo "=================================================================="
echo "  Uninstalling QuantumServiceOperationSDNarchitecture Environment"
echo "=================================================================="

CONTROLLER_NAME="terminal-controller"
CONTROLLER_VM="juju-${CONTROLLER_NAME}-0"
VENV_DIR=".venv"

# Ensure mount propagation and clear stale snap namespaces before running Juju
sudo mount --make-rshared / 2>/dev/null || true
if command -v juju &>/dev/null && ! juju version &>/dev/null; then
    sudo umount -l /run/snapd/ns/juju.mnt 2>/dev/null || true
    sudo /usr/lib/snapd/snap-discard-ns juju 2>/dev/null || true
    sudo rm -rf /run/snapd/ns/juju* 2>/dev/null || true
    sudo systemctl restart apparmor snapd 2>/dev/null || true
    sleep 2
fi

# ------------------------------------------------------------------------------
# 1. Stop and remove RESTCONF systemd service
# ------------------------------------------------------------------------------

echo "[*] Tearing down RESTCONF systemd service..."

if systemctl list-unit-files 2>/dev/null | grep -q '^quantum-restconf.service'; then

    sudo systemctl stop quantum-restconf.service 2>/dev/null || true
    sudo systemctl disable quantum-restconf.service 2>/dev/null || true

    sudo rm -f /etc/systemd/system/quantum-restconf.service
    sudo rm -f /usr/local/bin/quantum_restconf_server.py

    sudo systemctl daemon-reload

    echo "  -> Service quantum-restconf.service stopped and removed."

else
    echo "  -> Service quantum-restconf.service not found. Skipping."
fi

# ------------------------------------------------------------------------------
# 2. Destroy Juju controller and models
# ------------------------------------------------------------------------------

echo "[*] Tearing down Juju controller and models..."

if command -v juju >/dev/null 2>&1; then

    if juju controllers 2>/dev/null | grep -q "$CONTROLLER_NAME"; then

        echo "  -> Destroying Juju controller '$CONTROLLER_NAME'..."

        juju destroy-controller "$CONTROLLER_NAME" \
            --destroy-all-models \
            --force \
            --yes 2>/dev/null || true

        juju unregister "$CONTROLLER_NAME" 2>/dev/null || true

        echo "  -> Juju controller destroyed."

    else
        echo "  -> Juju controller '$CONTROLLER_NAME' not registered."
    fi

else
    echo "  -> Juju not installed. Skipping Juju cleanup."
fi

# ------------------------------------------------------------------------------
# 3. Remove persistent Juju controller VM
#
# The bootstrap configures the controller VM with:
#
#     boot.autostart=true
#
# Explicitly remove it during uninstall.
# ------------------------------------------------------------------------------

echo "[*] Removing Juju controller LXD VM..."

if sudo lxc info "$CONTROLLER_VM" >/dev/null 2>&1; then

    echo "  -> Found controller VM: $CONTROLLER_VM"

    sudo lxc config set "$CONTROLLER_VM" \
        boot.autostart false 2>/dev/null || true

    sudo lxc stop "$CONTROLLER_VM" \
        --force 2>/dev/null || true

    sudo lxc delete "$CONTROLLER_VM" \
        --force 2>/dev/null || true

    echo "  -> Controller VM removed."

else
    echo "  -> Controller VM '$CONTROLLER_VM' not found. Skipping."
fi

# ------------------------------------------------------------------------------
# 4. Remove Juju-generated LXD profile
# ------------------------------------------------------------------------------

echo "[*] Removing Juju LXD profile..."

CONTROLLER_PROFILE="juju-${CONTROLLER_NAME}"

if sudo lxc profile show "$CONTROLLER_PROFILE" >/dev/null 2>&1; then

    sudo lxc profile delete "$CONTROLLER_PROFILE" 2>/dev/null || true

    echo "  -> Removed LXD profile '$CONTROLLER_PROFILE'."

else
    echo "  -> LXD profile '$CONTROLLER_PROFILE' not found. Skipping."
fi

# ------------------------------------------------------------------------------
# 5. Remove Juju LXD trust
# ------------------------------------------------------------------------------

echo "[*] Removing Juju LXD trust..."

sudo lxc config trust remove juju 2>/dev/null || true
lxc config trust remove juju 2>/dev/null || true

# ------------------------------------------------------------------------------
# 6. Remove local Juju state
# ------------------------------------------------------------------------------

echo "[*] Removing local Juju state..."

rm -rf ~/.local/share/juju
rm -rf ~/.config/juju

echo "  -> Local Juju state removed."

# ------------------------------------------------------------------------------
# 7. Remove LXD group/session customization
# ------------------------------------------------------------------------------

echo "[*] Removing LXD group/session customization..."

sed -i \
    '/^# Auto-elevate LXD group for Juju\/Charmcraft in WSL$/d' \
    ~/.bashrc 2>/dev/null || true

sed -i \
    '/^if ! id -nG | grep -qw '\''lxd'\'' && grep -q '\''^lxd:.*:$USER'\'' \/etc\/group; then exec sudo -E -u "\$USER" -g lxd "\$SHELL"; fi$/d' \
    ~/.bashrc 2>/dev/null || true

if getent group lxd >/dev/null 2>&1 &&
   id -nG "$USER" | grep -qw "lxd"; then

    sudo gpasswd -d "$USER" lxd 2>/dev/null || true

    echo "  -> Removed $USER from the lxd group."

else
    echo "  -> $USER is not a member of the lxd group."
fi

# ------------------------------------------------------------------------------
# 8. Remove custom sysctl/module configuration
# ------------------------------------------------------------------------------

echo "[*] Reverting custom sysctl and network module configuration..."

sudo rm -f /etc/sysctl.d/99-sdn-uonos.conf
sudo rm -f /etc/modules-load.d/sdn-uonos.conf

sudo sysctl --system >/dev/null 2>&1 || true

echo "  -> Custom system configuration removed."

# ------------------------------------------------------------------------------
# 9. Remove Python virtual environment
# ------------------------------------------------------------------------------

if [ -d "$VENV_DIR" ]; then

    echo "[*] Removing Python virtual environment..."

    rm -rf "$VENV_DIR"

    echo "  -> Removed $VENV_DIR/"

else
    echo "[*] Python virtual environment not found. Skipping."
fi

# ------------------------------------------------------------------------------
# 10. Clean generated gRPC / Protobuf files
# ------------------------------------------------------------------------------

for STUB_DIR in \
    "src/api/proto" \
    "src/api/grpc" \
    "proto" \
    "hardware-agents/restconf-servers" \
    "hardware-agents/gnoi-targets"
do

    if [ -d "$STUB_DIR" ]; then

        echo "[*] Cleaning generated files in $STUB_DIR..."

        find "$STUB_DIR" \
            -type f \
            \( \
                -name "*_pb2.py" \
                -o -name "*_pb2_grpc.py" \
                -o -name "mock_*.py" \
            \) \
            -delete

    fi

done

# ------------------------------------------------------------------------------
# 11. Clean compiled YANG tree files
# ------------------------------------------------------------------------------

YANG_DIR="src/api/yang"

if [ -d "$YANG_DIR" ]; then

    echo "[*] Removing compiled YANG tree files..."

    find "$YANG_DIR" \
        -type f \
        -name "*.tree" \
        -delete

fi

# ------------------------------------------------------------------------------
# 12. Clean Charmcraft/Juju build artifacts
# ------------------------------------------------------------------------------

echo "[*] Removing Charmcraft/Juju build artifacts..."

rm -rf .charmcraft/
rm -rf charm/.charmcraft/
rm -rf charm/build/

rm -f *.charm
rm -f charm/*.charm

# ------------------------------------------------------------------------------
# 13. Clean Python cache files
# ------------------------------------------------------------------------------

echo "[*] Removing Python cache files..."

find . \
    -type d \
    -name "__pycache__" \
    -exec rm -rf {} + \
    2>/dev/null || true

find . \
    -type f \
    -name "*.py[cod]" \
    -delete \
    2>/dev/null || true

# ------------------------------------------------------------------------------
# 14. Final verification
# ------------------------------------------------------------------------------

echo "[*] Verifying Juju controller removal..."

if sudo lxc info "$CONTROLLER_VM" >/dev/null 2>&1; then
    echo "[!] WARNING: Controller VM still exists: $CONTROLLER_VM"
else
    echo "  -> Controller VM removed."
fi

if sudo lxc profile show "$CONTROLLER_PROFILE" >/dev/null 2>&1; then
    echo "[!] WARNING: Controller profile still exists: $CONTROLLER_PROFILE"
else
    echo "  -> Controller profile removed."
fi

echo "=================================================================="
echo "[+] Uninstall complete!"
echo "[+] Juju controller and its LXD resources removed."
echo "[+] LXD itself was NOT removed."
echo "=================================================================="
