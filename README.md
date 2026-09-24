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
```

## Orchestration via Canonical Juju

To seamlessly integrate with ETSI OSM and Kubernetes, this architecture is wrapped and managed using **Canonical Juju**. Operating as the VCA (VNF Configuration and Abstraction) engine, Juju charms map our underlying network data models to higher-level orchestrator inputs. Juju handles lifecycle operations, automatically translating orchestrator intents into local terminal configurations and executing operational scripts.

## mTLS Certificate & gNMI Configuration
To execute gnmic operations against the remote micro-onos controller, valid mTLS certificates must be imported into /etc/onos/certs/ on your local host.

1. Certificate Transfer Options
Extract or deploy the certificate files (client1.crt, client1.key, tls.cacrt) from the controller host using one of the following methods. These are the same files the controller uses: client1.* is the ONF-signed client identity from the onos-cli pod, and tls.cacrt is the server's CA extracted from the onos-config pod.

Option (i): Secure Copy (SCP) from Controller IP
Ensure the certificates on the controller have read permissions, then pull them into a user folder before copying to /etc/onos/certs/:
```bash
mkdir -p $HOME/onos/certs
scp <username>@<controller_IP>:~/Scripts/QuantumSwitchingSDNarchitecture/.certs/uonos/client1.crt $HOME/onos/certs/
scp <username>@<controller_IP>:~/Scripts/QuantumSwitchingSDNarchitecture/.certs/uonos/client1.key $HOME/onos/certs/
scp <username>@<controller_IP>:~/Scripts/QuantumSwitchingSDNarchitecture/.certs/uonos/tls.cacrt  $HOME/onos/certs/
sudo mkdir -p /etc/onos/certs
sudo cp $HOME/onos/certs/client1.crt /etc/onos/certs/
sudo cp $HOME/onos/certs/client1.key /etc/onos/certs/
sudo cp $HOME/onos/certs/tls.cacrt  /etc/onos/certs/
sudo chmod 644 /etc/onos/certs/client1.crt /etc/onos/certs/client1.key /etc/onos/certs/tls.cacrt
```

Option (ii): Manual Copy via Shared Folder
If both host systems share a mounted directory or shared folder, copy certificates to the shared mount point:
```bash
# In controller terminal:
mkdir -p /path/to/shared_folder/onos/certs
sudo cp .certs/uonos/client1.crt /path/to/shared_folder/onos/certs/
sudo cp .certs/uonos/client1.key /path/to/shared_folder/onos/certs/
sudo cp .certs/uonos/tls.cacrt  /path/to/shared_folder/onos/certs/
# In operational terminal:
sudo mkdir -p /etc/onos/certs
sudo cp /path/to/shared_folder/onos/certs/client1.crt /etc/onos/certs/
sudo cp /path/to/shared_folder/onos/certs/client1.key /etc/onos/certs/
sudo cp /path/to/shared_folder/onos/certs/tls.cacrt  /etc/onos/certs/
sudo chmod 644 /etc/onos/certs/client1.crt /etc/onos/certs/client1.key /etc/onos/certs/tls.cacrt
```

2. Local .gnmic.yaml Setup
Generate the global gnmic configuration file in /etc/onos/certs/.gnmic.yaml. Note that tls-ca is omitted due to x509 CA constraints on the micro-onos generated secrets, relying on skip-verify: true for identity validation:
```bash
sudo mkdir -p /etc/gnmic
cat << 'EOF' | sudo tee /etc/gnmic/gnmic.yaml > /dev/null
skip-verify: true
tls-cert: /etc/onos/certs/client1.crt
tls-key: /etc/onos/certs/client1.key
EOF
sudo chmod 644 /etc/gnmic/gnmic.yaml
```

### Invocation rules for gnmic

The config file above is placed under `/etc/gnmic/` (not in the default
`gnmic` search path) so it is only loaded when explicitly requested. This
avoids conflicts with `gnmic --insecure` when probing a plaintext device
like the BeagleBone.

- To query **onos-config** (mTLS, `skip-verify` required):
```bash
gnmic -c /etc/gnmic/gnmic.yaml -a <controller>:5150 capabilities
```

- To query a **plaintext device** like the BeagleBone (no TLS at all):
```bash
gnmic -a <node>:50051 --insecure get --path "/switching/state"
```

Do not mix `--insecure` with a config that sets `skip-verify: true`: gnmic
rejects the combination with
`flags --insecure and --skip-verify are mutually exclusive`.

## SDN Protocol Architecture: Protobuf & YANG

This terminal agent operates on a dual-protocol model to align with modern telecom SDN standards, effectively separating the control and management planes:

1. **High-Speed Control & Operations (gRPC / Protobuf):**
   Utilized for dynamic, low-latency quantum operations, such as fast path switching, entanglement request sessions, and continuous telemetry streaming. We leverage standard **gNOI** (gRPC Network Operations Interface) and **gNMI** (gRPC Network Management Interface) protocols.

*Example Usage:* To dynamically query the real-time status of a switching node on the data plane, the terminal or Juju charm executes:
   ```bash
   python3 ./scripts/terminal-gnoi-switching-client.py <NODE_IP> status
   python3 ./scripts/terminal-gnoi-switching-client.py <NODE_IP> connect
   python3 ./scripts/terminal-gnoi-switching-client.py <NODE_IP> disconnect
   ```

2. High-Level Service Orchestration (YANG / RESTCONF via Juju):
Utilized for intent-based provisioning by automatically translating orchestrator intents into local terminal configurations. The terminal maps these underlying network data models into standard YANG schemas and transmits them via RESTCONF to the controller.

* Compile the YANG tree and deploy the Juju charm
./tests/deploy-juju-example-switching-terminal.sh

* Trigger the RESTCONF service provisioning action
./tests/test-juju-example-switching-action.sh

3. End-to-End Performance & Statistical Protocol Benchmarking

To evaluate and compare performance across both Northbound (RESTCONF vs. direct gNMI) and Southbound (NETCONF vs. gNOI) protocol paths, a dedicated statistical benchmarking tool is provided.

The benchmark measures real lifecycle latency across multiple execution rounds and seamlessly supports execution against either physical hardware nodes or the in-cluster simulated target (devicesim-1).

a. Run against Physical Node Hardware:
```bash
TARGET_DEVICE="quantum-node-1" TARGET_NODE_IP="quantum-node-1" ./tests/test-sdn-protocol-switching-performance.sh 10
TARGET_DEVICE="quantum-node-1" TARGET_NODE_IP="quantum-node-1" ONOS_GNMI_TARGET_MODE=direct ./tests/test-sdn-protocol-switching-performance.sh 10
```
b. Run against Simulated Target (devicesim-1):
```bash
TARGET_DEVICE="devicesim-1" TARGET_NODE_IP="devicesim-1" ./tests/test-sdn-protocol-switching-performance.sh 10
```

Execution Particularities & Parameters:
TARGET_DEVICE (Environment Variable): Specifies the ONOS topology target entity name. Set to quantum-node-1 for physical node testing, or devicesim-1 for local/in-cluster simulator testing.

TARGET_NODE_IP (Environment Variable): Defines the network IP address of the target switching node (10.0.0.254 for physical hardware, or 127.0.0.1 / cluster IP for simulator).

[ITERATIONS] (Positional Argument): Number of full lifecycle executions to perform per protocol path (e.g., 10). Higher iterations generate statistical metrics: Mean (μ), Standard Deviation (σ), Minimum, and Maximum latency.

## Installation & Bootstrapping
Clone the repository and run the bootstrap script to create your virtual environment, install dependencies, and compile the necessary gRPC and YANG schemas:
```bash
git clone git clone https://github.com/marcjofreProf/QuantumServiceOperationSDNarchitecture.git
cd QuantumServiceOperationSDNarchitecture
sudo chmod +x ./bootstrap-oss-terminal.sh
./bootstrap-oss-terminal.sh
```

## The Cleanup Script (`uninstall-bootstrap-oss-terminal.sh`)
This script safely tears down the local environment, returning your repository to a perfectly clean state. It is useful for troubleshooting, resetting your setup, or preparing the directory for a fresh commit.
```bash
sudo chmod +x ./uninstall-bootstrap-oss-terminal.sh
./uninstall-bootstrap-oss-terminal.sh
```

When executed, it safely removes all generated artifacts:
*   **Removes the Environment:** Deletes the isolated `.venv/` directory.
*   **Cleans gRPC Stubs:** Deletes all auto-generated Python Protobuf files (`*_pb2.py` and `*_pb2_grpc.py`).
*   **Cleans YANG Trees:** Deletes all generated `.tree` visualization files.
*   **Clears System Cache:** Recursively wipes all `__pycache__` directories and compiled Python bytecode (`.pyc`).
*   **Revokes Permissions:** Removes execution rights from the `scripts/` directory to prevent accidental execution in a broken state.
