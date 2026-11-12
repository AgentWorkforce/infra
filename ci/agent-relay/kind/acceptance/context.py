"""Read actual deployment pins from the selected local Kind context."""
import json
from pathlib import Path
import re
import subprocess

from api import Failure, require

# Match both dashboard copy and serving containers, not just the main image.
ROLES = [
    ("relay-control", "api", "control"),
    ("relay-webapp", "copy-dashboard", "webapp"),
    ("relay-webapp", "dashboard", "webapp"),
    ("relaycast", "relaycast", "relaycast"),
    ("session-native-ingest", "ingest-edge", "pipeline"),
    ("session-native-consumer", "consumer", "pipeline"),
    ("session-read-api", "read-api", "pipeline"),
    ("sessions-session-brief", "session-brief", "pipeline"),
    ("telemetry-collector", "collector", "collector"),
]


def output(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise Failure("context_command_failed")
    return result.stdout


def collect(config, root):
    selection_path = Path(config["selectionFile"])
    selected = json.loads(selection_path.read_text())
    tenant = json.loads((selection_path.parent / "tenant.json").read_text())
    require(all(tenant.get(key) == config[key] for key in ["organizationId", "workspaceId"]), "local_tenant_mismatch")
    expected = {key: selected[key] for _, _, key in ROLES}
    require(all(isinstance(ref, str) and re.fullmatch(r"ghcr\.io/agentworkforce/[a-z0-9-]+@sha256:[0-9a-f]{64}", ref)
                for ref in expected.values()), "published_digest_pins_required")
    command = ["kubectl", "--kubeconfig", config["kubeconfig"]]
    uid = output(command + ["get", "namespace", "kube-system", "-o", "jsonpath={.metadata.uid}"]).strip()
    require(bool(re.fullmatch(r"[0-9a-f-]{36}", uid)), "cluster_uid_missing")
    deployments = json.loads(output(command + ["-n", "agent-relay", "get", "deployments", "-o", "json"]))["items"]
    by_name = {item["metadata"]["name"]: item for item in deployments}
    observed = []
    for deployment, container, key in ROLES:
        item = by_name.get(deployment)
        require(item is not None, "required_deployment_missing")
        template = item["spec"]["template"]["spec"]
        containers = template.get("initContainers", []) + template["containers"]
        found = [c for c in containers if c["name"] == container]
        require(len(found) == 1 and found[0]["image"] == expected[key], "runtime_pin_mismatch")
        replicas = item["spec"].get("replicas", 1)
        require(replicas >= 1 and item.get("status", {}).get("availableReplicas", 0) >= replicas
                and item.get("status", {}).get("readyReplicas", 0) >= replicas
                and item.get("status", {}).get("replicas", 0) == replicas
                and item.get("status", {}).get("updatedReplicas", 0) >= replicas
                and item.get("status", {}).get("observedGeneration", 0) >= item["metadata"].get("generation", 1),
                "required_deployment_not_ready")
        observed.append({"deployment": deployment, "container": container, "image": found[0]["image"]})
    revision = output(["git", "-C", str(root), "rev-parse", "HEAD"]).strip()
    require(bool(re.fullmatch(r"[0-9a-f]{40}", revision)), "source_revision_missing")
    require(not output(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=no"]).strip(),
            "tracked_source_changes_present")
    return {"sourceRevision": revision, "clusterUid": uid, "pins": expected, "deployments": observed}
