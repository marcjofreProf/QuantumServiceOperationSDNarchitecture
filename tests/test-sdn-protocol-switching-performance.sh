#!/usr/bin/env bash
# tests/test-sdn-protocol-matrix-performance.sh
# Benchmarks execution time and performance across 4 NB/SB protocol combinations.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

CONTROLLER_IP="10.0.0.2"
RESTCONF_BASE="http://${CONTROLLER_IP}:8181/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service"
GRPC_TARGET="${CONTROLLER_IP}:50051"

# Temporary timing results storage
RESULTS_FILE="/tmp/sdn_benchmark_results.txt"
rm -f "$RESULTS_FILE"

# High-resolution time helper (returns epoch ms)
get_time_ms() {
    python3 -c 'import time; print(int(time.time() * 1000))'
}

# Measure execution time of a command string
time_exec() {
    local start_t end_t elapsed
    start_t=$(get_time_ms)
    eval "$1" >/dev/null 2>&1 || true
    end_t=$(get_time_ms)
    elapsed=$((end_t - start_t))
    echo "$elapsed"
}

run_lifecycle_benchmark() {
    local mode_id="$1"
    local mode_name="$2"
    local nb_proto="$3"
    local sb_proto="$4"

    echo "=================================================================="
    echo "  Running Benchmark Mode ${mode_id}: ${mode_name}"
    echo "=================================================================="

    local t_conn t_stat1 t_disc t_stat2 t_total

    # 1. Connect Phase
    echo "[*] [1/4] Executing CONNECT (${nb_proto} -> Controller -> ${sb_proto})..."
    if [ "$nb_proto" == "RESTCONF" ]; then
        t_conn=$(time_exec "curl -s -X POST '${RESTCONF_BASE}' -H 'Content-Type: application/json' -H 'X-Southbound-Target: ${sb_proto}' -d '{\"service-id\":\"qservice-mode-${mode_id}\",\"target-node-ip\":\"10.0.0.254\",\"ingress-port\":1,\"egress-port\":2,\"admin-state\":\"ENABLED\"}'")
    else
        t_conn=$(time_exec "grpcurl -plaintext -d '{\"service_id\":\"qservice-mode-${mode_id}\",\"target_node_ip\":\"10.0.0.254\",\"ingress_port\":1,\"egress_port\":2,\"admin_state\":\"ENABLED\",\"sb_target\":\"${sb_proto}\"}' ${GRPC_TARGET} quantum.gnoi.SwitchingService/CreateCrossConnect")
    fi

    # 2. Status Check Post-Connect
    echo "[*] [2/4] Executing STATUS CHECK (Post-Connect)..."
    if [ "$nb_proto" == "RESTCONF" ]; then
        t_stat1=$(time_exec "curl -s -X GET '${RESTCONF_BASE}?sb=${sb_proto}'")
    else
        t_stat1=$(time_exec "grpcurl -plaintext -d '{\"service_id\":\"qservice-mode-${mode_id}\",\"sb_target\":\"${sb_proto}\"}' ${GRPC_TARGET} quantum.gnoi.SwitchingService/GetCrossConnect")
    fi

    # 3. Disconnect Phase
    echo "[*] [3/4] Executing DISCONNECT (${nb_proto} -> Controller -> ${sb_proto})..."
    if [ "$nb_proto" == "RESTCONF" ]; then
        t_disc=$(time_exec "curl -s -X DELETE '${RESTCONF_BASE}?service-id=qservice-mode-${mode_id}&sb=${sb_proto}'")
    else
        t_disc=$(time_exec "grpcurl -plaintext -d '{\"service_id\":\"qservice-mode-${mode_id}\",\"sb_target\":\"${sb_proto}\"}' ${GRPC_TARGET} quantum.gnoi.SwitchingService/DeleteCrossConnect")
    fi

    # 4. Status Check Post-Disconnect
    echo "[*] [4/4] Executing STATUS CHECK (Post-Disconnect)..."
    if [ "$nb_proto" == "RESTCONF" ]; then
        t_stat2=$(time_exec "curl -s -X GET '${RESTCONF_BASE}?sb=${sb_proto}'")
    else
        t_stat2=$(time_exec "grpcurl -plaintext -d '{\"service_id\":\"qservice-mode-${mode_id}\",\"sb_target\":\"${sb_proto}\"}' ${GRPC_TARGET} quantum.gnoi.SwitchingService/GetCrossConnect")
    fi

    t_total=$((t_conn + t_stat1 + t_disc + t_stat2))

    echo "Mode ${mode_id} Results: Connect=${t_conn}ms | Status1=${t_stat1}ms | Disconnect=${t_disc}ms | Status2=${t_stat2}ms | Total=${t_total}ms"
    echo "${mode_id}|${mode_name}|${t_conn}|${t_stat1}|${t_disc}|${t_stat2}|${t_total}" >> "$RESULTS_FILE"
    echo ""
}

# Run All 4 Protocol Modes
run_lifecycle_benchmark "1" "RESTCONF -> NETCONF" "RESTCONF" "NETCONF"
run_lifecycle_benchmark "2" "RESTCONF -> gNOI"    "RESTCONF" "gNOI"
run_lifecycle_benchmark "3" "gNOI/gRPC -> NETCONF" "gRPC"     "NETCONF"
run_lifecycle_benchmark "4" "gNOI/gRPC -> gNOI"    "gRPC"     "gNOI"

# Print Final Performance Table
echo "=================================================================================================="
echo "                                   SDN PROTOCOL BENCHMARK SUMMARY                                "
echo "=================================================================================================="
printf "%-7s | %-20s | %-10s | %-10s | %-10s | %-10s | %-12s\n" "Mode" "Path" "Connect" "Status-1" "Disconnect" "Status-2" "Total Time"
echo "--------------------------------------------------------------------------------------------------"

while IFS='|' read -r mid mname tc ts1 td ts2 tt; do
    printf "%-7s | %-20s | %-8sms | %-8sms | %-8sms | %-8sms | %-10sms\n" "Mode ${mid}" "${mname}" "${tc}" "${ts1}" "${td}" "${ts2}" "${tt}"
done < "$RESULTS_FILE"

echo "=================================================================================================="
