#!/usr/bin/env bash
# tests/test-juju-example-switching-action.sh
# Triggers the RESTCONF cross-connect action via the deployed Juju charm.

set -e

echo "=================================================================="
echo "  Testing Juju Action: create-cross-connect"
echo "=================================================================="

echo "[*] Triggering create-cross-connect action on quantum-terminal/0..."
juju run quantum-terminal/0 create-cross-connect \
  service-id="example-qservice-opt-01" \
  target-node-ip="10.0.0.254" \
  ingress-port=1 \
  egress-port=2 \
  admin-state="ENABLED" || echo "[!] Juju action failed. Ensure the charm is active."

echo "=================================================================="
echo "[+] Action execution complete."
echo "=================================================================="
