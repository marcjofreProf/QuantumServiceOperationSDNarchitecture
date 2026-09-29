#!/usr/bin/env python3
"""
Persistent gNMI client for the SDN protocol benchmark.

Reads commands from stdin, one per line:
    SET|<value>|<sb-hint>
    GET||<sb-hint>
    QUIT
and writes back either a latency in milliseconds or FAILED.

Two connection modes are supported, selected by the third CLI argument:

  mtls   -- connect to onos-config over mTLS.
  plain  -- connect to a plaintext gNMI server directly.

The third field (<sb-hint>) selects the southbound transport:
  NETCONF / gNOI  ->  dispatched to sdn-adapter through the RESTCONF
                      gateway proxy on ${CONTROLLER_HOST}:8181.
  gNMI / empty    ->  dispatched to onos-config over the existing
                      mTLS channel (this is the original Mode 5 path).

Invocation:
    gnmi_daemon.py <host:port> <device-name> <mtls|plain> [device-ip]

Environment:
    CONTROLLER_HOST  host of the RESTCONF gateway LoadBalancer
                     (exported by the benchmark script from
                      ~/.quantum-sdn/config.env). Default: 10.0.0.2.
    GATEWAY_URL      full URL of the gateway. Overrides the above.
    GATEWAY_TIMEOUT  seconds per gateway call. Default: 15.
"""
import sys
import os
import time
import traceback
import json
import urllib.request
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
PROTO_DIR = os.path.abspath(os.path.join(HERE, "..", "proto"))
if PROTO_DIR not in sys.path:
    sys.path.insert(0, PROTO_DIR)

import grpc
import gnmi_pb2 as gnmi
import gnmi_pb2_grpc as gnmi_grpc

DEBUG_LOG = "/tmp/gnmi_debug.log"

GATEWAY_HOST    = os.environ.get("CONTROLLER_HOST", "10.0.0.2")
GATEWAY_URL     = os.environ.get("GATEWAY_URL", f"http://{GATEWAY_HOST}:8181")
GATEWAY_TIMEOUT = float(os.environ.get("GATEWAY_TIMEOUT", "15"))

# Southbound ports on the BeagleBone.
NETCONF_PORT = 8300
GNOI_PORT    = 50051


def log(msg):
    with open(DEBUG_LOG, "a") as f:
        f.write(msg + "\n")


def _gateway_post(path, body, timeout=GATEWAY_TIMEOUT):
    """POST JSON to the gateway. Returns parsed JSON or raises."""
    url = f"{GATEWAY_URL}{path}"
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def main():
    if len(sys.argv) < 3:
        print("FATAL|usage: gnmi_daemon.py <host:port> <device-name> <mtls|plain> [device-ip]")
        sys.stdout.flush()
        sys.exit(1)

    target   = sys.argv[1]
    device   = sys.argv[2]
    tls_mode = sys.argv[3] if len(sys.argv) > 3 else "mtls"
    device_ip = sys.argv[4] if len(sys.argv) > 4 else device
    host, port = target.split(":") if ":" in target else (target, "5150")

    log(f"daemon starting target={target} device={device} "
        f"tls_mode={tls_mode} device_ip={device_ip} gateway={GATEWAY_URL}")

    if tls_mode == "mtls":
        try:
            cert = open("/etc/onos/certs/client1.crt", "rb").read()
            key  = open("/etc/onos/certs/client1.key", "rb").read()
            ca   = open("/etc/onos/certs/tls.cacrt", "rb").read()
        except Exception as e:
            log(f"cert read failed: {e}")
            print(f"FATAL|cert read failed: {e}")
            sys.stdout.flush()
            sys.exit(1)

        creds = grpc.ssl_channel_credentials(
            root_certificates=ca,
            private_key=key,
            certificate_chain=cert,
        )
        options = [
            ("grpc.ssl_target_name_override", "onos-config.opennetworking.org"),
            ("grpc.default_authority",        "onos-config.opennetworking.org"),
        ]
        channel = grpc.secure_channel(f"{host}:{port}", creds, options=options)

    elif tls_mode == "plain":
        channel = grpc.insecure_channel(f"{host}:{port}")

    else:
        log(f"unknown tls_mode: {tls_mode}")
        print(f"FATAL|unknown tls_mode: {tls_mode}")
        sys.stdout.flush()
        sys.exit(1)

    try:
        grpc.channel_ready_future(channel).result(timeout=10)
        log("channel ready")
    except Exception as e:
        log(f"connect failed: {e}")
        log(traceback.format_exc())
        print(f"FATAL|connect failed: {e}")
        sys.stdout.flush()
        sys.exit(1)

    stub = gnmi_grpc.gNMIStub(channel)

    # ------------------------------------------------------------------
    # Southbound dispatch
    # ------------------------------------------------------------------

    def _dispatch_netconf(state):
        """state=True -> enable, state=False -> disable."""
        _gateway_post("/adapter/netconf/switch", {
            "host":     device_ip,
            "port":     NETCONF_PORT,
            "user":     "sdn",
            "password": "quantum",
            "state":    state,
        })

    def _dispatch_gnoi(state):
        _gateway_post("/adapter/gnoi/crossconnect", {
            "host":  device_ip,
            "port":  GNOI_PORT,
            "state": state,
        })

    def _dispatch_gnmi_set(enum_value):
        path = "/switching/state"
        elems = [gnmi.PathElem(name=x) for x in path.strip("/").split("/") if x]
        req = gnmi.SetRequest(
            prefix=gnmi.Path(target=device),
            update=[gnmi.Update(
                path=gnmi.Path(elem=elems),
                val=gnmi.TypedValue(string_val=enum_value),
            )],
        )
        stub.Set(req, timeout=15)

    def _dispatch_gnmi_get():
        elems = [gnmi.PathElem(name=x) for x in
                 "/switching/state".strip("/").split("/") if x]
        req = gnmi.GetRequest(
            prefix=gnmi.Path(target=device),
            path=[gnmi.Path(elem=elems)],
            type=gnmi.GetRequest.CONFIG,
            encoding=gnmi.Encoding.JSON_IETF,
        )
        stub.Get(req, timeout=15)

    # ------------------------------------------------------------------
    # do_set / do_get take the SB hint and route accordingly
    # ------------------------------------------------------------------

    def do_set(value, sb_hint=""):
        is_disabled = str(value).strip().lower() == "disabled"

        if sb_hint == "NETCONF":
            _dispatch_netconf(state=(not is_disabled))
            return

        if sb_hint == "GNOI":
            _dispatch_gnoi(state=(not is_disabled))
            return

        # gNMI (or empty hint): route through onos-config as before.
        enum_value = "disabled" if is_disabled else "enabled"
        _dispatch_gnmi_set(enum_value)

    def do_get(sb_hint=""):
        if sb_hint == "NETCONF":
            _gateway_post("/adapter/netconf/status", {
                "host": device_ip, "port": NETCONF_PORT,
                "user": "sdn", "password": "quantum",
            })
            return

        if sb_hint == "GNOI":
            _gateway_post("/adapter/gnoi/status", {
                "host": device_ip, "port": GNOI_PORT,
            })
            return

        _dispatch_gnmi_get()

    # ------------------------------------------------------------------
    # Command loop
    # ------------------------------------------------------------------

    while True:
        line = sys.stdin.readline()
        if not line or "QUIT" in line:
            break

        parts = line.strip().split("|")
        action  = parts[0]
        raw_val = parts[1] if len(parts) > 1 else ""
        sb_hint = parts[2].strip().upper() if len(parts) > 2 else ""

        try:
            t0 = time.perf_counter()
            if action == "SET":
                do_set(raw_val, sb_hint)
            elif action == "GET":
                do_get(sb_hint)
            elapsed = int((time.perf_counter() - t0) * 1000)
            print(f"{elapsed}")
        except urllib.error.URLError as e:
            log(f"action {action} gateway error: {e}")
            log(traceback.format_exc())
            print("FAILED")
        except grpc.RpcError as e:
            log(f"action {action} gRPC error: {e.code().name}: {e.details()}")
            log(traceback.format_exc())
            print("FAILED")
        except Exception as e:
            log(f"action {action} failed: {e}")
            log(traceback.format_exc())
            print("FAILED")
        sys.stdout.flush()

    try:
        channel.close()
    except Exception:
        pass


if __name__ == "__main__":
    main()
