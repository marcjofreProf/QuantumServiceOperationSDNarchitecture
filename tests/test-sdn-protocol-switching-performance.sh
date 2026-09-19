#!/usr/bin/env bash

set -eo pipefail

ITERATIONS="${1:-5}"
TARGET_DEVICE="${TARGET_DEVICE:-quantum-node-1}"
TARGET_NODE_IP="${TARGET_NODE_IP:-10.0.0.254}"
INTERVAL="${INTERVAL:-0.5}"

CONTROLLER_HOST="172.28.32.106"
RESTCONF_GW_URL="${RESTCONF_GW_URL:-http://127.0.0.1:8181/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service}"
ONOS_GNMI_TARGET="${CONTROLLER_HOST}:5150"

RESULTS_FILE="/tmp/sdn_benchmark_raw.txt"
SUMMARY_FILE="/tmp/sdn_benchmark_summary.txt"
FIFO_IN="/tmp/gnmi_fifo_in_$$"
FIFO_OUT="/tmp/gnmi_fifo_out_$$"
GNMI_DEBUG_LOG="/tmp/gnmi_debug.log"

rm -f "$RESULTS_FILE" "$SUMMARY_FILE" "$FIFO_IN" "$FIFO_OUT" "$GNMI_DEBUG_LOG"

# Python binary path setup
PYTHON_BIN="python3"
if [ -f "./.venv/bin/python3" ]; then
    PYTHON_BIN="./.venv/bin/python3"
fi

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
preflight_failed=0

echo "=================================================================="
echo "  Pre-flight checks"
echo "=================================================================="

# 1. Python interpreter
if [ ! -x "$PYTHON_BIN" ]; then
    echo "[!] ERROR: Python interpreter not found or not executable: $PYTHON_BIN"
    preflight_failed=1
else
    echo "    [OK] Python: $PYTHON_BIN"
fi

# 2. pygnmi in that interpreter
if [ "$preflight_failed" -eq 0 ]; then
    if ! "$PYTHON_BIN" -c 'import pygnmi' >/dev/null 2>&1; then
        echo "[!] ERROR: pygnmi is not importable in $PYTHON_BIN"
        echo "    Install it with: $PYTHON_BIN -m pip install pygnmi"
        preflight_failed=1
    else
        echo "    [OK] pygnmi is importable"
    fi
fi

# 3. Client certs — presence, readability, and whether they match the
#    controller's current set. The controller-side fingerprint is fetched
#    from the onos-cli pod via kubectl (or skipped if kubectl isn't
#    available on this host).
for c in /etc/onos/certs/client1.crt \
         /etc/onos/certs/client1.key \
         /etc/onos/certs/tls.cacrt; do
    if [ ! -f "$c" ]; then
        echo "[!] ERROR: missing $c"
        preflight_failed=1
    elif [ ! -r "$c" ]; then
        echo "[!] ERROR: $c is not readable by $USER"
        preflight_failed=1
    else
        echo "    [OK] $c present and readable"
    fi
done

# If kubectl is available, compare with what the controller currently has.
if command -v kubectl >/dev/null 2>&1 && \
   kubectl get pods -n micro-onos >/dev/null 2>&1; then

    echo "    [*] Comparing certs with the controller's current set..."

    # Local fingerprints (sha256 of the cert bodies)
    local_leaf_fp=$(openssl x509 -in /etc/onos/certs/client1.crt -noout -fingerprint -sha256 2>/dev/null \
                    | awk -F= '{print $2}')
    local_ca_fp=$(openssl x509 -in /etc/onos/certs/tls.cacrt  -noout -fingerprint -sha256 2>/dev/null \
                    | awk -F= '{print $2}')

    # Controller fingerprints (from the running pods)
    CLI_POD=$(kubectl get pods -n micro-onos -l app=onos \
              -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    CONFIG_POD=$(kubectl get pods -n micro-onos -l app.kubernetes.io/name=onos-config \
                 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -n "$CLI_POD" ]; then
        ctrl_leaf_fp=$(kubectl exec -n micro-onos "$CLI_POD" -- \
            sh -c 'cat /etc/ssl/certs/client1.crt' 2>/dev/null \
            | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
            | awk -F= '{print $2}')
    fi

    if [ -n "$CONFIG_POD" ]; then
        ctrl_ca_fp=$(kubectl exec -n micro-onos "$CONFIG_POD" -- \
            sh -c 'cat /etc/onos/certs/tls.cacrt' 2>/dev/null \
            | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
            | awk -F= '{print $2}')
    fi

    if [ -n "${ctrl_leaf_fp:-}" ] && [ "$local_leaf_fp" != "$ctrl_leaf_fp" ]; then
        echo "[!] ERROR: client1.crt on this host does NOT match the controller's client cert."
        echo "    local:      $local_leaf_fp"
        echo "    controller: $ctrl_leaf_fp"
        echo "    Re-extract from the controller host:"
        echo "      kubectl exec -n micro-onos \$CLI_POD -- cat /etc/ssl/certs/client1.crt | sudo tee /etc/onos/certs/client1.crt >/dev/null"
        echo "      kubectl exec -n micro-onos \$CLI_POD -- cat /etc/ssl/certs/client1.key | sudo tee /etc/onos/certs/client1.key >/dev/null"
        preflight_failed=1
    elif [ -n "${ctrl_leaf_fp:-}" ]; then
        echo "    [OK] client1.crt matches the controller"
    fi

    if [ -n "${ctrl_ca_fp:-}" ] && [ "$local_ca_fp" != "$ctrl_ca_fp" ]; then
        echo "[!] ERROR: tls.cacrt on this host does NOT match the controller's CA."
        echo "    local:      $local_ca_fp"
        echo "    controller: $ctrl_ca_fp"
        preflight_failed=1
    elif [ -n "${ctrl_ca_fp:-}" ]; then
        echo "    [OK] tls.cacrt matches the controller"
    fi
else
    echo "    [--] kubectl not available or no access to micro-onos namespace"
    echo "         Cannot verify that local certs match the controller's set."
fi

# 3b. Cert subject sanity check: the client cert must NOT have the server's
#     CN. If it does, someone copied the wrong file.
if [ -f /etc/onos/certs/client1.crt ]; then
    cn=$(openssl x509 -in /etc/onos/certs/client1.crt -noout -subject 2>/dev/null \
         | sed -n 's/.*CN *= *\([^,]*\).*/\1/p')
    if [ -z "$cn" ]; then
        echo "[!] ERROR: could not read subject from /etc/onos/certs/client1.crt"
        preflight_failed=1
    elif [[ "$cn" == onos-config* ]]; then
        echo "[!] ERROR: /etc/onos/certs/client1.crt has CN='$cn', which is the SERVER cert, not a client cert."
        echo "    Re-extract the client cert from the onos-cli pod:"
        echo "      CLI_POD=\$(kubectl get pods -n micro-onos -l app=onos -o jsonpath='{.items[0].metadata.name}')"
        echo "      kubectl exec -n micro-onos \$CLI_POD -- cat /etc/ssl/certs/client1.crt | sudo tee /etc/onos/certs/client1.crt >/dev/null"
        preflight_failed=1
    else
        echo "    [OK] client1.crt subject CN=$cn"
    fi
fi

# 4. Reachability of onos-config gNMI
if nc -z "$CONTROLLER_HOST" 5150 2>/dev/null; then
    echo "    [OK] TCP $CONTROLLER_HOST:5150 reachable"
else
    echo "[!] ERROR: cannot reach $CONTROLLER_HOST:5150"
    echo "    Ensure the onos-config LoadBalancer or port-forward is active."
    preflight_failed=1
fi

# 5. RESTCONF gateway (informational only — modes 1,2,6 need it)
if curl -sf -o /dev/null "http://127.0.0.1:8181/restconf/" 2>/dev/null; then
    echo "    [OK] RESTCONF gateway reachable at 127.0.0.1:8181"
else
    echo "    [--] RESTCONF gateway not reachable at 127.0.0.1:8181"
    echo "         Modes 1, 2 and 6 will fail; modes 3, 4, 5 can still run."
fi

if [ "$preflight_failed" -ne 0 ]; then
    echo
    echo "[!] Pre-flight checks failed. Aborting."
    exit 1
fi

echo "    All required pre-flight checks passed."
echo

# Map non-IP hostnames to prevent 5s DNS timeouts in ONOS backend
PAYLOAD_NODE_IP="${TARGET_NODE_IP}"
PAYLOAD_TARGET_DEVICE="${TARGET_DEVICE}"
if [[ "$PAYLOAD_NODE_IP" == "quantum-node-1" || ! "$PAYLOAD_NODE_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    PAYLOAD_NODE_IP="10.0.0.254"
    PAYLOAD_TARGET_DEVICE="10.0.0.254"
fi

get_time_ms() {
    $PYTHON_BIN -c 'import time; print(int(time.time() * 1000))'
}

time_exec() {
    local cmd="$1"
    local start_t end_t elapsed
    start_t=$(get_time_ms)
    if eval "$cmd" >/tmp/nb_cmd_last_error.log 2>&1; then
        end_t=$(get_time_ms)
        elapsed=$((end_t - start_t))
        echo "$elapsed"
    else
        echo "FAILED"
    fi
}

calc_stats() {
    $PYTHON_BIN -c '
import sys, math, re

raw_input = " ".join(sys.argv[1:])
vals = [float(n) for n in re.findall(r"\d+\.?\d*", raw_input) if n and n != "FAILED"]

if not vals:
    print("0.0|0.0|0.0|0.0")
else:
    avg = sum(vals) / len(vals)
    std = math.sqrt(sum((x - avg) ** 2 for x in vals) / len(vals))
    print(f"{avg:.1f}|{std:.1f}|{min(vals):.1f}|{max(vals):.1f}")
' "$@"
}

# --- PERSISTENT gNMI DAEMON SETUP ---

PY_DAEMON_SCRIPT="/tmp/gnmi_daemon_$$.py"

cat << 'PYEOF' > "$PY_DAEMON_SCRIPT"
import sys, time, warnings, logging, json, traceback, os
warnings.filterwarnings('ignore')
logging.disable(logging.CRITICAL)

DEBUG_LOG = "/tmp/gnmi_debug.log"

target = sys.argv[1]
device = sys.argv[2]
host, port = target.split(':') if ':' in target else (target, '5150')

with open(DEBUG_LOG, "w") as f:
    f.write(f"daemon starting target={target} device={device}\n")

# --- import pygnmi ---
try:
    from pygnmi.client import gNMIclient
except Exception as e:
    with open(DEBUG_LOG, "a") as f:
        f.write(f"import pygnmi failed: {e}\n")
    print(f"FATAL|import pygnmi failed: {e}")
    sys.stdout.flush()
    sys.exit(1)

# --- verify certs exist ---
for p in ("/etc/onos/certs/client1.crt",
          "/etc/onos/certs/client1.key",
          "/etc/onos/certs/tls.cacrt"):
    if not os.path.exists(p):
        with open(DEBUG_LOG, "a") as f:
            f.write(f"missing cert file: {p}\n")
        print(f"FATAL|missing cert file: {p}")
        sys.stdout.flush()
        sys.exit(1)

# --- connect ---
gc = None
try:
    gc = gNMIclient(
        target=(host, int(port)),
        skip_verify=True,
        path_cert='/etc/onos/certs/client1.crt',
        path_key='/etc/onos/certs/client1.key',
        path_root='/etc/onos/certs/tls.cacrt'
    )
    gc.connect()
    with open(DEBUG_LOG, "a") as f:
        f.write("gNMI client connected\n")
except Exception as e:
    with open(DEBUG_LOG, "a") as f:
        f.write(f"connect failed: {e}\n")
        traceback.print_exc(file=f)
    print(f"FATAL|connect failed: {e}")
    sys.stdout.flush()
    sys.exit(1)

while True:
    line = sys.stdin.readline()
    if not line or 'QUIT' in line:
        break

    parts = line.strip().split('|')
    action = parts[0]

    try:
        t0 = time.perf_counter()
        if action == "SET":
            raw_val = parts[1] if len(parts) > 1 else ""
            json_val = json.dumps(str(raw_val))
            paths = [
                '/openconfig-interfaces:interfaces/interface[name=eth1]/config/description',
                '/interfaces/interface[name=eth1]/config/description'
            ]
            success = False
            for p in paths:
                try:
                    gc.set(update=[(p, json_val)], target=device)
                    success = True
                    break
                except Exception as path_err:
                    with open(DEBUG_LOG, "a") as f:
                        f.write(f"Path failed [{p}]: {path_err}\n")
                    continue
            if not success:
                raise Exception("gNMI Set path match failed")

        elif action == "GET":
            gc.get(path=['/openconfig-interfaces:interfaces/interface[name=eth1]'], target=device)

        elapsed = int((time.perf_counter() - t0) * 1000)
        print(f"{elapsed}")
    except Exception as e:
        with open(DEBUG_LOG, "a") as f:
            traceback.print_exc(file=f)
        print("FAILED")
    sys.stdout.flush()

if gc:
    try: gc.close()
    except Exception: pass
PYEOF

mkfifo "$FIFO_IN" "$FIFO_OUT"

# Single daemon process using created file script
$PYTHON_BIN "$PY_DAEMON_SCRIPT" "$ONOS_GNMI_TARGET" "$TARGET_DEVICE" < "$FIFO_IN" > "$FIFO_OUT" &
DAEMON_PID=$!

# Open file descriptors on the created FIFOs
exec 3> "$FIFO_IN"
exec 4< "$FIFO_OUT"

cleanup() {
    echo "QUIT" >&3 2>/dev/null || true
    exec 3>&- 2>/dev/null || true
    exec 4<&- 2>/dev/null || true
    rm -f "$FIFO_IN" "$FIFO_OUT" "$PY_DAEMON_SCRIPT"
    if [ -n "$DAEMON_PID" ]; then
        kill "$DAEMON_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

sleep 1

# Check whether the daemon is still alive and whether it printed a FATAL line.
# If FATAL, we surface the reason and exit instead of showing "FAILED" for
# every benchmark mode.
if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    DAEMON_MSG=$(head -n1 "$FIFO_OUT" 2>/dev/null || echo "")
    if [[ "$DAEMON_MSG" == FATAL* ]]; then
        echo
        echo "[!] gNMI daemon failed to start:"
        echo "    ${DAEMON_MSG#FATAL|}"
        echo "    See ${GNMI_DEBUG_LOG} for details."
    else
        echo
        echo "[!] gNMI daemon exited unexpectedly."
        echo "    See ${GNMI_DEBUG_LOG} for details."
    fi
    exit 1
fi

exec_gnmi_op() {
    local op_type="$1" val_arg="$2"
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        echo "FAILED"
        return
    fi
    echo "${op_type}|${val_arg}" >&3
    local res
    read -r res <&4 || res="FAILED"
    if [[ "$res" == FATAL* ]]; then
        echo "[!] gNMI daemon reported: ${res#FATAL|}" >&2
        echo "FAILED"
        return
    fi
    echo "$res"
}

check_step() {
    local step_name="$1" result="$2"
    if [ "$result" == "FAILED" ]; then
        echo "Warning: ${step_name} failed." >&2
    fi
}

# --- PROTOCOL HELPERS ---

exec_connect() {
    local mode_id="$1" nb_proto="$2" sb_proto="$3" service_id="$4"
    local service_desc="qservice-m${mode_id}-${sb_proto}-${service_id}"

    if [ "$nb_proto" == "RESTCONF" ]; then
        time_exec "curl -s -X POST '${RESTCONF_GW_URL}' \
            -H 'Content-Type: application/json' \
            -H 'X-Southbound-Target: ${sb_proto}' \
            -d '{\"service-id\":\"${service_id}\",\"target-node\":\"${PAYLOAD_TARGET_DEVICE}\",\"target-node-ip\":\"${PAYLOAD_NODE_IP}\",\"ingress-port\":1,\"egress-port\":2,\"admin-state\":\"ENABLED\",\"name\":\"eth1\",\"description\":\"${service_desc}\"}'"
    else
        exec_gnmi_op "SET" "$service_desc"
    fi
}

exec_disconnect() {
    local mode_id="$1" nb_proto="$2" sb_proto="$3" service_id="$4"

    if [ "$nb_proto" == "RESTCONF" ]; then
        time_exec "curl -s -f -X DELETE '${RESTCONF_GW_URL}' \
            -H 'Content-Type: application/json' \
            -H 'X-Southbound-Target: ${sb_proto}' \
            -d '{\"service-id\":\"${service_id}\",\"target-node\":\"${PAYLOAD_TARGET_DEVICE}\"}'"
    else
        exec_gnmi_op "SET" "disabled"
    fi
}

run_lifecycle_benchmark() {
    local mode_id="$1" mode_name="$2" nb_proto="$3" sb_proto="$4"
    echo "=================================================================="
    echo "  Running Benchmark Mode ${mode_id}: ${mode_name}"
    echo "  Target: ${TARGET_DEVICE} (${TARGET_NODE_IP}) | ${ITERATIONS} Full Trials"
    echo "=================================================================="

    # 1. Unmeasured Pre-Warmup Run
    echo -n "[*] Pre-Warmup Lifecycle Run... "
    wp_conn=$(exec_connect "$mode_id" "$nb_proto" "$sb_proto" "warmup")
    check_step "Warmup Connect" "$wp_conn"

    if [ "$nb_proto" == "RESTCONF" ]; then
        wp_stat=$(time_exec "curl -s -f -X GET '${RESTCONF_GW_URL}?sb=${sb_proto}'")
    else
        wp_stat=$(exec_gnmi_op "GET" "")
    fi
    check_step "Warmup Status" "$wp_stat"

    wp_disc=$(exec_disconnect "$mode_id" "$nb_proto" "$sb_proto" "warmup")
    check_step "Warmup Disconnect" "$wp_disc"
    echo "Done (Conn: ${wp_conn}ms | Stat: ${wp_stat}ms | Disc: ${wp_disc}ms)"
    sleep 1

    # 2. Measured Iterations
    local conn_list="" stat_list="" disc_list="" total_list=""

    for ((i=1; i<=ITERATIONS; i++)); do
        local service_id="qservice-m${mode_id}-i${i}"

        # Connect Phase
        t_conn=$(exec_connect "$mode_id" "$nb_proto" "$sb_proto" "$service_id")

        # Status Read Phase
        if [ "$nb_proto" == "RESTCONF" ]; then
            t_stat=$(time_exec "curl -s -f -X GET '${RESTCONF_GW_URL}?sb=${sb_proto}'")
        else
            t_stat=$(exec_gnmi_op "GET" "")
        fi

        # Disconnect Phase
        t_disc=$(exec_disconnect "$mode_id" "$nb_proto" "$sb_proto" "$service_id")

        # Total Cycle Time
        if [ "$t_conn" != "FAILED" ] && [ "$t_stat" != "FAILED" ] && [ "$t_disc" != "FAILED" ]; then
            t_total=$((t_conn + t_stat + t_disc))
        else
            t_total="FAILED"
        fi

        conn_list="${conn_list} ${t_conn}"
        stat_list="${stat_list} ${t_stat}"
        disc_list="${disc_list} ${t_disc}"
        total_list="${total_list} ${t_total}"

        echo "  [Trial ${i}/${ITERATIONS}] Conn: ${t_conn}ms | Stat: ${t_stat}ms | Disc: ${t_disc}ms | Total: ${t_total}ms"
        sleep "$INTERVAL"
    done

    # Statistics Calculation
    IFS='|' read -r c_avg c_sd c_min c_max <<< "$(calc_stats $conn_list)"
    IFS='|' read -r s_avg s_sd s_min s_max <<< "$(calc_stats $stat_list)"
    IFS='|' read -r d_avg d_sd d_min d_max <<< "$(calc_stats $disc_list)"
    IFS='|' read -r t_avg t_sd t_min t_max <<< "$(calc_stats $total_list)"

    echo "${mode_id}|${mode_name}|${c_avg}±${c_sd}|${s_avg}±${s_sd}|${d_avg}±${d_sd}|${t_avg}±${t_sd}" >> "$SUMMARY_FILE"
    echo ""
}

# Execute Benchmark Modes
run_lifecycle_benchmark "1" "RESTCONF -> NETCONF" "RESTCONF" "NETCONF"
run_lifecycle_benchmark "2" "RESTCONF -> gNOI"    "RESTCONF" "gNOI"
run_lifecycle_benchmark "3" "gNMI -> NETCONF"     "gNMI"     "NETCONF"
run_lifecycle_benchmark "4" "gNMI -> gNOI"        "gNMI"     "gNOI"
run_lifecycle_benchmark "5" "gNMI -> gNMI"        "gNMI"     "gNMI"
run_lifecycle_benchmark "6" "RESTCONF -> gNMI"    "RESTCONF" "gNMI"

# Summary Output Table
echo "=========================================================================================================="
echo "                   SDN PROTOCOL BENCHMARK SUMMARY (${ITERATIONS} Full Lifecycle Trials)                  "
echo "=========================================================================================================="
printf "%-7s | %-20s | %-15s | %-15s | %-15s | %-15s\n" "Mode" "Path" "Connect (ms)" "Status (ms)" "Disconnect (ms)" "Total Cycle (ms)"
echo "----------------------------------------------------------------------------------------------------------"

while IFS='|' read -r mid mname c_stat s_stat d_stat t_stat; do
    printf "%-7s | %-20s | %-15s | %-15s | %-15s | %-15s\n" "Mode ${mid}" "${mname}" "${c_stat}" "${s_stat}" "${d_stat}" "${t_stat}"
done < "$SUMMARY_FILE"
echo "=========================================================================================================="
