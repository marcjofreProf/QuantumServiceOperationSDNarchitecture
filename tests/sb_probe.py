#!/usr/bin/env python3
"""gNMI southbound probe."""
import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
for p in (os.path.join(ROOT, "proto"), ROOT):
    if p not in sys.path: sys.path.insert(0, p)
import grpc
import gnmi_pb2 as gnmi
import gnmi_pb2_grpc as gnmi_grpc

def read_state(stub, timeout=2.0):
    resp = stub.Get(gnmi.GetRequest(), timeout=timeout)
    for n in resp.notification:
        for u in n.update:
            if u.val.HasField("string_val"):
                return u.val.string_val.strip().lower()
    return None

def main():
    if len(sys.argv) < 2:
        print("FATAL|usage: sb_probe.py <host:port>"); sys.stdout.flush(); sys.exit(1)
    endpoint = sys.argv[1]
    ch = grpc.insecure_channel(endpoint)
    stub = gnmi_grpc.gNMIStub(ch)
    try:
        grpc.channel_ready_future(ch).result(timeout=5)
        if read_state(stub) is None:
            raise RuntimeError("no string_val in initial Get")
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
        except Exception as e:
            print(f"ERROR|{type(e).__name__}"); sys.stdout.flush(); continue
        if actual is None: print("ERROR|no-state")
        elif actual == expected: print("PRESENT")
        else: print("ABSENT")
        sys.stdout.flush()
    try: ch.close()
    except Exception: pass

if __name__ == "__main__":
    main()
