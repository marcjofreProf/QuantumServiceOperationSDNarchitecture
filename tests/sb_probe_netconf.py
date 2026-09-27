#!/usr/bin/env python3
"""NETCONF southbound probe."""
import sys
from ncclient import manager
from lxml import etree
NS = "urn:quantum:sdn:netconf-switch"

def read_state(host, port):
    with manager.connect(
        host=host, port=port, username="sdn", password="quantum",
        hostkey_verify=False, allow_agent=False, look_for_keys=False,
        device_params={"name": "default"}, timeout=5,
    ) as m:
        reply = m.get(filter=("subtree", f'<netconf-switch xmlns="{NS}"/>'))
    root = etree.fromstring(reply.xml.encode())
    node = root.find(f".//{{{NS}}}switch-state")
    return node.text.strip().lower() if node is not None and node.text else None

def main():
    if len(sys.argv) < 2:
        print("FATAL|usage: sb_probe_netconf.py <host> [port]"); sys.stdout.flush(); sys.exit(1)
    host = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8300
    try:
        if read_state(host, port) is None:
            raise RuntimeError("no switch-state in initial <get>")
    except Exception as e:
        print(f"FATAL|cannot talk NETCONF to {host}:{port}: {type(e).__name__}: {e}")
        sys.stdout.flush(); sys.exit(1)
    for raw in sys.stdin:
        line = raw.strip()
        if not line: continue
        if line == "QUIT": break
        if not line.startswith("CHECK|"):
            print("ERROR|bad-command"); sys.stdout.flush(); continue
        expected = line.split("|", 1)[1].strip().lower()
        try:
            actual = read_state(host, port)
        except Exception as e:
            print(f"ERROR|{type(e).__name__}"); sys.stdout.flush(); continue
        if actual is None: print("ERROR|no-state")
        else: print("PRESENT" if actual == expected else "ABSENT")
        sys.stdout.flush()

if __name__ == "__main__":
    main()
