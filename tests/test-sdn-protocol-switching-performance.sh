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

# Determine Python binary path
PYTHON_BIN="python3"
if [ -f "./.venv/bin/python3" ]; then
    PYTHON_BIN="./.venv/bin/python3"
fi

get_time_ms() {
    python3 -c 'import time; print(int(time.time() * 1000))'
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
    python3 -c '
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

# --- PROTOCOL EXECUTION HELPERS ---

exec_connect() {
    local mode_id="$1" nb_proto="$2" sb_proto="$3" service_id="$4"
    local service_desc="qservice-m${mode_id}-${sb_proto}-${service_id}"

    if [ "$nb_proto" == "RESTCONF" ]; then
        time_exec "curl -s -f -X POST '${RESTCONF_GW_URL}?sb=${sb_proto}' \
            -H 'Content-Type: application/json' \
            -H 'X-Southbound-Target: ${sb_proto}' \
            -d '{\"service-id\":\"${service_id}\",\"target-node\":\"${TARGET_DEVICE}\",\"target-node-ip\":\"${TARGET_NODE_IP}\",\"ingress-port\":1,\"egress-port\":2,\"admin-state\":\"ENABLED\",\"name\":\"eth1\",\"description\":\"${service_desc}\"}'"
    else
        time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --timeout 5s --target ${TARGET_DEVICE} set --update '/interfaces/interface[name=eth1]/config/description:::string:::${service_desc}'"
    fi
}

exec_status() {
    local mode_id="$1" nb_proto="$2" sb_proto="$3"

    if [ "$nb_proto" == "RESTCONF" ]; then
        time_exec "curl -s -f -X GET '${RESTCONF_GW_URL}?sb=${sb_proto}'"
    else
        time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --timeout 5s --target ${TARGET_DEVICE} get --path '/interfaces/interface[name=eth1]'"
    fi
}

exec_disconnect() {
    local mode_id="$1" nb_proto="$2" sb_proto="$3" service_id="$4"

    if [ "$nb_proto" == "RESTCONF" ]; then
        time_exec "curl -s -f -X DELETE '${RESTCONF_GW_URL}?sb=${sb_proto}&service-id=${service_id}&target-node=${TARGET_DEVICE}' \
            -H 'Content-Type: application/json' \
            -H 'X-Southbound-Target: ${sb_proto}' \
            -d '{\"service-id\":\"${service_id}\",\"target-node\":\"${TARGET_DEVICE}\"}'"
    else
        time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --timeout 5s --target ${TARGET_DEVICE} set --update '/interfaces/interface[name=eth1]/config/description:::string:::disabled'"
    fi
}

run_lifecycle_benchmark() {
    local mode_id="$1" mode_name="$2" nb_proto="$3" sb_proto="$4"
    echo "=================================================================="
    echo "  Running Benchmark Mode ${mode_id}: ${mode_name}"
    echo "  Target: ${TARGET_DEVICE} (${TARGET_NODE_IP}) | ${ITERATIONS} Full Trials"
    echo "=================================================================="

    # 1. Unmeasured Pre-Warmup Run (Discarded from statistics)
    echo -n "[*] Pre-Warmup Lifecycle Run... "
    wp_conn=$(exec_connect "$mode_id" "$nb_proto" "$sb_proto" "warmup")
    wp_stat=$(exec_status "$mode_id" "$nb_proto" "$sb_proto")
    wp_disc=$(exec_disconnect "$mode_id" "$nb_proto" "$sb_proto" "warmup")
    echo "Done (Conn: ${wp_conn}ms | Stat: ${wp_stat}ms | Disc: ${wp_disc}ms)"
    sleep 1

    # 2. Measured Trials (Connect -> Status Read -> Disconnect)
    local conn_list="" stat_list="" disc_list="" total_list=""

    for ((i=1; i<=ITERATIONS; i++)); do
        local service_id="qservice-m${mode_id}-i${i}"

        # Connect Phase
        t_conn=$(exec_connect "$mode_id" "$nb_proto" "$sb_proto" "$service_id")

        # Status Read Phase
        t_stat=$(exec_status "$mode_id" "$nb_proto" "$sb_proto")

        # Disconnect Phase
        t_disc=$(exec_disconnect "$mode_id" "$nb_proto" "$sb_proto" "$service_id")

        # Total Trial Execution Time
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

    # Calculate Summaries
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

# Final Summary Table
echo "=========================================================================================================="
echo "                   SDN PROTOCOL BENCHMARK SUMMARY (${ITERATIONS} Full Lifecycle Trials)                  "
echo "=========================================================================================================="
printf "%-7s | %-20s | %-15s | %-15s | %-15s | %-15s\n" "Mode" "Path" "Connect (ms)" "Status (ms)" "Disconnect (ms)" "Total Cycle (ms)"
echo "----------------------------------------------------------------------------------------------------------"

while IFS='|' read -r mid mname c_stat s_stat d_stat t_stat; do
    printf "%-7s | %-20s | %-15s | %-15s | %-15s | %-15s\n" "Mode ${mid}" "${mname}" "${c_stat}" "${s_stat}" "${d_stat}" "${t_stat}"
done < "$SUMMARY_FILE"
echo "=========================================================================================================="
