#!/usr/bin/env bash
"exec" "$(dirname "$0")/../.venv/bin/python3" "$0" "$@"
# --- Python Code Starts Below ---

import sys
import os
import argparse

# Inject src/api/grpc into Python path for generated stubs
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GRPC_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "../src/api/grpc"))
sys.path.insert(0, GRPC_DIR)

try:
    import grpc
    import terminal_quantum_gnoi_switching_pb2 as pb2
    import terminal_quantum_gnoi_switching_pb2_grpc as pb2_grpc
    STUBS_AVAILABLE = True
except ImportError:
    STUBS_AVAILABLE = False

def main():
    parser = argparse.ArgumentParser(
        description="Quantum Terminal gNOI Switching Client"
    )
    parser.add_argument("node_ip", help="Target IP address of the Quantum Switching Node")
    parser.add_argument(
        "command", 
        choices=["status", "connect", "disconnect"], 
        help="gNOI operation to perform"
    )
    parser.add_argument("--port", default="50051", help="gRPC server port (default: 50051)")

    args = parser.parse_args()

    target_address = f"{args.node_ip}:{args.port}"
    print(f"[*] Target Node Address: {target_address}")
    print(f"[*] Command: {args.command}")
    print(f"[*] Python Interpreter: {sys.executable}")
    print(f"[*] Compiled gRPC Stubs Loaded: {STUBS_AVAILABLE}")

    if not STUBS_AVAILABLE:
        print("[!] Warning: gRPC stubs not compiled yet. Run './bootstrap-oss-terminal.sh' first.")
        return

    # Mock execution flow (Ready for live gRPC channel connection)
    if args.command == "status":
        request = pb2.SwitchStatusRequest(terminal_id="terminal-edge-01")
        print(f"[+] Formatted Protobuf Request:\n{request}")
    elif args.command in ["connect", "disconnect"]:
        is_connect = (args.command == "connect")
        request = pb2.CrossConnectRequest(
            session_id="sess-qsdn-1001",
            input_port=1,
            output_port=2,
            connect_state=is_connect,
            resource_type=pb2.RESOURCE_TYPE_EPR_PAIR
        )
        print(f"[+] Formatted Protobuf Request:\n{request}")

if __name__ == "__main__":
    main()
