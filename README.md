# QuantumServiceOperationSDNarchitecture

**QuantumServiceOperationSDNarchitecture** defines the Operation and Service Terminal layer for a Software-Defined Quantum Network (SDQN). 

This repository provides the software agent deployed at the edge of the quantum network. It offers a hardware-agnostic interface to request and distribute fundamental quantum resources (such as entanglement pairs or raw qubits) from the SDN controller to end-user applications, serving as the foundation for diverse quantum protocols.

This project works in tandem with the central control plane repository: [QuantumSwitchingSDNarchitecture](https://github.com/marcjofreProf/QuantumSwitchingSDNarchitecture.git), which houses the µONOS, ETSI OSM, and Kubernetes deployments; and with the data plane repository: [QuantumNodeSwitchingSDNoperation](https://github.com/marcjofreProf/QuantumNodeSwitchingSDNoperation.git), which houses the nodes deployments for switching.

## Directory Structure

```text
QuantumServiceOperationSDNarchitecture/
├── config/              # Deployment profiles and configuration templates
├── docs/                # System documentation
├── src/                 # Core source code for the terminal agent
│   ├── api/             # SDN controller communication interfaces
│   ├── core/            # Quantum resource lifecycle and connection management
│   └── hardware/        # Hardware abstraction layer (memories, transceivers)
├── tests/               # Unit tests
├── README.md            # This documentation
└── requirements.txt     # Project dependencies
