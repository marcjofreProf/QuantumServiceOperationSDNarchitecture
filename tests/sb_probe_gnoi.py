#!/usr/bin/env python3
"""gNOI southbound probe."""
import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
for p in (os.path.join(ROOT, "proto"), ROOT):
    if p not in sys.path: sys.path.insert(0, p)
import grpc
import quantum_gnoi_switching_pb2 as pb
import quantum_gnoi_switching_pb2_grpc as svc

def read_state(stub, timeout=2.0):
    resp = stub.GetCrossConnectStatus(pb.StatusRequest(), timeout=timeout)
    return "true" if resp.is_connected else "false"

def main():
    if len(sys.argv) < 2:
        print("FATAL|usage: sb_probe_gnoi.py <host:port>"); sys.stdout.flush(); sys.exit(1)
    endpoint = sys.argv[1]
    ch = grpc.insecure_channel(endpoint)
    stub = svc.QuantumGnoiSwitchingServiceStub(ch)
    try:
        grpc.channel_ready_future(ch).result(timeout=5)
        read_state(stub)
    except Exception as e:
        print(f"FATAL|cannot reach {endpoint}: {e}"); sys.stdout.flush(); sys.exit(1)
    for raw in sys.stdin:
        line = raw.strip()
        if not line: continue
        if line == "QUIT": break
        if not line.startswith("CHECK|"):
            print("ERROR|bad-command"); sys.stdout.flush(); continue
        expected = line.split("|", 1)[1].strip().lower()
        try:
            actual = read_state(stub)
        except grpc.RpcError as e:
            print(f"ERROR|{e.code()}"); sys.stdout.flush(); continue
        print("PRESENT" if actual == expected else "ABSENT")
        sys.stdout.flush()
    try: ch.close()
    except Exception: pass

if __name__ == "__main__":
    main()
