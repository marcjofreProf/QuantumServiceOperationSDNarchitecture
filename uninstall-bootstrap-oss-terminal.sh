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

echo "[*] Removing Juju controller LXD containers..."

# Delete the primary controller container plus any orphans that a
# partial bootstrap may have left behind. Any container starting with
# "juju-" belongs to Juju.
removed_any=false
while read -r name; do
    [ -z "$name" ] && continue
    echo "  -> Removing container: $name"
    sudo lxc config set "$name" boot.autostart false 2>/dev/null || true
    sudo lxc stop   "$name" --force 2>/dev/null || true
    sudo lxc delete "$name" --force 2>/dev/null || true
    removed_any=true
done < <(sudo lxc list --format csv 2>/dev/null | awk -F, '$1 ~ /^juju-/ {print $1}')

if [ "$removed_any" = true ]; then
    echo "  -> Juju LXD containers removed."
else
    echo "  -> No Juju LXD containers found. Skipping."
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
#
# `lxc config trust remove juju` fails on some LXD versions with
# "Certificate not found" — the name field is display-only and the CLI
# resolves removals by fingerprint. Read the fingerprint from the CSV
# output and remove by that.
# ------------------------------------------------------------------------------

echo "[*] Removing Juju LXD trust..."

while read -r fp; do
    [ -n "$fp" ] && sudo lxc config trust remove "$fp" 2>/dev/null || true
done < <(sudo lxc config trust list --format csv 2>/dev/null | awk -F, '$2=="juju" {print $4}')


# ------------------------------------------------------------------------------
# 6. Remove local Juju state and bootstrap artifacts
# ------------------------------------------------------------------------------

echo "[*] Removing local Juju state and bootstrap artifacts..."

rm -rf ~/.local/share/juju
rm -rf ~/.config/juju
rm -rf ~/.cache/juju

# Remove the dedicated SSH key created by the bootstrap for the local
# Juju connection, and its public companion.
rm -f ~/.ssh/juju_bootstrap_ed25519
rm -f ~/.ssh/juju_bootstrap_ed25519.pub

# Remove the corresponding block from ~/.ssh/config so a future bootstrap
# starts from a clean file.
if [ -f ~/.ssh/config ]; then
    # Delete the block that starts with "Host 127.0.0.1" and continues
    # until the next blank line or end of file.
    sed -i '/^Host 127\.0\.0\.1$/,/^$/d' ~/.ssh/config 2>/dev/null || true
fi

echo "  -> Local Juju state, SSH key, and SSH config block removed."

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
# 8b. Remove residual Juju cloud registration and bootstrap files
# ------------------------------------------------------------------------------

echo "[*] Removing residual Juju cloud registration and files..."

if command -v juju >/dev/null 2>&1; then
    # The bootstrap used to register a "terminal-local" manual cloud.
    # Newer versions use the built-in "localhost" LXD cloud instead, but
    # a stale "terminal-local" registration from an older run should go.
    juju remove-cloud terminal-local --client 2>/dev/null || true

    # Remove any stored credentials for the localhost LXD cloud. These
    # are what made `juju bootstrap` fail with "credentials not found"
    # after the trust store was manually cleaned.
    juju remove-credential localhost juju 2>/dev/null || true
fi

# Remove the temporary cloud definition file used by the old manual
# provider path.
rm -f ./terminal-local-cloud.yaml 2>/dev/null || true

echo "  -> Residual Juju cloud state removed."

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

# Remove the downloaded OpenConfig gNMI proto sources and the nested
# extension tree that the bootstrap fetched for stub generation.
# The tracked proto/ directory (if any) is left alone except for these
# specific downloaded artifacts.
echo "[*] Removing downloaded OpenConfig gNMI proto sources..."
rm -f  "proto/gnmi.proto"            2>/dev/null || true
rm -f  "proto/gnmi_ext.proto"        2>/dev/null || true
rm -rf "proto/github.com"            2>/dev/null || true
rm -rf "proto/github"                2>/dev/null || true
rm -f  "proto/__init__.py"           2>/dev/null || true

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

echo "[*] Verifying Juju cleanup..."

remaining_containers=$(sudo lxc list --format csv 2>/dev/null \
    | awk -F, '$1 ~ /^juju-/ {print $1}' | wc -l)
if [ "$remaining_containers" -gt 0 ]; then
    echo "[!] WARNING: $remaining_containers Juju container(s) still present:"
    sudo lxc list --format csv 2>/dev/null | awk -F, '$1 ~ /^juju-/ {print "    " $1}'
else
    echo "  -> All Juju containers removed."
fi

remaining_trust=$(sudo lxc config trust list --format csv 2>/dev/null \
    | awk -F, '$2=="juju"' | wc -l)
if [ "$remaining_trust" -gt 0 ]; then
    echo "[!] WARNING: stale 'juju' trust entry still present in LXD."
else
    echo "  -> No stale Juju trust entries in LXD."
fi

if sudo lxc profile show "$CONTROLLER_PROFILE" >/dev/null 2>&1; then
    echo "[!] WARNING: Controller profile still exists: $CONTROLLER_PROFILE"
else
    echo "  -> Controller profile removed."
fi

# ------------------------------------------------------------------------------
# 15. Remove shared deployment configuration
#
# The bootstrap writes CONTROLLER_HOST / QUANTUM_NODE_ID / QUANTUM_NODE_IP to
# ~/.quantum-sdn/config.env. The same file is used by the controller and node
# bootstraps, so its removal is guarded by an env var: only delete it when the
# user explicitly asks, to avoid surprising a machine that also runs one of
# the other repositories.
#
# To remove it:
#   REMOVE_QUANTUM_SDN_CONF=yes ./uninstall-bootstrap-oss-terminal.sh
# ------------------------------------------------------------------------------

if [ "${REMOVE_QUANTUM_SDN_CONF:-no}" = "yes" ]; then
    if [ -d "${HOME}/.quantum-sdn" ]; then
        echo "[*] Removing shared deployment config..."
        rm -rf "${HOME}/.quantum-sdn"
        echo "  -> ${HOME}/.quantum-sdn removed."
    else
        echo "[*] Shared deployment config not present. Skipping."
    fi
else
    echo "[*] Shared deployment config preserved. Set REMOVE_QUANTUM_SDN_CONF=yes to remove it."
fi

echo "=================================================================="
echo "[+] Uninstall complete!"
echo "[+] Juju controller and its LXD resources removed."
echo "[+] LXD itself was NOT removed."
echo "=================================================================="
