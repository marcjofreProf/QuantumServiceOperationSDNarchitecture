#!/usr/bin/env bash
# tests/test-sdn-protocol-switching-performance.sh
# Real E2E benchmark across 4 NB/SB protocol matrix paths in micro-onos

set -eo pipefail

CONTROLLER_HOST="10.0.0.2"
RESTCONF_GW_URL="http://${CONTROLLER_HOST}:8181/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service"
ONOS_GNMI_TARGET="${CONTROLLER_HOST}:5150"
TARGET_DEVICE="devicesim-1"

RESULTS_FILE="/tmp/sdn_benchmark_results.txt"
rm -f "$RESULTS_FILE"

get_time_ms() {
    python3 -c 'import time; print(int(time.time() * 1000))'
}

# Real execution timer
time_exec() {
    local cmd="$1"
    local start_t end_t elapsed
    start_t=$(get_time_ms)
    eval "$cmd" >/dev/null 2>&1
    end_t=$(get_time_ms)
    elapsed=$((end_t - start_t))
    echo "$elapsed"
}

run_lifecycle_benchmark() {
    local mode_id="$1" mode_name="$2" nb_proto="$3" sb_proto="$4"
    echo "=================================================================="
    echo "  Running Real Benchmark Mode ${mode_id}: ${mode_name}"
    echo "=================================================================="

    local t_conn t_stat1 t_disc t_stat2 t_total

    # 1. Connect Phase
    echo "[*] [1/4] CONNECT (${nb_proto} -> Controller -> ${sb_proto})..."
    if [ "$nb_proto" == "RESTCONF" ]; then
        t_conn=$(time_exec "curl -s -f -X POST '${RESTCONF_GW_URL}' -H 'Content-Type: application/json' -H 'X-Southbound-Target: ${sb_proto}' -d '{\"service-id\":\"qservice-m${mode_id}\",\"target-node-ip\":\"10.0.0.254\",\"ingress-port\":1,\"egress-port\":2,\"admin-state\":\"ENABLED\"}'")
    else
        t_conn=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --skip-verify --target ${TARGET_DEVICE} set --update '/quantum-switching/cross-connect[id=qservice-m${mode_id}]:::json:::{\"ingress\":1,\"egress\":2,\"sb\":\"${sb_proto}\"}'")
    fi

    # 2. Status Check Post-Connect
    echo "[*] [2/4] STATUS CHECK (Post-Connect)..."
    if [ "$nb_proto" == "RESTCONF" ]; then
        t_stat1=$(time_exec "curl -s -f -X GET '${RESTCONF_GW_URL}?sb=${sb_proto}'")
    else
        t_stat1=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --skip-verify --target ${TARGET_DEVICE} get --path '/quantum-switching/cross-connect[id=qservice-m${mode_id}]'")
    fi

    # 3. Disconnect Phase
    echo "[*] [3/4] DISCONNECT (${nb_proto} -> Controller -> ${sb_proto})..."
    if [ "$nb_proto" == "RESTCONF" ]; then
        t_disc=$(time_exec "curl -s -f -X DELETE '${RESTCONF_GW_URL}?service-id=qservice-m${mode_id}&sb=${sb_proto}'")
    else
        t_disc=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --skip-verify --target ${TARGET_DEVICE} set --delete '/quantum-switching/cross-connect[id=qservice-m${mode_id}]'")
    fi

    # 4. Status Check Post-Disconnect
    echo "[*] [4/4] STATUS CHECK (Post-Disconnect)..."
    if [ "$nb_proto" == "RESTCONF" ]; then
        t_stat2=$(time_exec "curl -s -X GET '${RESTCONF_GW_URL}?sb=${sb_proto}'")
    else
        t_stat2=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --skip-verify --target ${TARGET_DEVICE} get --path '/quantum-switching/cross-connect[id=qservice-m${mode_id}]'")
    fi

    t_total=$((t_conn + t_stat1 + t_disc + t_stat2))
    echo "Mode ${mode_id} Results: Connect=${t_conn}ms | Status1=${t_stat1}ms | Disconnect=${t_disc}ms | Status2=${t_stat2}ms | Total=${t_total}ms"
    echo "${mode_id}|${mode_name}|${t_conn}|${t_stat1}|${t_disc}|${t_stat2}|${t_total}" >> "$RESULTS_FILE"
    echo ""
}

# Run 4 Real Matrix Modes
run_lifecycle_benchmark "1" "RESTCONF -> NETCONF" "RESTCONF" "NETCONF"
run_lifecycle_benchmark "2" "RESTCONF -> gNOI"    "RESTCONF" "gNOI"
run_lifecycle_benchmark "3" "gNMI -> NETCONF"     "gNMI"     "NETCONF"
run_lifecycle_benchmark "4" "gNMI -> gNOI"        "gNMI"     "gNOI"

echo "=================================================================================================="
echo "                                   SDN PROTOCOL BENCHMARK SUMMARY                                "
echo "=================================================================================================="
printf "%-7s | %-20s | %-10s | %-10s | %-10s | %-10s | %-12s\n" "Mode" "Path" "Connect" "Status-1" "Disconnect" "Status-2" "Total Time"
echo "--------------------------------------------------------------------------------------------------"

while IFS='|' read -r mid mname tc ts1 td ts2 tt; do
    printf "%-7s | %-20s | %-8sms | %-8sms | %-8sms | %-8sms | %-10sms\n" "Mode ${mid}" "${mname}" "${tc}" "${ts1}" "${td}" "${ts2}" "${tt}"
done < "$RESULTS_FILE"
echo "=================================================================================================="
