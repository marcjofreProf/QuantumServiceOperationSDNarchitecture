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

# Set Python binary path to use virtual environment if available
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
vals = [float(n) for n in re.findall(r"\d+\.?\d*", raw_input) if n]

if not vals:
    print("0.0|0.0|0.0|0.0")
else:
    avg = sum(vals) / len(vals)
    std = math.sqrt(sum((x - avg) ** 2 for x in vals) / len(vals))
    print(f"{avg:.1f}|{std:.1f}|{min(vals):.1f}|{max(vals):.1f}")
' "$@"
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

    #if [ "$nb_proto" == "gNMI" ] || [ "$sb_proto" == "gNMI" ]; then
    #    ensure_gnmi_topo_aspect
    #fi

    local stat_list=""
    local t_warmup="0"
    local service_desc="qservice-m${mode_id}-${sb_proto}"

    # Connect Phase (Executed Once)
    echo -n "[*] Connecting... "
    if [ "$nb_proto" == "RESTCONF" ]; then
        t_conn=$(time_exec "curl -s -X POST '${RESTCONF_GW_URL}' -H 'Content-Type: application/json' -H 'X-Southbound-Target: ${sb_proto}' -d '{\"service-id\":\"qservice-m${mode_id}\",\"target-node\":\"${TARGET_DEVICE}\",\"target-node-ip\":\"${TARGET_NODE_IP}\",\"ingress-port\":1,\"egress-port\":2,\"admin-state\":\"ENABLED\",\"name\":\"eth1\",\"description\":\"${service_desc}\"}'")
    else
        #t_conn=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --timeout 5s --target ${TARGET_DEVICE} set --update '/interfaces/interface[name=eth1]/config/name:::string:::eth1' --update '/interfaces/interface[name=eth1]/config/description:::string:::${service_desc}'")
        t_conn=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --timeout 5s --target ${TARGET_DEVICE} set --update '/interfaces/interface[name=eth1]/config/description:::string:::${service_desc}'")
    fi
    echo "${t_conn}ms"
    
    # Status Iteration Phase
    INTERVAL=${INTERVAL:-0.5}  # Default 0.5s, override via INTERVAL env var

    if [ "$nb_proto" == "RESTCONF" ]; then
        # Warmup read (measured and recorded)
        t_warmup=$(time_exec "curl -s -f -X GET '${RESTCONF_GW_URL}?sb=${sb_proto}'")
        echo "[*] Warm-up Read... ${t_warmup}ms"

        for ((i=1; i<=ITERATIONS; i++)); do
            t_stat=$(time_exec "curl -s -f -X GET '${RESTCONF_GW_URL}?sb=${sb_proto}'")
            stat_list="${stat_list} ${t_stat}"
            
            running_avg=$(python3 -c "vals=[float(x) for x in '${stat_list}'.split() if x]; print(f'{sum(vals)/len(vals):.1f}')" 2>/dev/null || echo "$t_stat")
            echo -ne "\r[*] Status Read Iteration ${i}/${ITERATIONS}... ${t_stat}ms (Avg: ${running_avg}ms)\033[K"
            
            sleep "$INTERVAL"
        done
        echo ""
    else
        # Persistent gNMI Session via inline Python
        gnmi_raw="$($PYTHON_BIN - "$ONOS_GNMI_TARGET" "$TARGET_DEVICE" "$ITERATIONS" "$INTERVAL" << 'PYEOF'
import sys, time, warnings, logging

# Suppress SSL/TLS and pygnmi library warnings from leaking into output streams
warnings.filterwarnings('ignore')
logging.disable(logging.CRITICAL)

target = sys.argv[1]
device = sys.argv[2]
iterations = int(sys.argv[3])
interval = float(sys.argv[4]) if len(sys.argv) > 4 else 0.5
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

    # Warmup read (measured and recorded)
    t_w0 = time.perf_counter()
    try:
        _ = gc.get(path=['/interfaces/interface[name=eth1]'], target=device)
        warmup_ms = (time.perf_counter() - t_w0) * 1000
    except Exception:
        warmup_ms = 0.0
        
    sys.stderr.write(f"[*] Warm-up Read... {warmup_ms:.1f}ms\n")
    sys.stderr.flush()

    timings = []
    
    for i in range(1, iterations + 1):
        t_start = time.perf_counter()
        
        try:
            _ = gc.get(path=['/interfaces/interface[name=eth1]'], target=device)
            elapsed = (time.perf_counter() - t_start) * 1000
            timings.append(f"{elapsed:.1f}")
            
            running_avg = sum(float(x) for x in timings) / len(timings)
            sys.stderr.write(f"\r[*] Persistent gNMI Read Iteration {i}/{iterations}... {elapsed:.1f}ms (Avg: {running_avg:.1f}ms)\033[K")
        except Exception as req_err:
            sys.stderr.write(f"\n[!] Read error on iteration {i}: {req_err}\n")
            
        sys.stderr.flush()
        
        if i < iterations:
            work_duration = time.perf_counter() - t_start
            sleep_time = max(0.0, interval - work_duration)
            time.sleep(sleep_time)

    gc.close()
    sys.stderr.write("\n")
    print(f"{warmup_ms:.1f}|" + " ".join(timings))
except Exception as e:
    sys.stderr.write(f"\n[!] gNMI Python Fatal Exception: {e}\n")
    print("FALLBACK")
PYEOF
)"
        # Extract strictly the pipe-delimited output line to protect against stray stdout
        gnmi_line="$(echo "$gnmi_raw" | grep '|' | tail -n 1)"

        if [ "$gnmi_line" != "FALLBACK" ] && [ -n "$gnmi_line" ]; then
            t_warmup="$(echo "$gnmi_line" | cut -d'|' -f1)"
            stat_list="$(echo "$gnmi_line" | cut -d'|' -f2)"
        else
            # Warmup read for gnmic fallback
            t_warmup=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --timeout 5s --target ${TARGET_DEVICE} get --path '/interfaces/interface[name=eth1]'")
            echo "[*] Warm-up Read... ${t_warmup}ms"

            for ((i=1; i<=ITERATIONS; i++)); do
                t_stat=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --timeout 5s --target ${TARGET_DEVICE} get --path '/interfaces/interface[name=eth1]'")
                stat_list="${stat_list} ${t_stat}"
                
                running_avg=$(python3 -c "vals=[float(x) for x in '${stat_list}'.split() if x]; print(f'{sum(vals)/len(vals):.1f}')" 2>/dev/null || echo "$t_stat")
                echo -ne "\r[*] Status Read Iteration ${i}/${ITERATIONS}... ${t_stat}ms (Avg: ${running_avg}ms)\033[K"
                
                sleep "$INTERVAL"
            done
            echo ""
        fi
    fi

    # Disconnect Phase (Executed Once)
    echo -n "[*] Disconnecting... "
    if [ "$nb_proto" == "RESTCONF" ]; then
        t_disc=$(time_exec "curl -s -f -X DELETE '${RESTCONF_GW_URL}' -H 'Content-Type: application/json' -H 'X-Southbound-Target: ${sb_proto}' -d '{\"service-id\":\"qservice-m${mode_id}\",\"target-node\":\"${TARGET_DEVICE}\"}'")
    else
        #t_disc=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --timeout 5s --target ${TARGET_DEVICE} set --delete '/interfaces/interface[name=eth1]/config/description'")
        t_disc=$(time_exec "gnmic -a ${ONOS_GNMI_TARGET} --tls-cert /etc/onos/certs/tls.crt --tls-key /etc/onos/certs/tls.key --skip-verify --timeout 5s --target ${TARGET_DEVICE} set --update '/interfaces/interface[name=eth1]/config/description:::string:::disabled'")
    fi
    echo "${t_disc}ms"

    # Calculate statistics for the looped status reads
    IFS='|' read -r stat_avg stat_sd stat_min stat_max <<< "$(calc_stats $stat_list)"

    echo "${mode_id}|${mode_name}|${t_conn}|${t_warmup}|${stat_avg}±${stat_sd}|${t_disc}|[${stat_min}-${stat_max}]" >> "$SUMMARY_FILE"
    echo ""
}

# Original Benchmark Modes
run_lifecycle_benchmark "1" "RESTCONF -> NETCONF" "RESTCONF" "NETCONF"
run_lifecycle_benchmark "2" "RESTCONF -> gNOI"    "RESTCONF" "gNOI"
run_lifecycle_benchmark "3" "gNMI -> NETCONF"     "gNMI"     "NETCONF"
run_lifecycle_benchmark "4" "gNMI -> gNOI"        "gNMI"     "gNOI"
run_lifecycle_benchmark "5" "gNMI -> gNMI"        "gNMI"     "gNMI"
run_lifecycle_benchmark "6" "RESTCONF -> gNMI"    "RESTCONF" "gNMI"

echo "===================================================================================================================="
echo "                               SDN PROTOCOL BENCHMARK STATISTICAL SUMMARY (${ITERATIONS} Status Reads)             "
echo "===================================================================================================================="
printf "%-7s | %-20s | %-12s | %-12s | %-16s | %-10s | %-12s\n" "Mode" "Path" "Connect(ms)" "Warmup(ms)" "Status Avg (ms)" "Disc.(ms)" "Stat Range(ms)"
echo "--------------------------------------------------------------------------------------------------------------------"

while IFS='|' read -r mid mname tc tw ts_stats td tr; do
    printf "%-7s | %-20s | %-12s | %-12s | %-16s | %-10s | %-12s\n" "Mode ${mid}" "${mname}" "${tc}" "${tw}" "${ts_stats}" "${td}" "${tr}"
done < "$SUMMARY_FILE"
echo "===================================================================================================================="
