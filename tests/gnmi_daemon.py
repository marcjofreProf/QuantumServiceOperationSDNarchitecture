#!/usr/bin/env python3
"""
Persistent gNMI client for the SDN protocol benchmark.

Reads commands from stdin, one per line, in the form:
    SET|<value>
    GET|
    QUIT
and writes back either a latency in milliseconds or FAILED.

Runs against onos-config over mTLS. We build the gRPC channel directly
(with the SNI override pygnmi does not expose) and use the gNMI stubs
generated into proto/ by the bootstrap script.
"""
import sys
import os
import time
import json
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
PROTO_DIR = os.path.abspath(os.path.join(HERE, "..", "proto"))
if PROTO_DIR not in sys.path:
    sys.path.insert(0, PROTO_DIR)

import grpc
import gnmi_pb2 as gnmi
import gnmi_pb2_grpc as gnmi_grpc

DEBUG_LOG = "/tmp/gnmi_debug.log"


def log(msg):
    with open(DEBUG_LOG, "a") as f:
        f.write(msg + "\n")


def main():
    target = sys.argv[1]
    device = sys.argv[2]
    host, port = target.split(":") if ":" in target else (target, "5150")

    log(f"daemon starting target={target} device={device}")

    # ---- TLS credentials ----
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

    # ---- channel options (the SNI override) ----
    options = [
        ("grpc.ssl_target_name_override", "onos-config.opennetworking.org"),
        ("grpc.default_authority",        "onos-config.opennetworking.org"),
    ]

    try:
        channel = grpc.secure_channel(f"{host}:{port}", creds, options=options)
        grpc.channel_ready_future(channel).result(timeout=10)
        log("channel ready")
    except Exception as e:
        log(f"connect failed: {e}")
        log(traceback.format_exc())
        print(f"FATAL|connect failed: {e}")
        sys.stdout.flush()
        sys.exit(1)

    stub = gnmi_grpc.gNMIStub(channel)

    def do_set(value):
        # The controller-quantum-switching model plugin exposes exactly one
        # writable leaf: /switching/state (enum: enabled | disabled).
        # Any other path is rejected by onos-config with "not yet supported".
        #
        # The shell script sends an arbitrary description string for the
        # "connect" phase and "disabled" for the "disconnect" phase. Map
        # anything that is not "disabled" to "enabled" so both phases are
        # valid writes.
        enum_value = "disabled" if str(value).strip().lower() == "disabled" else "enabled"

        path = "/switching/state"
        elems = [gnmi.PathElem(name=x) for x in path.strip("/").split("/") if x]
        req = gnmi.SetRequest(
            prefix=gnmi.Path(target=device),
            update=[
                gnmi.Update(
                    path=gnmi.Path(elem=elems),
                    val=gnmi.TypedValue(string_val=enum_value),
                )
            ],
        )
        try:
            stub.Set(req, timeout=15)
        except Exception as e:
            log(f"Set failed on [{path}]: {e}")
            raise

    def do_get():
        # Read back the same leaf the Set writes to.
        elems = [gnmi.PathElem(name=x) for x in
                 "/switching/state".strip("/").split("/") if x]
        req = gnmi.GetRequest(
            prefix=gnmi.Path(target=device),
            path=[gnmi.Path(elem=elems)],
            type=gnmi.GetRequest.CONFIG,
            encoding=gnmi.Encoding.JSON_IETF,
        )
        stub.Get(req, timeout=15)

    while True:
        line = sys.stdin.readline()
        if not line or "QUIT" in line:
            break

        parts = line.strip().split("|")
        action = parts[0]

        try:
            t0 = time.perf_counter()
            if action == "SET":
                raw_val = parts[1] if len(parts) > 1 else ""
                do_set(raw_val)
            elif action == "GET":
                do_get()
            elapsed = int((time.perf_counter() - t0) * 1000)
            print(f"{elapsed}")
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
