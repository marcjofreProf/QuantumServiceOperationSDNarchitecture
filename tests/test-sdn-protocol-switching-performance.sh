#!/usr/bin/env bash

set -eo pipefail

ITERATIONS="${1:-5}"
TARGET_DEVICE="${TARGET_DEVICE:-quantum-node-1}"
TARGET_NODE_IP="${TARGET_NODE_IP:-10.0.0.254}"

CONTROLLER_HOST="10.0.0.2"
RESTCONF_GW_URL="http://${CONTROLLER_HOST}:8181/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service"
ONOS_GNMI_TARGET="${CONTROLLER_HOST}:5150"

RESULTS_FILE="/tmp/sdn_benchmark_raw.txt"
SUMMARY_FILE="/tmp/sdn_benchmark_summary.txt"
rm -f "$RESULTS_FILE" "$SUMMARY_FILE"

get_time_ms() {
    python3 -c 'import time; print(int(time.time() * 1000))'
}

time_exec() {
    local cmd="$1"
    local start_t end_t elapsed
    start_t=$(get_time_ms)
    if eval "$cmd" >/dev/null 2>&1; then
        end_t=$(get_time_ms)
        elapsed=$((end_t - start_t))
        echo "$elapsed"
    else
        echo "FAILED"
    fi
}

calc_stats() {
    python3 -c 'import sys, math; vals = [float(x) for x in sys.argv[1:] if x.isdigit()]; print("0.0|0.0|0|0") if not vals else print(f"{sum(vals)/len(vals):.1f}|{math.sqrt(sum((x - sum(vals)/len(vals))**2 for x in vals)/len(vals)):.1f}|{int(min(vals))}|{int(max(vals))}")' "$@"
}

ensure_gnmi_topo_aspect() {
    echo "[*] Directing onos-topo target to gNMI port 50051 (IP: ${TARGET_NODE_IP})..."
    kubectl exec -n micro-onos deployment/onos-cli -- onos topo set entity "${TARGET_DEVICE}" \
      -a onos.topo.Configurable="{\"address\":\"${TARGET_NODE_IP}:50051\",\"type\":\"devicesim\",\"version\":\"1.0.x\"}" >/dev/null 2>&1 || true
    sleep 1
}

run_lifecycle_benchmark() {
    local mode_id="$1" mode_name="$2" nb_proto="$3" sb_proto="$4"
    echo "=================================================================="
    echo "  Running Benchmark Mode ${mode_id}: ${mode_name} (${ITERATIONS} Runs)"
    echo "  Target: ${TARGET_DEVICE} (${TARGET_NODE_IP})"
    echo "=================================================================="

    if [ "$sb_proto" == "gNMI" ]; then
        ensure_gnmi_topo_aspect
    fi

    local conn_list="" stat1_list="" disc_list="" stat2_list="" total_list=""

    for ((i=1; i<=ITERATIONS; i++)); do
        echo -n "[*] Iteration ${i}/${ITERATIONS}... "

        # 1. Connect
        if [ "$nb_proto" == "RESTCONF" ]; then
            t_conn=$(time_exec "curl -s -f -X POST '${RESTCONF_GW_URL}' -H 'Content-Type: application/json' -H 'X-Southbound-Target: ${sb_proto}' -d '{\"service-id\":\"qservice-m${mode_id}\",\"target-node-ip\":\"${TARGET_NODE_IP}\",\"ingress-port\":1,\"egress-port\":2,\"admin-state\":\"ENABLED\"}'")
        else
            t_conn=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --target ${TARGET_DEVICE} set --update '/interfaces/interface[name=eth1]/config/description:::string:::qservice-m${mode_id}-${sb_proto}'")
        fi

        # 2. Status 1
        if [ "$nb_proto" == "RESTCONF" ]; then
            t_stat1=$(time_exec "curl -s -f -X GET '${RESTCONF_GW_URL}?sb=${sb_proto}'")
        else
            t_stat1=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --target ${TARGET_DEVICE} get --path '/interfaces/interface[name=eth1]'")
        fi

        # 3. Disconnect
        if [ "$nb_proto" == "RESTCONF" ]; then
            t_disc=$(time_exec "curl -s -f -X DELETE '${RESTCONF_GW_URL}?service-id=qservice-m${mode_id}&sb=${sb_proto}'")
        else
            t_disc=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --target ${TARGET_DEVICE} set --delete '/interfaces/interface[name=eth1]/config/description'")
        fi

        # 4. Status 2
        if [ "$nb_proto" == "RESTCONF" ]; then
            t_stat2=$(time_exec "curl -s -X GET '${RESTCONF_GW_URL}?sb=${sb_proto}'")
        else
            t_stat2=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --target ${TARGET_DEVICE} get --path '/interfaces/interface[name=eth1]'")
        fi

        t_total=0
        for val in "$t_conn" "$t_stat1" "$t_disc" "$t_stat2"; do
            if [[ "$val" =~ ^[0-9]+$ ]]; then
                t_total=$((t_total + val))
            fi
        done

        echo "Connect=${t_conn}ms | Total=${t_total}ms"

        conn_list="${conn_list} ${t_conn}"
        stat1_list="${stat1_list} ${t_stat1}"
        disc_list="${disc_list} ${t_disc}"
        stat2_list="${stat2_list} ${t_stat2}"
        total_list="${total_list} ${t_total}"
    done

    IFS='|' read -r conn_avg conn_sd conn_min conn_max <<< "$(calc_stats $conn_list)"
    IFS='|' read -r stat1_avg stat1_sd stat1_min stat1_max <<< "$(calc_stats $stat1_list)"
    IFS='|' read -r disc_avg disc_sd disc_min disc_max <<< "$(calc_stats $disc_list)"
    IFS='|' read -r stat2_avg stat2_sd stat2_min stat2_max <<< "$(calc_stats $stat2_list)"
    IFS='|' read -r total_avg total_sd total_min total_max <<< "$(calc_stats $total_list)"

    echo "${mode_id}|${mode_name}|${conn_avg}±${conn_sd}|${stat1_avg}±${stat1_sd}|${disc_avg}±${disc_sd}|${stat2_avg}±${stat2_sd}|${total_avg}±${total_sd}|[${total_min}-${total_max}]" >> "$SUMMARY_FILE"
    echo ""
}

# Original Benchmark Modes
run_lifecycle_benchmark "1" "RESTCONF -> NETCONF" "RESTCONF" "NETCONF"
run_lifecycle_benchmark "2" "RESTCONF -> gNOI"    "RESTCONF" "gNOI"
run_lifecycle_benchmark "3" "gNMI -> NETCONF"     "gNMI"     "NETCONF"
run_lifecycle_benchmark "4" "gNMI -> gNOI"        "gNMI"     "gNOI"

# Native gNMI Baseline Modes
run_lifecycle_benchmark "5" "gNMI -> gNMI"        "gNMI"     "gNMI"
run_lifecycle_benchmark "6" "RESTCONF -> gNMI"    "RESTCONF" "gNMI"

echo "========================================================================================================================="
echo "                                SDN PROTOCOL BENCHMARK STATISTICAL SUMMARY (${ITERATIONS} Runs)                             "
echo "========================================================================================================================="
printf "%-7s | %-20s | %-12s | %-12s | %-12s | %-12s | %-14s | %-12s\n" "Mode" "Path" "Connect (ms)" "Status-1(ms)" "Disc. (ms)" "Status-2(ms)" "Total (ms)" "Range (ms)"
echo "-------------------------------------------------------------------------------------------------------------------------"

while IFS='|' read -r mid mname tc ts1 td ts2 tt tr; do
    printf "%-7s | %-20s | %-12s | %-12s | %-12s | %-12s | %-14s | %-12s\n" "Mode ${mid}" "${mname}" "${tc}" "${ts1}" "${td}" "${ts2}" "${tt}" "${tr}"
done < "$SUMMARY_FILE"
echo "========================================================================================================================="
