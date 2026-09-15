#!/usr/bin/env bash

set -eo pipefail

ITERATIONS="${1:-5}"
TARGET_DEVICE="${TARGET_DEVICE:-quantum-node-1}"
TARGET_NODE_IP="${TARGET_NODE_IP:-10.0.0.254}"
INTERVAL="${INTERVAL:-0.5}"

CONTROLLER_HOST="10.0.0.2"
RESTCONF_GW_URL="${RESTCONF_GW_URL:-http://localhost:8181/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service}"
ONOS_GNMI_TARGET="${CONTROLLER_HOST}:5150"

RESULTS_FILE="/tmp/sdn_benchmark_raw.txt"
SUMMARY_FILE="/tmp/sdn_benchmark_summary.txt"
rm -f "$RESULTS_FILE" "$SUMMARY_FILE"

# Python binary path setup
PYTHON_BIN="python3"
if [ -f "./.venv/bin/python3" ]; then
    PYTHON_BIN="./.venv/bin/python3"
fi

# Ensure valid IP format for RESTCONF JSON payloads
PAYLOAD_NODE_IP="${TARGET_NODE_IP}"
if [[ "$PAYLOAD_NODE_IP" == "quantum-node-1" || ! "$PAYLOAD_NODE_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    PAYLOAD_NODE_IP="10.0.0.254"
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

# --- PROTOCOL HELPERS ---

exec_connect() {
    local mode_id="$1" nb_proto="$2" sb_proto="$3" service_id="$4"
    local service_desc="qservice-m${mode_id}-${sb_proto}-${service_id}"

    if [ "$nb_proto" == "RESTCONF" ]; then
        time_exec "curl -s -X POST '${RESTCONF_GW_URL}' \
            -H 'Content-Type: application/json' \
            -H 'X-Southbound-Target: ${sb_proto}' \
            -d '{\"service-id\":\"${service_id}\",\"target-node\":\"${TARGET_DEVICE}\",\"target-node-ip\":\"${PAYLOAD_NODE_IP}\",\"ingress-port\":1,\"egress-port\":2,\"admin-state\":\"ENABLED\",\"name\":\"eth1\",\"description\":\"${service_desc}\"}'"
    else
        # gNMI Set via Python pygnmi with JSON-marshaled value
        $PYTHON_BIN - "$ONOS_GNMI_TARGET" "$TARGET_DEVICE" "$service_desc" << 'PYEOF'
import sys, time, json, warnings, logging
warnings.filterwarnings('ignore')
logging.disable(logging.CRITICAL)

target = sys.argv[1]
device = sys.argv[2]
raw_val = sys.argv[3]
host, port = target.split(':') if ':' in target else (target, '5150')

try:
    from pygnmi.client import gNMIclient
    gc = gNMIclient(
        target=(host, int(port)),
        skip_verify=True,
        path_cert='/etc/onos/certs/tls.crt',
        path_key='/etc/onos/certs/tls.key',
        path_root='/etc/onos/certs/tls.crt'
    )
    gc.connect()
    t0 = time.perf_counter()
    # Format value as JSON string expected by ONOS
    gc.set(update=[('/interfaces/interface[name=eth1]/config/description', json.dumps(raw_val))], target=device)
    elapsed = (time.perf_counter() - t0) * 1000
    gc.close()
    print(f"{int(elapsed)}")
except Exception as e:
    sys.stderr.write(f"gNMI Connect Error: {e}\n")
    print("FAILED")
PYEOF
    fi
}

exec_disconnect() {
    local mode_id="$1" nb_proto="$2" sb_proto="$3" service_id="$4"

    if [ "$nb_proto" == "RESTCONF" ]; then
        time_exec "curl -s -f -X DELETE '${RESTCONF_GW_URL}' \
            -H 'Content-Type: application/json' \
            -H 'X-Southbound-Target: ${sb_proto}' \
            -d '{\"service-id\":\"${service_id}\",\"target-node\":\"${TARGET_DEVICE}\"}'"
    else
        # gNMI Set via Python pygnmi with JSON-marshaled value
        $PYTHON_BIN - "$ONOS_GNMI_TARGET" "$TARGET_DEVICE" "disabled" << 'PYEOF'
import sys, time, json, warnings, logging
warnings.filterwarnings('ignore')
logging.disable(logging.CRITICAL)

target = sys.argv[1]
device = sys.argv[2]
raw_val = sys.argv[3]
host, port = target.split(':') if ':' in target else (target, '5150')

try:
    from pygnmi.client import gNMIclient
    gc = gNMIclient(
        target=(host, int(port)),
        skip_verify=True,
        path_cert='/etc/onos/certs/tls.crt',
        path_key='/etc/onos/certs/tls.key',
        path_root='/etc/onos/certs/tls.crt'
    )
    gc.connect()
    t0 = time.perf_counter()
    # Format value as JSON string expected by ONOS
    gc.set(update=[('/interfaces/interface[name=eth1]/config/description', json.dumps(raw_val))], target=device)
    elapsed = (time.perf_counter() - t0) * 1000
    gc.close()
    print(f"{int(elapsed)}")
except Exception as e:
    sys.stderr.write(f"gNMI Disconnect Error: {e}\n")
    print("FAILED")
PYEOF
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
    
    if [ "$nb_proto" == "RESTCONF" ]; then
        wp_stat=$(time_exec "curl -s -f -X GET '${RESTCONF_GW_URL}?sb=${sb_proto}'")
    else
        wp_stat=$($PYTHON_BIN - "$ONOS_GNMI_TARGET" "$TARGET_DEVICE" << 'PYEOF'
import sys, time, warnings, logging
warnings.filterwarnings('ignore')
logging.disable(logging.CRITICAL)
target, device = sys.argv[1], sys.argv[2]
host, port = target.split(':') if ':' in target else (target, '5150')
try:
    from pygnmi.client import gNMIclient
    gc = gNMIclient(target=(host, int(port)), skip_verify=True, path_cert='/etc/onos/certs/tls.crt', path_key='/etc/onos/certs/tls.key', path_root='/etc/onos/certs/tls.crt')
    gc.connect()
    t0 = time.perf_counter()
    gc.get(path=['/interfaces/interface[name=eth1]'], target=device)
    elapsed = (time.perf_counter() - t0) * 1000
    gc.close()
    print(f"{int(elapsed)}")
except Exception:
    print("FAILED")
PYEOF
)
    fi

    wp_disc=$(exec_disconnect "$mode_id" "$nb_proto" "$sb_proto" "warmup")
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
            t_stat=$($PYTHON_BIN - "$ONOS_GNMI_TARGET" "$TARGET_DEVICE" << 'PYEOF'
import sys, time, warnings, logging
warnings.filterwarnings('ignore')
logging.disable(logging.CRITICAL)

target = sys.argv[1]
device = sys.argv[2]
host, port = target.split(':') if ':' in target else (target, '5150')

try:
    from pygnmi.client import gNMIclient
    gc = gNMIclient(
        target=(host, int(port)),
        skip_verify=True,
        path_cert='/etc/onos/certs/tls.crt',
        path_key='/etc/onos/certs/tls.key',
        path_root='/etc/onos/certs/tls.crt'
    )
    gc.connect()
    t0 = time.perf_counter()
    gc.get(path=['/interfaces/interface[name=eth1]'], target=device)
    elapsed = (time.perf_counter() - t0) * 1000
    gc.close()
    print(f"{int(elapsed)}")
except Exception as e:
    sys.stderr.write(f"gNMI Status Read Error: {e}\n")
    print("FAILED")
PYEOF
)
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
