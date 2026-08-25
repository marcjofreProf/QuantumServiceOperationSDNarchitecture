import json
import requests
from ops.charm import CharmBase
from ops.main import main

class QuantumTerminalCharm(CharmBase):
    def __init__(self, *args):
        super().__init__(*args)
        self.framework.observe(self.on.create_cross_connect_action, self._on_create_cross_connect)

    def _on_create_cross_connect(self, event):
        service_id = event.params["service-id"]
        node_ip = event.params["target-node-ip"]
        admin_state = event.params["admin-state"]

        controller_ip = self.config.get("controller-ip", "10.0.0.1")
        restconf_url = f"http://{controller_ip}:8181/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service"

        # JSON object keyed by the module name example-quantum-switching-terminal-service
        yang_payload = {
            "example-quantum-switching-terminal-service:cross-connect-service": [
                {
                    "service-id": service_id,
                    "target-node-ip": node_ip,
                    "ingress-port": event.params["ingress-port"],
                    "egress-port": event.params["egress-port"],
                    "admin-state": admin_state
                }
            ]
        }

        headers = {"Content-Type": "application/yang-data+json"}

        try:
            response = requests.post(restconf_url, json=yang_payload, headers=headers, timeout=5)
            if response.status_code in [200, 201, 204]:
                event.set_results({"status": "SUCCESS", "message": f"Service {service_id} provisioned on {node_ip}"})
            else:
                event.fail(f"RESTCONF HTTP {response.status_code}: {response.text}")
        except Exception as e:
            event.fail(f"Connection to controller failed: {str(e)}")

if __name__ == "__main__":
    main(QuantumTerminalCharm)
