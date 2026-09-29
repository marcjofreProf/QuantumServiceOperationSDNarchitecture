#!/usr/bin/env bash

set -eo pipefail

ITERATIONS="${1:-5}"
INTERVAL="${INTERVAL:-0.5}"

# -----------------------------------------------------------------------------
# Deployment configuration
#
# Load the shared config written by the bootstraps so the controller IP and
# node identity are consistent across the three repositories. Values already
# set in the environment win over the config file, so per-run overrides
# (TARGET_DEVICE=... TARGET_NODE_IP=... ./test-...) still work as before.
# -----------------------------------------------------------------------------
QUANTUM_SDN_CONF="${HOME}/.quantum-sdn/config.env"
if [ -f "$QUANTUM_SDN_CONF" ]; then
    while IFS='=' read -r k v; do
        case "$k" in ''|\#*) continue ;; esac
        if [ -z "${!k:-}" ]; then
            printf -v "$k" '%s' "$v"
            export "$k"
        fi
    done < "$QUANTUM_SDN_CONF"
fi

TARGET_DEVICE="${TARGET_DEVICE:-${QUANTUM_NODE_ID:-quantum-node-1}}"
TARGET_NODE_IP="${TARGET_NODE_IP:-${QUANTUM_NODE_IP:-172.21.128.254}}"

# If TARGET_NODE_IP was set to something that is not a dotted-quad IP
# (typically the topo entity name, per the historical convention
# "TARGET_DEVICE=X TARGET_NODE_IP=X ./test-..."), fall back to the
# configured node IP. The gateway would otherwise forward a hostname
# to the southbound adapter, which cannot resolve it inside the
# cluster.
if [[ ! "$TARGET_NODE_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    RESOLVED="${QUANTUM_NODE_IP:-172.21.128.254}"
    echo "[*] TARGET_NODE_IP='${TARGET_NODE_IP}' is not an IP; using '${RESOLVED}'"
    TARGET_NODE_IP="${RESOLVED}"
fi

# -----------------------------------------------------------------------------
# gNMI target selection
#
#   ONOS_GNMI_TARGET_MODE=controller   (default)
#       The daemon connects to onos-config:5150 over mTLS, and onos-config
#       re-emits the request southbound to the target device. This measures
#       the full µONOS control plane (validation + transaction + Raft +
#       southbound push). Slower, but representative of the real deployment.
#
#   ONOS_GNMI_TARGET_MODE=direct
#       The daemon connects straight to the target's own gNMI server
#       (TARGET_DEVICE_GNMI_ADDR, default 10.0.0.254:50051) in plaintext.
#       This measures only the device + the northbound protocol. Faster,
#       and comparable to the RESTCONF gateway modes.
#
# Override the target's own gNMI endpoint with TARGET_DEVICE_GNMI_ADDR.
# -----------------------------------------------------------------------------
ONOS_GNMI_TARGET_MODE="${ONOS_GNMI_TARGET_MODE:-controller}"

# CONTROLLER_HOST is set above from the config file (default 172.21.2.23).
# The fallback below only fires if the file does not exist and the shell
# did not export a value.
CONTROLLER_HOST="${CONTROLLER_HOST:-172.21.2.23}"

# The node's own gNMI endpoint, used only in direct mode. It is derived
# from the node IP loaded above so a single config drives both the
# topo entity name and the direct connection target.
TARGET_DEVICE_GNMI_ADDR="${TARGET_DEVICE_GNMI_ADDR:-${QUANTUM_NODE_IP:-172.21.128.254}:50051}"
# --- Southbound confirmation ---
SB_CONFIRM_MODE="${SB_CONFIRM_MODE:-warn}"        # off | warn | strict
SB_CONFIRM_TIMEOUT_MS="${SB_CONFIRM_TIMEOUT_MS:-5000}"
SB_CONFIRM_POLL_MS="${SB_CONFIRM_POLL_MS:-50}"
SB_GNMI_TARGET="${SB_GNMI_TARGET:-${TARGET_NODE_IP}:50051}"
SB_GNOI_TARGET="${SB_GNOI_TARGET:-${TARGET_NODE_IP}:50051}"
SB_NETCONF_HOST="${SB_NETCONF_HOST:-${TARGET_NODE_IP}}"
SB_NETCONF_PORT="${SB_NETCONF_PORT:-8300}"

case "$ONOS_GNMI_TARGET_MODE" in
    controller)
        ONOS_GNMI_TARGET="${CONTROLLER_HOST}:5150"
        GNMI_TLS_MODE="mtls"     # daemon uses client1.crt/key + tls.cacrt
        ;;
    direct)
        ONOS_GNMI_TARGET="${TARGET_DEVICE_GNMI_ADDR}"
        GNMI_TLS_MODE="plain"    # daemon uses an insecure channel
        ;;
    *)
        echo "[!] ERROR: ONOS_GNMI_TARGET_MODE must be 'controller' or 'direct' (got '$ONOS_GNMI_TARGET_MODE')"
        exit 1
        ;;
esac

# RESTCONF gateway address.
# Default assumes a kubectl port-forward is active (kubectl port-forward -n micro-onos svc/restconf-gateway 8181:8181).
# Alternative: use the LoadBalancer IP directly, e.g. http://172.28.32.106:8181/...
RESTCONF_GW_URL="${RESTCONF_GW_URL:-http://${CONTROLLER_HOST}:8181/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service}"

RESULTS_FILE="/tmp/sdn_benchmark_raw.txt"
SUMMARY_FILE="/tmp/sdn_benchmark_summary.txt"
FIFO_IN="/tmp/gnmi_fifo_in_$$"
FIFO_OUT="/tmp/gnmi_fifo_out_$$"
FIFO_SB_IN="/tmp/gnmi_sb_fifo_in_$$"
FIFO_SB_OUT="/tmp/gnmi_sb_fifo_out_$$"
GNMI_DEBUG_LOG="/tmp/gnmi_debug.log"

rm -f "$RESULTS_FILE" "$SUMMARY_FILE" "$FIFO_IN" "$FIFO_OUT" \
      "$FIFO_SB_IN" "$FIFO_SB_OUT" "$GNMI_DEBUG_LOG"

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
echo "  gNMI target mode: ${ONOS_GNMI_TARGET_MODE}"
echo "  gNMI endpoint:    ${ONOS_GNMI_TARGET}"
echo "  gNMI TLS mode:    ${GNMI_TLS_MODE}"
echo "=================================================================="

# 1. Python interpreter
if [ ! -x "$PYTHON_BIN" ]; then
    echo "[!] ERROR: Python interpreter not found or not executable: $PYTHON_BIN"
    preflight_failed=1
else
    echo "    [OK] Python: $PYTHON_BIN"
fi

# 2. gNMI stubs (daemon imports gnmi_pb2 / gnmi_pb2_grpc)
if [ "$preflight_failed" -eq 0 ]; then
    if ! "$PYTHON_BIN" -c "import sys; sys.path.insert(0, 'proto'); import gnmi_pb2, gnmi_pb2_grpc" >/dev/null 2>&1; then
        echo "[!] ERROR: gNMI stubs (gnmi_pb2 / gnmi_pb2_grpc) are not importable."
        echo "    Run the bootstrap to generate them:"
        echo "      ./bootstrap-oss-terminal.sh"
        preflight_failed=1
    else
        echo "    [OK] gNMI stubs importable"
    fi
fi

# 3. Client certs — only required when talking to onos-config (mTLS).
if [ "$GNMI_TLS_MODE" = "mtls" ]; then
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

    # Cert subject sanity check: the client cert must NOT have the server's CN.
    if [ -f /etc/onos/certs/client1.crt ]; then
        cn=$(openssl x509 -in /etc/onos/certs/client1.crt -noout -subject 2>/dev/null \
             | sed -n 's/.*CN *= *\([^,]*\).*/\1/p')
        if [ -z "$cn" ]; then
            echo "[!] ERROR: could not read subject from /etc/onos/certs/client1.crt"
            preflight_failed=1
        elif [[ "$cn" == onos-config* ]]; then
            echo "[!] ERROR: /etc/onos/certs/client1.crt has CN='$cn', which is the SERVER cert, not a client cert."
            preflight_failed=1
        else
            echo "    [OK] client1.crt subject CN=$cn"
        fi

        # Chain check: the client cert must be signed by the local CA.
        if ! openssl verify -CAfile /etc/onos/certs/tls.cacrt \
                            /etc/onos/certs/client1.crt >/dev/null 2>&1; then
            echo "[!] ERROR: client1.crt is NOT signed by tls.cacrt"
            echo "    The client identity does not belong to the CA that onos-config trusts."
            echo "    Re-copy the cert triplet, e.g.:"
            echo "      sudo cp .certs/uonos/client1.crt /etc/onos/certs/client1.crt"
            echo "      sudo cp .certs/uonos/client1.key /etc/onos/certs/client1.key"
            echo "      sudo cp .certs/uonos/tls.cacrt  /etc/onos/certs/tls.cacrt"
            preflight_failed=1
        else
            echo "    [OK] client1.crt verifies against tls.cacrt"
        fi
    fi
else
    echo "    [--] plaintext mode: skipping cert checks"
fi

# 4. Reachability of the chosen gNMI endpoint
GNMI_HOST="${ONOS_GNMI_TARGET%%:*}"
GNMI_PORT="${ONOS_GNMI_TARGET##*:}"
if nc -z "$GNMI_HOST" "$GNMI_PORT" 2>/dev/null; then
    echo "    [OK] TCP ${ONOS_GNMI_TARGET} reachable"
else
    echo "[!] ERROR: cannot reach ${ONOS_GNMI_TARGET}"
    preflight_failed=1
fi

# 4b. Southbound probe endpoints
if [ "$SB_CONFIRM_MODE" = "off" ]; then
    echo "    [--] SB confirmation disabled (SB_CONFIRM_MODE=off)"
else
    for ep in "$SB_GNMI_TARGET" "$SB_GNOI_TARGET"; do
        h="${ep%%:*}"; p="${ep##*:}"
        if nc -z "$h" "$p" 2>/dev/null; then
            echo "    [OK] SB probe endpoint ${ep} reachable"
        else
            echo "    [--] SB probe endpoint ${ep} unreachable"
        fi
    done
    if nc -z "$SB_NETCONF_HOST" "$SB_NETCONF_PORT" 2>/dev/null; then
        echo "    [OK] SB probe endpoint ${SB_NETCONF_HOST}:${SB_NETCONF_PORT} reachable"
    else
        echo "    [--] SB probe endpoint ${SB_NETCONF_HOST}:${SB_NETCONF_PORT} unreachable"
    fi
fi

# 5. RESTCONF gateway (informational only)
# Probe the real data URL the benchmark uses, and treat any HTTP reply
# (1xx–5xx) as "reachable". A 404/405 on /restconf/ root is normal and
# does NOT mean the gateway is down.
RESTCONF_PROBE_URL="${RESTCONF_GW_URL}"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$RESTCONF_PROBE_URL" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" =~ ^[1-5][0-9][0-9]$ ]]; then
    echo "    [OK] RESTCONF gateway reachable at ${RESTCONF_PROBE_URL} (HTTP ${HTTP_CODE})"
else
    echo "    [--] RESTCONF gateway not reachable at ${RESTCONF_PROBE_URL} (HTTP ${HTTP_CODE})"
    echo "         Modes 1, 2 and 6 will fail; modes 3, 4, 5 can still run."
fi

if [ "$preflight_failed" -ne 0 ]; then
    echo
    echo "[!] Pre-flight checks failed. Aborting."
    exit 1
fi

echo "    All required pre-flight checks passed."
echo

# Build the payload fields. TARGET_DEVICE and TARGET_NODE_IP are already
# resolved (config file → shell → default), so no hostname-to-IP mapping
# is needed anymore. The gateway and onos-config both accept the topo
# entity name in `target-node` and the plain IP in `target-node-ip`.
PAYLOAD_NODE_IP="${TARGET_NODE_IP}"
PAYLOAD_TARGET_DEVICE="${TARGET_DEVICE}"

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
import sys, math

raw_input = " ".join(sys.argv[1:])
tokens = [t for t in raw_input.split() if t]
vals = []
failures = 0
for t in tokens:
    if t in ("FAILED", "TIMEOUT", "ERR", "-", "DEAD") or t.startswith("ERROR"):
        failures += 1
        continue
    try:
        vals.append(float(t))
    except ValueError:
        failures += 1

if not vals:
    print("FAIL|FAIL|FAIL|FAIL")
elif failures:
    avg = sum(vals) / len(vals)
    print(f"{avg:.1f}|FAIL|{min(vals):.1f}|{max(vals):.1f}")
else:
    avg = sum(vals) / len(vals)
    std = math.sqrt(sum((x - avg) ** 2 for x in vals) / len(vals))
    print(f"{avg:.1f}|{std:.1f}|{min(vals):.1f}|{max(vals):.1f}")
' "$@"
}

# --- PERSISTENT gNMI DAEMON SETUP ---

PY_DAEMON_SCRIPT="./tests/gnmi_daemon.py"

mkfifo "$FIFO_IN" "$FIFO_OUT"

# Launch the daemon. It receives three arguments:
#   $1 = target endpoint (host:port)
#   $2 = target device name (for the gNMI Path.target field)
#   $3 = TLS mode: "mtls" or "plain"
$PYTHON_BIN "$PY_DAEMON_SCRIPT" "$ONOS_GNMI_TARGET" "$TARGET_DEVICE" "$GNMI_TLS_MODE" < "$FIFO_IN" > "$FIFO_OUT" &
DAEMON_PID=$!

# Open file descriptors on the created FIFOs
exec 3> "$FIFO_IN"
exec 4< "$FIFO_OUT"

SB_DAEMON_PID=""

cleanup() {
    echo "QUIT" >&3 2>/dev/null || true
    if [ -n "$SB_DAEMON_PID" ]; then
        echo "QUIT" >&5 2>/dev/null || true
    fi
    exec 3>&- 2>/dev/null || true
    exec 4<&- 2>/dev/null || true
    exec 5>&- 2>/dev/null || true
    exec 6<&- 2>/dev/null || true
    rm -f "$FIFO_IN" "$FIFO_OUT" "$FIFO_SB_IN" "$FIFO_SB_OUT"
    if [ -n "$DAEMON_PID" ]; then
        kill "$DAEMON_PID" 2>/dev/null || true
    fi
    if [ -n "$SB_DAEMON_PID" ]; then
        kill "$SB_DAEMON_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

sleep 2

# Check whether the daemon is still alive and whether it printed a FATAL line.
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
    local op_type="$1" val_arg="$2" sb_hint="${3:-}"
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        echo "FAILED"
        return
    fi
    echo "${op_type}|${val_arg}|${sb_hint}" >&3
    local res
    read -r res <&4 || res="FAILED"
    if [[ "$res" == FATAL* ]]; then
        echo "[!] gNMI daemon reported: ${res#FATAL|}" >&2
        echo "FAILED"
        return
    fi
    echo "$res"
}


# --- SB probe lifecycle -------------------------------------------------

SB_EXPECT_CONNECT=""
SB_EXPECT_DISCONNECT=""

start_sb_probe() {
    local sb_proto="$1"
    SB_DAEMON_PID=""
    SB_EXPECT_CONNECT=""
    SB_EXPECT_DISCONNECT=""

    if [ "$SB_CONFIRM_MODE" = "off" ]; then return 0; fi

    local script args=()
    case "$sb_proto" in
        NETCONF) script="./tests/sb_probe_netconf.py"
                 args=("$SB_NETCONF_HOST" "$SB_NETCONF_PORT")
                 SB_EXPECT_CONNECT="true"; SB_EXPECT_DISCONNECT="false" ;;
        gNOI)    script="./tests/sb_probe_gnoi.py"
                 args=("$SB_GNOI_TARGET")
                 SB_EXPECT_CONNECT="true"; SB_EXPECT_DISCONNECT="false" ;;
        gNMI)    script="./tests/sb_probe.py"
                 args=("$SB_GNMI_TARGET")
                 SB_EXPECT_CONNECT="enabled"; SB_EXPECT_DISCONNECT="disabled" ;;
        *)       echo "[!] unknown sb_proto '$sb_proto'" >&2
                 SB_CONFIRM_MODE="off"; return 0 ;;
    esac

    if [ ! -f "$script" ]; then
        echo "[!] $script not found; disabling SB confirmation" >&2
        SB_CONFIRM_MODE="off"; return 0
    fi

    mkfifo "$FIFO_SB_IN" "$FIFO_SB_OUT"
    local sb_err="/tmp/sb_probe_err.$$"
    : > "$sb_err"
    "$PYTHON_BIN" "$script" "${args[@]}" \
        < "$FIFO_SB_IN" > "$FIFO_SB_OUT" 2> "$sb_err" &
    SB_DAEMON_PID=$!
    exec 5> "$FIFO_SB_IN"
    exec 6< "$FIFO_SB_OUT"

    sleep 2
    if ! kill -0 "$SB_DAEMON_PID" 2>/dev/null; then
        local msg; msg=$(head -n3 "$sb_err" 2>/dev/null | tr '\n' ' ' || true)
        echo "[!] SB probe failed to start: ${msg:-<no message>}" >&2
        exec 5>&- 2>/dev/null || true
        exec 6<&- 2>/dev/null || true
        rm -f "$FIFO_SB_IN" "$FIFO_SB_OUT" "$sb_err"
        SB_DAEMON_PID=""
        if [ "$SB_CONFIRM_MODE" = "strict" ]; then
            echo "[!] strict mode but probe is dead. Aborting." >&2
            exit 1
        fi
        SB_CONFIRM_MODE="off"
    fi
}

stop_sb_probe() {
    if [ -n "$SB_DAEMON_PID" ]; then
        echo "QUIT" >&5 2>/dev/null || true
        exec 5>&- 2>/dev/null || true
        exec 6<&- 2>/dev/null || true
        kill "$SB_DAEMON_PID" 2>/dev/null || true
        wait "$SB_DAEMON_PID" 2>/dev/null || true
        SB_DAEMON_PID=""
        rm -f "$FIFO_SB_IN" "$FIFO_SB_OUT" /tmp/sb_probe_err.$$
    fi
}

wait_sb_state() {
    local expected="$1"
    local timeout_ms="${2:-$SB_CONFIRM_TIMEOUT_MS}"
    if [ -z "$SB_DAEMON_PID" ] || [ -z "$expected" ]; then echo "-"; return 0; fi
    if ! kill -0 "$SB_DAEMON_PID" 2>/dev/null; then echo "DEAD"; return 0; fi
    local start_t end_t resp
    start_t=$(get_time_ms)
    while :; do
        echo "CHECK|${expected}" >&5
        if ! read -r resp <&6; then echo "ERROR|eof"; return 0; fi
        case "$resp" in
            PRESENT) end_t=$(get_time_ms); echo $((end_t - start_t)); return 0 ;;
            ABSENT)  : ;;
            ERROR*)  echo "ERR"; return 0 ;;
            *)       echo "ERROR|bad-response:${resp}"; return 0 ;;
        esac
        end_t=$(get_time_ms)
        if [ $((end_t - start_t)) -ge "$timeout_ms" ]; then echo "TIMEOUT"; return 0; fi
        $PYTHON_BIN -c "import time; time.sleep(${SB_CONFIRM_POLL_MS} / 1000.0)"
    done
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
        exec_gnmi_op "SET" "$service_desc" "$sb_proto"
    fi
}

exec_disconnect() {
    local mode_id="$1" nb_proto="$2" sb_proto="$3" service_id="$4"

    if [ "$nb_proto" == "RESTCONF" ]; then
        time_exec "curl -s -f -X DELETE '${RESTCONF_GW_URL}?sb=${sb_proto}' \
            -H 'Content-Type: application/json' \
            -H 'X-Southbound-Target: ${sb_proto}' \
            -d '{\"service-id\":\"${service_id}\",\"target-node\":\"${PAYLOAD_TARGET_DEVICE}\"}'"
    else
        exec_gnmi_op "SET" "disabled" "$sb_proto"
    fi
}

run_lifecycle_benchmark() {
    local mode_id="$1" mode_name="$2" nb_proto="$3" sb_proto="$4"
    echo "=================================================================="
    echo "  Running Benchmark Mode ${mode_id}: ${mode_name}"
    echo "  Target: ${TARGET_DEVICE} (${TARGET_NODE_IP}) | ${ITERATIONS} Full Trials"
    echo "=================================================================="

    start_sb_probe "$sb_proto"

    # 1. Unmeasured Pre-Warmup Run
    echo -n "[*] Pre-Warmup Lifecycle Run... "
    wp_conn=$(exec_connect "$mode_id" "$nb_proto" "$sb_proto" "warmup")
    check_step "Warmup Connect" "$wp_conn"

    if [ "$nb_proto" == "RESTCONF" ]; then
        wp_stat=$(time_exec "curl -s -f -X GET '${RESTCONF_GW_URL}?sb=${sb_proto}'")
    else
        wp_stat=$(exec_gnmi_op "GET" "" "$sb_proto")
    fi
    check_step "Warmup Status" "$wp_stat"

    wp_disc=$(exec_disconnect "$mode_id" "$nb_proto" "$sb_proto" "warmup")
    check_step "Warmup Disconnect" "$wp_disc"
    echo "Done (Conn: ${wp_conn}ms | Stat: ${wp_stat}ms | Disc: ${wp_disc}ms)"
    sleep 1

    # 2. Measured Iterations
    local conn_list="" stat_list="" disc_list="" total_list=""
    local sb_conn_list="" sb_disc_list="" e2e_list=""

    for ((i=1; i<=ITERATIONS; i++)); do
        local service_id="qservice-m${mode_id}-i${i}"

        t_conn=$(exec_connect "$mode_id" "$nb_proto" "$sb_proto" "$service_id")

        t_sb_conn=$(wait_sb_state "$SB_EXPECT_CONNECT")

        sleep 1 # added sleep to not carry over the measured times in the following process
        
        if [ "$nb_proto" == "RESTCONF" ]; then
            t_stat=$(time_exec "curl -s -f -X GET '${RESTCONF_GW_URL}?sb=${sb_proto}'")
        else
            t_stat=$(exec_gnmi_op "GET" "" "$sb_proto")
        fi

        sleep 1 # added sleep to not carry over the measured times in the following process

        t_disc=$(exec_disconnect "$mode_id" "$nb_proto" "$sb_proto" "$service_id")

        if [[ "$t_sb_conn" =~ ^[0-9]+$ ]]; then
            t_sb_disc=$(wait_sb_state "$SB_EXPECT_DISCONNECT")
        else
            # Connect never observed; still attempt to observe the
            # disconnect so we don't silently copy the TIMEOUT forward.
            t_sb_disc=$(wait_sb_state "$SB_EXPECT_DISCONNECT")
        fi

        sleep 1 # added sleep to not carry over the measured times in the following process
        
        local fail_total=0
        [ "$t_conn" = "FAILED" ] && fail_total=1
        [ "$t_stat" = "FAILED" ] && fail_total=1
        [ "$t_disc" = "FAILED" ] && fail_total=1
        if [ "$SB_CONFIRM_MODE" = "strict" ]; then
            case "$t_sb_conn" in TIMEOUT|ERROR*|eof) fail_total=1 ;; esac
            case "$t_sb_disc" in TIMEOUT|ERROR*|eof) fail_total=1 ;; esac
        fi
        if [ "$fail_total" -eq 0 ]; then
            t_total=$((t_conn + t_stat + t_disc))
        else
            t_total="FAILED"
        fi
        if [ "$fail_total" -eq 0 ] && \
           [[ "$t_sb_conn" =~ ^[0-9]+$ ]] && \
           [[ "$t_sb_disc" =~ ^[0-9]+$ ]]; then
            t_e2e=$((t_conn + t_stat + t_disc + t_sb_conn + t_sb_disc))
        else
            t_e2e="FAILED"
        fi

        conn_list="${conn_list} ${t_conn}"
        stat_list="${stat_list} ${t_stat}"
        disc_list="${disc_list} ${t_disc}"
        total_list="${total_list} ${t_total}"
        sb_conn_list="${sb_conn_list} ${t_sb_conn}"
        sb_disc_list="${sb_disc_list} ${t_sb_disc}"
        e2e_list="${e2e_list} ${t_e2e}"

        if [ -t 1 ]; then
            # Interactive: overwrite the same line with \r + right-pad to
            # erase any trailing characters from the previous longer line.
            printf "\r  [Trial %2d/%2d] Conn: %5sms | Stat: %5sms | Disc: %5sms | SB-C: %5sms | SB-D: %5sms | Total: %5sms" \
                "$i" "$ITERATIONS" "$t_conn" "$t_stat" "$t_disc" "$t_sb_conn" "$t_sb_disc" "$t_total"
        else
            printf "  [Trial %2d/%2d] Conn: %5sms | Stat: %5sms | Disc: %5sms | SB-C: %5sms | SB-D: %5sms | Total: %5sms\n" \
                "$i" "$ITERATIONS" "$t_conn" "$t_stat" "$t_disc" "$t_sb_conn" "$t_sb_disc" "$t_total"
        fi
        sleep "$INTERVAL"
    done

    # Move to a new line after the in-place bar finishes, so the next
    # mode's header starts cleanly.
    if [ -t 1 ]; then
        printf "\n"
    fi
    stop_sb_probe
    IFS='|' read -r c_avg c_sd c_min c_max <<< "$(calc_stats $conn_list)"
    IFS='|' read -r s_avg s_sd s_min s_max <<< "$(calc_stats $stat_list)"
    IFS='|' read -r d_avg d_sd d_min d_max <<< "$(calc_stats $disc_list)"
    IFS='|' read -r b_avg b_sd b_min b_max <<< "$(calc_stats $sb_conn_list)"
    IFS='|' read -r e_avg e_sd e_min e_max <<< "$(calc_stats $sb_disc_list)"
    IFS='|' read -r t_avg t_sd t_min t_max <<< "$(calc_stats $total_list)"
    IFS='|' read -r x_avg x_sd x_min x_max <<< "$(calc_stats $e2e_list)"

    echo "${mode_id}|${mode_name}|${c_avg}±${c_sd}|${s_avg}±${s_sd}|${d_avg}±${d_sd}|${b_avg}±${b_sd}|${e_avg}±${e_sd}|${t_avg}±${t_sd}" >> "$SUMMARY_FILE"
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
echo "                     gNMI target mode: ${ONOS_GNMI_TARGET_MODE} (${ONOS_GNMI_TARGET})"
echo "=========================================================================================================="
printf "%-7s | %-20s | %-13s | %-11s | %-13s | %-10s | %-10s | %-13s\n" \
    "Mode" "Path" "Connect (ms)" "Status (ms)" "Disconnect (ms)" "SB-C (ms)" "SB-D (ms)" "Total (ms)"
echo "--------------------------------------------------------------------------------------------------------------------------------------"

while IFS='|' read -r mid mname c_stat s_stat d_stat b_stat e_stat t_stat; do
    printf "%-7s | %-20s | %-13s | %-11s | %-13s | %-10s | %-10s | %-13s\n" \
        "Mode ${mid}" "${mname}" "${c_stat}" "${s_stat}" "${d_stat}" "${b_stat}" "${e_stat}" "${t_stat}"
done < "$SUMMARY_FILE"
echo "=========================================================================================================="
