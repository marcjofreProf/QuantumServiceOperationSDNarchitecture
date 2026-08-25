#!/usr/bin/env python3
import sys
import os

# Auto-reexec script under project .venv if present
script_dir = os.path.dirname(os.path.abspath(__file__))
project_root = os.path.dirname(script_dir)
venv_python = os.path.join(project_root, ".venv", "bin", "python3")

if os.path.exists(venv_python) and sys.executable != venv_python:
    os.execv(venv_python, [venv_python] + sys.argv)

import grpc

# Add proto directory to path
proto_path = os.path.join(project_root, "src", "api", "proto")
sys.path.append(proto_path)

try:
    import terminal_quantum_gnoi_switching_pb2 as pb2
    import terminal_quantum_gnoi_switching_pb2_grpc as pb2_grpc
except ImportError:
    print(f"[-] Error: Could not find compiled stubs in {proto_path}")
    sys.exit(1)


def main():
    if len(sys.argv) < 3:
        print("Usage: ./terminal-gnoi-switching-client.py <NODE_IP> <status|connect|disconnect>")
        sys.exit(1)

    node_ip = sys.argv[1]
    command = sys.argv[2].lower()
    target_addr = f"{node_ip}:50051"

    print(f"[*] Target Node Address: {target_addr}")
    print(f"[*] Command: {command}")

    channel = grpc.insecure_channel(target_addr)
    # Match working controller stub class
    stub = pb2_grpc.QuantumGnoiSwitchingServiceStub(channel)

    try:
        if command == "status":
            request = pb2.StatusRequest()
            response = stub.GetCrossConnectStatus(request, timeout=5)
            print(f"[+] Status Response: connected={response.is_connected}, switch_type='{response.switch_type}'")

        elif command in ["connect", "enable", "on"]:
            request = pb2.CrossConnectRequest(state=True)
            response = stub.SetCrossConnect(request, timeout=5)
            print(f"[+] Response: success={response.success}, message='{response.message}'")

        elif command in ["disconnect", "disable", "off"]:
            request = pb2.CrossConnectRequest(state=False)
            response = stub.SetCrossConnect(request, timeout=5)
            print(f"[+] Response: success={response.success}, message='{response.message}'")

        else:
            print(f"[-] Unknown command '{command}'. Use 'status', 'connect', or 'disconnect'.")

    except grpc.RpcError as e:
        print(f"[-] gRPC Error ({e.code()}): {e.details()}")


if __name__ == "__main__":
    main()
