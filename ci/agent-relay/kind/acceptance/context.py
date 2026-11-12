"""Read actual deployment pins from the selected local Kind context."""
import json
import importlib.util
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
    backend = selected.get("relaycastBackend", "sqlite")
    require(backend in {"sqlite", "postgres", "durable-actors"}, "unknown_cast_backend")
    roles = list(ROLES)
    built = None
    if backend == "durable-actors":
        roles = [(deployment, "gateway" if deployment == "relaycast" else container, key) for deployment, container, key in roles]
        roles.append(("relaycast", "durable-actors-dev", "relaycastActors"))
        spec = importlib.util.spec_from_file_location("acceptance_actor_recipe", root / "ci/agent-relay/kind/local_actor_recipe.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        recipe = module.recipe(root)
        raw = json.loads((selection_path.parent / "actor-build/images.json").read_text())
        require(selected["relaycastActors"] == recipe["actorTag"] and selected["relaycast"] == recipe["source"]["gateway"]["reference"]
                and raw.get("recipeSha256") == recipe["recipeSha256"] and raw.get("actorTag") == recipe["actorTag"]
                and raw.get("upstreamRevision") == recipe["source"]["upstream"]["revision"]
                and raw.get("relaycastRevision") == recipe["source"]["relaycast"]["revision"], "local_actor_recipe_mismatch")
        require(all(isinstance(raw.get(key), str) and re.fullmatch(r"sha256:[0-9a-f]{64}", raw[key])
                    for key in ("runtimeImageId", "actorImageId", "actorConfigId")), "local_actor_image_id_missing")
        built = {key: raw[key] for key in ("recipeSha256", "upstreamRevision", "relaycastRevision", "runtimeImageId", "actorImageId", "actorConfigId")}
    expected = {key: selected[key] for _, _, key in roles}
    require(all(key == "relaycastActors" or isinstance(ref, str) and re.fullmatch(r"ghcr\.io/agentworkforce/[a-z0-9-]+@sha256:[0-9a-f]{64}", ref)
                for key, ref in expected.items()), "published_digest_pins_required")
    command = ["kubectl", "--kubeconfig", config["kubeconfig"]]
    uid = output(command + ["get", "namespace", "kube-system", "-o", "jsonpath={.metadata.uid}"]).strip()
    require(bool(re.fullmatch(r"[0-9a-f-]{36}", uid)), "cluster_uid_missing")
    deployments = json.loads(output(command + ["-n", "agent-relay", "get", "deployments", "-o", "json"]))["items"]
    by_name = {item["metadata"]["name"]: item for item in deployments}
    observed = []
    for deployment, container, key in roles:
        item = by_name.get(deployment)
        require(item is not None, "required_deployment_missing")
        if deployment == "relaycast" and built:
            require(item["spec"]["template"]["metadata"].get("annotations", {}).get("local.agentrelay.dev/actor-image-id") == built["actorImageId"],
                    "deployed_actor_build_mismatch")
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
    result = {"sourceRevision": revision, "clusterUid": uid, "pins": expected, "deployments": observed, "relaycastBackend": backend}
    if built:
        pods = json.loads(output(command + ["-n", "agent-relay", "get", "pods", "-o", "json"]))["items"]
        selector = by_name["relaycast"]["spec"]["selector"]["matchLabels"]
        cast_pods = [pod for pod in pods if not pod["metadata"].get("deletionTimestamp")
                     and all(pod["metadata"].get("labels", {}).get(k) == v for k, v in selector.items())]
        require(len(cast_pods) == by_name["relaycast"]["spec"].get("replicas", 1), "actor_pod_count_mismatch")
        running = []
        for pod in cast_pods:
            node = pod["spec"].get("nodeName")
            imported = raw.get("kindImages", {}).get(node, {})
            require(imported.get("imageId") == built["actorConfigId"], "actor_node_image_mismatch")
            statuses = [s for s in pod.get("status", {}).get("containerStatuses", []) if s["name"] == "durable-actors-dev"]
            require(len(statuses) == 1 and statuses[0].get("ready") is True, "actor_container_not_ready")
            image_id = statuses[0].get("imageID", "").removeprefix("docker-pullable://").removeprefix("docker://").removeprefix("containerd://")
            require(image_id in [built["actorConfigId"], *imported.get("repoDigests", [])], "running_actor_image_mismatch")
            running.append({"node": node, "imageId": image_id})
        built["runningContainers"] = running
        result["localBuilds"] = {"relaycastActors": built}
    return result
