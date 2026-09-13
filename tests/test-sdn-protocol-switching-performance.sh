#!/usr/bin/env bash

set -eo pipefail

ITERATIONS="${1:-5}"
TARGET_DEVICE="${TARGET_DEVICE:-quantum-node-1}"
TARGET_NODE_IP="${TARGET_NODE_IP:-10.0.0.254}"

CONTROLLER_HOST="10.0.0.2"
RESTCONF_GW_URL="${RESTCONF_GW_URL:-http://localhost:8181/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service}"
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
    if eval "$cmd" >/tmp/nb_cmd_last_error.log 2>&1; then
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
    if command -v kubectl >/dev/null 2>&1; then
        echo "[*] Ensuring topology entity and aspects exist for ${TARGET_DEVICE}..."
        
        local gnmi_addr=""
        local netconf_addr=""

        if [ "${TARGET_DEVICE}" == "devicesim-1" ] || [ "${TARGET_NODE_IP}" == "devicesim-1" ]; then
            gnmi_addr="devicesim-1.micro-onos.svc.cluster.local:10161"
            netconf_addr="devicesim-1.micro-onos.svc.cluster.local:8300"
        elif [ "${TARGET_DEVICE}" == "quantum-node-1" ] || [ "${TARGET_NODE_IP}" == "quantum-node-1" ] || [ "${TARGET_NODE_IP}" == "10.0.0.254" ]; then
            gnmi_addr="10.0.0.254:50051"
            netconf_addr="10.0.0.254:8300"
        else
            gnmi_addr="${TARGET_NODE_IP}:50051"
            netconf_addr="${TARGET_NODE_IP}:8300"
        fi

        kubectl exec -n micro-onos deployment/onos-cli -- onos topo create entity "${TARGET_DEVICE}" -k "devicesim" >/dev/null 2>&1 || true
        kubectl exec -n micro-onos deployment/onos-cli -- onos topo set entity "${TARGET_DEVICE}" \
          -a gnmi_address="${gnmi_addr}" \
          -a gnoi_address="${gnmi_addr}" \
          -a netconf_address="${netconf_addr}" \
          -a onos.topo.TLSOptions='{"insecure":true,"plain":true}' \
          -a onos.topo.Configurable="{\"address\":\"${gnmi_addr}\",\"type\":\"devicesim\",\"version\":\"1.0.x\"}" >/dev/null 2>&1 || true
        
        sleep 2
    fi
}

run_lifecycle_benchmark() {
    local mode_id="$1" mode_name="$2" nb_proto="$3" sb_proto="$4"
    echo "=================================================================="
    echo "  Running Benchmark Mode ${mode_id}: ${mode_name} (${ITERATIONS} Status Reads)"
    echo "  Target: ${TARGET_DEVICE} (${TARGET_NODE_IP})"
    echo "=================================================================="

    if [ "$nb_proto" == "gNMI" ] || [ "$sb_proto" == "gNMI" ]; then
        ensure_gnmi_topo_aspect
    fi

    local stat_list=""
    local service_desc="qservice-m${mode_id}-${sb_proto}"

    # Connect Phase (Executed Once)
    echo -n "[*] Connecting... "
    if [ "$nb_proto" == "RESTCONF" ]; then
        t_conn=$(time_exec "curl -s -X POST '${RESTCONF_GW_URL}' -H 'Content-Type: application/json' -H 'X-Southbound-Target: ${sb_proto}' -d '{\"service-id\":\"qservice-m${mode_id}\",\"target-node\":\"${TARGET_DEVICE}\",\"target-node-ip\":\"${TARGET_NODE_IP}\",\"ingress-port\":1,\"egress-port\":2,\"admin-state\":\"ENABLED\",\"name\":\"eth1\",\"description\":\"${service_desc}\"}'")
    else
        t_conn=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --timeout 5s --target ${TARGET_DEVICE} set --update '/interfaces/interface[name=eth1]/config/name:::string:::eth1' --update '/interfaces/interface[name=eth1]/config/description:::string:::${service_desc}'")
    fi
    echo "${t_conn}ms"

    # Status Iteration Phase
    for ((i=1; i<=ITERATIONS; i++)); do        
        if [ "$nb_proto" == "RESTCONF" ]; then
            t_stat=$(time_exec "curl -s -f -X GET '${RESTCONF_GW_URL}?sb=${sb_proto}'")
        else
            t_stat=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --timeout 5s --target ${TARGET_DEVICE} get --path '/interfaces/interface[name=eth1]'")
        fi
        
        echo -ne "\r[*] Status Read Iteration ${i}/${ITERATIONS}... ${t_stat}ms\033[K"
        stat_list="${stat_list} ${t_stat}"
        
        # Reasonable sleep between status queries (not counted in time_exec)
        sleep 1
    done
    echo "" # Move to a fresh line when status iterations complete
    
    # Disconnect Phase (Executed Once)
    echo -n "[*] Disconnecting... "
    if [ "$nb_proto" == "RESTCONF" ]; then
        t_disc=$(time_exec "curl -s -f -X DELETE '${RESTCONF_GW_URL}' -H 'Content-Type: application/json' -H 'X-Southbound-Target: ${sb_proto}' -d '{\"service-id\":\"qservice-m${mode_id}\",\"target-node\":\"${TARGET_DEVICE}\"}'")
    else
        t_disc=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --timeout 5s --target ${TARGET_DEVICE} set --delete '/interfaces/interface[name=eth1]/config/description'")
    fi
    echo "${t_disc}ms"

    # Calculate statistics for the looped status reads
    IFS='|' read -r stat_avg stat_sd stat_min stat_max <<< "$(calc_stats $stat_list)"

    echo "${mode_id}|${mode_name}|${t_conn}|${stat_avg}±${stat_sd}|${t_disc}|[${stat_min}-${stat_max}]" >> "$SUMMARY_FILE"
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

echo "=========================================================================================================="
echo "                           SDN PROTOCOL BENCHMARK STATISTICAL SUMMARY (${ITERATIONS} Status Reads)        "
echo "=========================================================================================================="
printf "%-7s | %-20s | %-12s | %-16s | %-12s | %-12s\n" "Mode" "Path" "Connect (ms)" "Status Avg (ms)" "Disc. (ms)" "Stat Range(ms)"
echo "----------------------------------------------------------------------------------------------------------"

while IFS='|' read -r mid mname tc ts_stats td tr; do
    printf "%-7s | %-20s | %-12s | %-16s | %-12s | %-12s\n" "Mode ${mid}" "${mname}" "${tc}" "${ts_stats}" "${td}" "${tr}"
done < "$SUMMARY_FILE"
echo "=========================================================================================================="
