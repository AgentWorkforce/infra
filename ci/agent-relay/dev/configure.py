#!/usr/bin/env python3
"""Discover a private development config using GETs and existing source trees."""
import argparse
import json
from pathlib import Path
import re

import dev

SERVICES = {"session-ingest": "ingest", "session-read-api": "reader",
            "session-pipeline-consumer": "consumer", "session-brief": "brief"}
IMAGES = {"selfhost-api": "control", "relay-control": "control", "relay-dashboard": "webapp",
          "relay-webapp": "webapp", "relaycast": "cast", "telemetry-collector": "collector",
          "relaycast-self-host": "cast", "relayfile": "file", "relayflows": "flows"}
REPOS = {"webapp": "relay-webapp", "control": "relay-control", "pipeline": "sessions-pipeline",
         "cast": "relaycast", "file": "relayfile", "flows": "relayflows"}
REQUIRED = {"webapp", "control", "ingest", "reader", "consumer", "brief", "cast", "collector"}


def classify(container, deployment=None):
    if deployment == "telemetry-collector" and container["name"] == "collector":
        dev.need(container.get("command") == ["/usr/bin/flock", "--nonblock", "--no-fork", "/var/lib/telemetry/.writer.lock",
                                              "node", "node_modules/relay-control/dist/collector-cli.js"] and
                 not container.get("args"), "collector_command_shape_changed")
        return "collector"
    service = next((e.get("value") for e in container.get("env", []) if e["name"] == "SERVICE"), None)
    if service in SERVICES: return SERVICES[service]
    name = re.split(r"[@:]", container["image"].rsplit("/", 1)[-1])[0]
    return IMAGES.get(name)


def discover(base, workspace, source_map, cmd):
    cmd.docker_context = base["dockerContext"]
    k = dev.Cluster(base, cmd)
    base = dict(base)
    base["clusterUid"] = k.get("namespace", "kube-system")["metadata"]["uid"]
    base["namespaceUid"] = k.get("namespace", base["namespace"])["metadata"]["uid"]
    k = dev.Cluster(base, cmd)
    docs = k.inventory()
    matches = {}
    for name, doc in docs.items():
        for container in doc["spec"]["template"]["spec"]["containers"]:
            role = classify(container, name)
            if role: matches.setdefault(role, []).append((name, doc, container))
    dev.need(REQUIRED <= matches.keys(), "core_runtime_role_missing")
    for role, rows in matches.items(): dev.need(len(rows) == 1, "ambiguous_role_" + role)
    groups, selected, excluded = {}, set(), {"desktop": "Native Desktop is not a Kind workload; use the Desktop repository's native dev command.",
                                           "chief": "Keep Chief capability off as requested; this loop does not enable optional features."}
    for role, rows in matches.items():
        name, doc, container = rows[0]
        group_name = "pipeline" if role in SERVICES.values() else "control" if role == "collector" else role
        source = source_map.get(group_name, str(Path(workspace) / REPOS[group_name]))
        if isinstance(source, str): source = {"path": source}
        repo = Path(source["path"]).resolve()
        if group_name not in groups:
            dockerfile = source.get("dockerfile", "docker/services.Dockerfile" if group_name == "pipeline" else "Dockerfile")
            groups[group_name] = {"name": group_name, "repo": str(repo), "dockerfile": dockerfile,
                                  "baselineRevision": None, "protectedSourceSha256": None, "sourceUnavailable": True,
                                  "mode": "frontend-hmr" if role == "webapp" else "rebuild", "targets": []}
            if repo.is_dir():
                files = dev.source_files(repo, cmd)
                dev.validate_dockerfile(files, dockerfile)
                groups[group_name].update(baselineRevision=cmd.run(["git", "-C", repo, "rev-parse", "HEAD"]).decode().strip(),
                                          protectedSourceSha256=dev.digest(dev.protected_source(files)), sourceUnavailable=False)
        groups[group_name]["targets"].append({"role": role, "deployment": name, "container": container["name"],
                                             "uid": doc["metadata"]["uid"], "image": container["image"],
                                             "reviewedInitSha256": dev.digest(doc["spec"]["template"]["spec"].get("initContainers", []))})
        selected.add(name)
        if role == "webapp":
            base["publicOrigin"] = next((e.get("value") for e in container.get("env", []) if e["name"] == "DASHBOARD_PUBLIC_URL"), None)
    for role in ("file", "flows"):
        if role not in matches: excluded[role] = "Not deployed on this target; this loop does not enable optional components."
    engine = cmd.json([base["docker"], "info", "--format", "{{json .}}"])
    dev.need(engine["Architecture"] in ("arm64", "aarch64", "amd64", "x86_64"), "architecture_required")
    base.update(version=1, developmentOnly=True, architecture="arm64" if engine["Architecture"] in ("arm64", "aarch64") else "amd64",
                groups=list(groups.values()), protectedDeployments=sorted(docs.keys() - selected), excluded=excluded)
    dev.need(base["protectedDeployments"], "protected_dependency_inventory_required")
    # Metadata discovery does not confer release or containment clearance.
    # A held target may opt into an external admissionFile; normal developers
    # use their explicit target/source bindings without a separate ceremony.
    k.target()
    dev.need({n: dev.identity(d) for n,d in docs.items()} ==
             {n: dev.identity(d) for n,d in k.inventory().items()}, "discovery_runtime_drift")
    return base


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for key in ("kubeconfig", "context", "namespace", "workspace", "docker-context"):
        p.add_argument("--" + key, required=True)
    p.add_argument("--docker", default="docker")
    p.add_argument("--kubectl", default="kubectl")
    p.add_argument("--kind", default="kind")
    p.add_argument("--sources", help="JSON map of component group to existing source checkout path (or {path,dockerfile})")
    p.add_argument("--output", default=".kind/dev/config.json")
    p.add_argument("--admission-file", help="Optional external clearance for an existing target hold")
    a = p.parse_args()
    dev.need(a.context.startswith("kind-"), "explicit_kind_context_required")
    base = {"kubeconfig": str(Path(a.kubeconfig).resolve()), "context": a.context, "cluster": a.context[5:],
            "namespace": a.namespace, "docker": a.docker, "dockerContext": a.docker_context,
            "kubectl": a.kubectl, "kind": a.kind}
    result = discover(base, a.workspace, json.loads(Path(a.sources).read_text()) if a.sources else {}, dev.Commands())
    if a.admission_file: result["admissionFile"] = str(Path(a.admission_file).resolve())
    dev.save(a.output, result)
    dev.emit("discovered_no_effects", config=a.output, configSha256=dev.digest(result),
             roles=sorted(t["role"] for g in result["groups"] for t in g["targets"]),
             missingSourceGroups=[g["name"] for g in result["groups"] if g["sourceUnavailable"]],
             qualification="DEVELOPMENT_ONLY_NOT_RELEASE_ADMISSION")


if __name__ == "__main__":
    try: main()
    except Exception as error:
        dev.emit("refused", code=str(error) if isinstance(error, dev.Refused) else type(error).__name__)
        raise SystemExit(1)
