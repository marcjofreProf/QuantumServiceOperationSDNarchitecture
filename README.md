# QuantumServiceOperationSDNarchitecture

**QuantumServiceOperationSDNarchitecture** defines the Operation and Service Terminal layer for a Software-Defined Quantum Network (SDQN). 

This repository provides the software agent deployed at the edge of the quantum network. It offers a hardware-agnostic interface to request and distribute fundamental quantum resources (such as entanglement pairs or raw qubits) from the SDN controller to end-user applications, serving as the foundation for diverse quantum protocols.

This project works in tandem with the central control plane repository: [QuantumSwitchingSDNarchitecture](https://github.com/marcjofreProf/QuantumSwitchingSDNarchitecture.git), which houses the µONOS, ETSI OSM, and Kubernetes deployments; and with the data plane repository: [QuantumNodeSwitchingSDNoperation](https://github.com/marcjofreProf/QuantumNodeSwitchingSDNoperation.git), which houses the nodes deployments for switching.

## Directory Structure

```text
QuantumServiceOperationSDNarchitecture/
├── charm/               # Canonical Juju charm definitions and hooks
├── config/              # Deployment profiles and configuration templates
├── docs/                # System documentation
├── scripts/             # Day-1/Day-2 operational scripts (e.g., gnoi-switching-client.py)
├── src/                 # Core source code for the terminal agent
│   ├── api/             
│   │   ├── yang/        # YANG models for RESTCONF
│   │   ├── proto/       # Protobuf files for gRPC/gNMI
│   │   ├── restconf/    # RESTCONF client & server implementations
│   └── grpc/            # Generated gRPC code & client stubs
│   ├── core/            # Quantum resource lifecycle and connection management
│   └── hardware/        # Hardware abstraction layer (memories, transceivers)
├── tests/               # Unit tests
├── bootstrap-oss-terminal.sh            # Setup script (venv, dependencies, schemas)
├── uninstall-bootstrap-oss-terminal.sh  # Cleanup script
└── requirements.txt     # Python project dependencies

## Orchestration via Canonical Juju

To seamlessly integrate with ETSI OSM and Kubernetes, this architecture is wrapped and managed using **Canonical Juju**. Operating as the VCA (VNF Configuration and Abstraction) engine, Juju charms map our underlying network data models to higher-level orchestrator inputs. Juju handles lifecycle operations, automatically translating orchestrator intents into local terminal configurations and executing operational scripts.

## SDN Protocol Architecture: Protobuf & YANG

This terminal agent operates on a dual-protocol model to align with modern telecom SDN standards, effectively separating the control and management planes:

1. **High-Speed Control & Operations (gRPC / Protobuf):**
   Utilized for dynamic, low-latency quantum operations, such as fast path switching, entanglement request sessions, and continuous telemetry streaming. We leverage standard **gNOI** (gRPC Network Operations Interface) and **gNMI** (gRPC Network Management Interface) protocols.

*Example Usage:* To dynamically query the real-time status of a switching node on the data plane, the terminal or Juju charm executes:
   ```bash
   python3 scripts/terminal-gnoi-switching-client.py <NODE_IP> status

2. High-Level Service Orchestration (YANG / RESTCONF via Juju):
Utilized for intent-based provisioning by automatically translating orchestrator intents into local terminal configurations. The terminal maps these underlying network data models into standard YANG schemas and transmits them via RESTCONF to the controller.

* Compile the YANG tree and deploy the Juju charm
./tests/deploy-juju-example-switching-terminal.sh

* Trigger the RESTCONF service provisioning action
./tests/test-juju-example-switching-action.sh

## Installation & Bootstrapping
Clone the repository and run the bootstrap script to create your virtual environment, install dependencies, and compile the necessary gRPC and YANG schemas:

git clone git clone https://github.com/marcjofreProf/QuantumServiceOperationSDNarchitecture.git
cd QuantumServiceOperationSDNarchitecture
sudo chmod +x ./bootstrap-oss-terminal.sh
./bootstrap-oss-terminal.sh


## The Cleanup Script (`uninstall-bootstrap-oss-terminal.sh`)
This script safely tears down the local environment, returning your repository to a perfectly clean state. It is useful for troubleshooting, resetting your setup, or preparing the directory for a fresh commit.

When executed, it safely removes all generated artifacts:
*   **Removes the Environment:** Deletes the isolated `.venv/` directory.
*   **Cleans gRPC Stubs:** Deletes all auto-generated Python Protobuf files (`*_pb2.py` and `*_pb2_grpc.py`).
*   **Cleans YANG Trees:** Deletes all generated `.tree` visualization files.
*   **Clears System Cache:** Recursively wipes all `__pycache__` directories and compiled Python bytecode (`.pyc`).
*   **Revokes Permissions:** Removes execution rights from the `scripts/` directory to prevent accidental execution in a broken state.
