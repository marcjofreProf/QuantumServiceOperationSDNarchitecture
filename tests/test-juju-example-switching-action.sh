#!/usr/bin/env bash
# tests/test-juju-example-switching-action.sh
# Triggers the RESTCONF cross-connect action sequence with strict automated HTTP state assertions.

set -eo pipefail

# 1. Ensure script executes relative to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

CONTROLLER_NAME="terminal-controller"
MODEL_NAME="terminal-model"
APP_NAME="quantum-terminal"
RESTCONF_ENDPOINT="http://10.0.0.2:8181/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service"
TEST_FAILED=0

echo "=================================================================="
echo "  Testing Juju Action: Connect -> Status -> Disconnect -> Status"
echo "=================================================================="

# 2. Switch active context to target model
echo "[*] Selecting model context (${CONTROLLER_NAME}:${MODEL_NAME})..."
juju switch "${CONTROLLER_NAME}:${MODEL_NAME}" 2>/dev/null || juju switch "${MODEL_NAME}" 2>/dev/null || true

# 3. Dynamically discover active application unit
UNIT_NAME=$(juju status --format=line 2>/dev/null | grep -oE "${APP_NAME}/[0-9]+" | head -n 1 || true)
if [ -z "$UNIT_NAME" ]; then
    UNIT_NAME="${APP_NAME}/0"
fi

# -------------------------------------------------------------------
# STEP 1: CONNECT
# -------------------------------------------------------------------
echo -e "\n[*] [1/4] Triggering create-cross-connect action on ${UNIT_NAME}..."

CONNECT_OUTPUT=$(juju run "$UNIT_NAME" create-cross-connect \
  service-id="example-qservice-opt-01" \
  target-node-ip="10.0.0.254" \
  ingress-port=1 \
  egress-port=2 \
  admin-state="ENABLED" \
  --wait 5m 2>&1) || true

echo "$CONNECT_OUTPUT"

if echo "$CONNECT_OUTPUT" | grep -Ei -q "failed|error"; then
    echo "[!] Step 1 (create-cross-connect) failed."
    TEST_FAILED=1
fi

# -------------------------------------------------------------------
# STEP 2: STATUS ASSERTION (POST-CONNECT)
# -------------------------------------------------------------------
echo -e "\n[*] [2/4] Querying RESTCONF Switch State (Post-Connect)..."
echo "GET ${RESTCONF_ENDPOINT}"
HTTP_CODE_CONN=$(curl -s -o /tmp/restconf_conn.json -w "%{http_code}" -X GET "${RESTCONF_ENDPOINT}" || true)
echo "HTTP Response Code: ${HTTP_CODE_CONN}"
echo "Payload Content:"
if [ -s /tmp/restconf_conn.json ]; then
    jq . /tmp/restconf_conn.json 2>/dev/null || cat /tmp/restconf_conn.json
    echo ""
else
    echo "(No payload returned / Endpoint unavailable)"
fi

# Assertion 1: Must be HTTP 200 OK
if [ "$HTTP_CODE_CONN" -eq 200 ]; then
    echo "[+] Assertion Passed: HTTP 200 received (Active cross-connect verified)."
else
    echo "[!] Assertion Failed: Expected HTTP 200, but received HTTP $HTTP_CODE_CONN."
    TEST_FAILED=1
fi

# -------------------------------------------------------------------
# STEP 3: DISCONNECT
# -------------------------------------------------------------------
echo -e "\n[*] [3/4] Triggering delete-cross-connect action on ${UNIT_NAME}..."

DISCONNECT_OUTPUT=$(juju run "$UNIT_NAME" delete-cross-connect \
  service-id="example-qservice-opt-01" \
  --wait 5m 2>&1) || true

echo "$DISCONNECT_OUTPUT"

if echo "$DISCONNECT_OUTPUT" | grep -Ei -q "failed|error"; then
    echo "[!] Step 3 (delete-cross-connect) failed."
    TEST_FAILED=1
fi

# -------------------------------------------------------------------
# STEP 4: STATUS ASSERTION (POST-DISCONNECT)
# -------------------------------------------------------------------
echo -e "\n[*] [4/4] Querying RESTCONF Switch State (Post-Disconnect)..."
echo "GET ${RESTCONF_ENDPOINT}"
HTTP_CODE_DISC=$(curl -s -o /tmp/restconf_disc.json -w "%{http_code}" -X GET "${RESTCONF_ENDPOINT}" || true)
echo "HTTP Response Code: ${HTTP_CODE_DISC}"
echo "Payload Content:"
if [ -s /tmp/restconf_disc.json ]; then
    jq . /tmp/restconf_disc.json 2>/dev/null || cat /tmp/restconf_disc.json
    echo ""
else
    echo "(Resource deleted / empty response)"
fi

# Assertion 2: Must be HTTP 404 NOT FOUND
if [ "$HTTP_CODE_DISC" -eq 404 ]; then
    echo "[+] Assertion Passed: HTTP 404 received (Cross-connect successfully cleared)."
else
    echo "[!] Assertion Failed: Expected HTTP 404, but received HTTP $HTTP_CODE_DISC."
    TEST_FAILED=1
fi

# -------------------------------------------------------------------
# 5. Final Validation and Execution Exit Code
# -------------------------------------------------------------------
if [ "$TEST_FAILED" -ne 0 ]; then
    echo "=================================================================="
    echo "[!] Test failed: One or more Juju actions or HTTP assertions failed."
    echo "=================================================================="
    exit 1
else
    echo "=================================================================="
    echo "[+] Action execution succeeded and all state assertions passed."
    echo "=================================================================="
    exit 0
fi
