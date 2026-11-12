#!/usr/bin/env python3
"""An isolated local Kind fixture for the actor benchmark. Never adopts local-up."""
import argparse
import json
import math
import os
from pathlib import Path
import secrets
import sys
import time

NAME = "agent-relay-actors-bench"
NS = "relaycast-bench"
NODE_IMAGE = "node:22.23.2-bookworm-slim@sha256:48e4b67d85f87bd551df43704e24d252f56cc5f8e9718841aace50f19948f0f9"


def validate_plan(plan, seconds):
    if (plan.get("schema") != "agent-relay.relaycast-replay-plan/v1" or plan.get("execution") != "not_run"
            or not 10 <= seconds <= 600 or not 1 <= len(plan.get("steps", [])) <= 12):
        raise ValueError("invalid benchmark plan")
    for step in plan["steps"]:
        target = step.get("targetPeakRps")
        if type(target) not in (int, float) or not math.isfinite(target) or not 0 < target <= 5000:
            raise ValueError("benchmark target must be finite and at most 5000 RPS")
        rates = [route.get("targetRps") for route in step.get("routes", [])]
        if (not rates or len(rates) > 256 or any(type(rate) not in (int, float) or not math.isfinite(rate) or rate < 0 for rate in rates)
                or not math.isclose(sum(rates), target, abs_tol=1e-6)):
            raise ValueError("route rates do not equal the step target")
    return plan


def validate_identity(record, cluster_uid, docker_host):
    if (record.get("name") != NAME or record.get("clusterUid") != cluster_uid
            or record.get("dockerHost") != docker_host):
        raise ValueError("benchmark cluster identity changed; no resource adopted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["up", "down", "observe", "run"])
    parser.add_argument("--infra-root", type=Path, required=True)
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--seconds", type=int, default=60)
    args = parser.parse_args()
    root = args.infra_root.resolve()
    sys.path.insert(0, str(root / "ci/agent-relay/kind"))
    from stack import Stack, StackError, NODE, private_json
    from local_actors import recipe, build, load

    class Fixture(Stack):
        def identity_layout(self, profile):
            return NAME, root / ".kind/bench-runtime"

        def k(self, *words, namespace=NS, **kw):
            return super().k(*words, namespace=namespace, **kw)

        def owned(self):
            record = json.loads(self.marker.read_text())
            validate_identity(record, self.cluster_uid(self.kubeconfig), self.env["DOCKER_HOST"])

    s = Fixture("core")
    s.docker(require_space=args.command == "up")
    clusters = s.cmd(["kind", "get", "clusters"]).stdout.splitlines()
    if args.command == "up":
        if NAME in clusters:
            s.owned()
        else:
            if s.marker.exists():
                raise StackError("benchmark cluster disappeared; ownership must be reconciled")
            # No host ports, hosts entries, CA, system settings or viewing data.
            s.cmd(["kind", "create", "cluster", "--name", NAME, "--image", NODE,
                   "--kubeconfig", s.kubeconfig], timeout=600)
            s.kubeconfig.chmod(0o600)
            private_json(s.marker, {"name": NAME, "clusterUid": s.cluster_uid(s.kubeconfig),
                                   "dockerHost": s.env["DOCKER_HOST"]})
        selected = recipe(root)
        built = build(s, selected)
        load(s, built)
        s.apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": NS}})
        credential_path = s.state / "benchmark-credentials.json"
        if credential_path.exists():
            c = json.loads(credential_path.read_text())
        else:
            c = {key: secrets.token_hex(32) for key in ("internal", "bootstrap", "keyring", "files", "actors")}
            private_json(credential_path, c)
        s.apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "benchmark-credentials", "namespace": NS},
            "stringData": {"internal-secret": c["internal"], "workspace-bootstrap-secret": c["bootstrap"],
                "credential-keyring": json.dumps({"current": "benchmark", "keys": {"benchmark": c["keyring"]}}),
                "file-signing-secret": c["files"], "durable-actors-dev-secret": c["actors"]}})
        s.apply({"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "benchmark-actors", "namespace": NS},
            "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}}})
        repo, tag = built["actorTag"].rsplit(":", 1)
        gateway_repo, digest = selected["source"]["gateway"]["reference"].split("@", 1)
        values = {"fullnameOverride": "relaycast-bench", "baseUrl": "http://relaycast-bench.relaycast-bench.svc:8787",
            "allowInsecureBaseUrl": True, "existingSecret": "benchmark-credentials",
            "secretKeys": {"credentialKeyring": "credential-keyring"}, "credentials": {"format": "ar", "authority": "self"},
            "analytics": {"enabled": False}, "networkPolicy": {"enabled": False}, "ingress": {"enabled": False},
            "podSecurityContext": {"fsGroup": 10000},
            "podAnnotations": {"local.agentrelay.dev/actor-image-id": built["actorImageId"]},
            "runtime": {"backend": "durable-actors", "durableActors": {
                "gateway": {"image": {"repository": gateway_repo, "digest": digest},
                    "resources": {"requests": {"cpu": "100m", "memory": "128Mi"}, "limits": {"memory": "1Gi"}}},
                "fileStore": {"driver": "local"}, "deployer": {"enabled": False},
                "devRuntime": {"enabled": True, "acknowledgeNonProduction": True, "existingClaim": "benchmark-actors",
                    "image": {"repository": repo, "tag": tag, "pullPolicy": "Never"},
                    "resources": {"requests": {"cpu": "100m", "memory": "256Mi"}, "limits": {"memory": "2Gi"}}}}}}
        private_json(s.overrides, values)
        s.cmd(["helm", "upgrade", "--install", "relaycast-bench", str(root / "charts/relaycast"), "-n", NS,
               "--kubeconfig", s.kubeconfig, "-f", s.overrides, "--wait", "--timeout", "8m"], timeout=510)
        print(json.dumps({"status": "ready", "cluster": NAME, "gateway": selected["source"]["gateway"]["reference"],
                          "actorImageId": built["actorImageId"], "actorAnalytics": "unsupported_skipped"}))
        return
    s.owned()
    if args.command == "down":
        s.cmd(["kind", "delete", "cluster", "--name", NAME], timeout=180)
        s.marker.unlink()
        print(json.dumps({"removedCluster": NAME, "viewingFixture": "untouched", "buildCache": "retained"}))
        return
    if args.command == "observe":
        print(s.k("get", "pods", "-o", "json").stdout)
        return
    if args.plan is None or not 10 <= args.seconds <= 600:
        raise StackError("benchmark run needs --plan and --seconds between 10 and 600")
    plan = validate_plan(json.loads(args.plan.read_text()), args.seconds)
    run_id = secrets.token_hex(6)
    pod_name = "load-" + run_id
    config = {"plan": plan, "seconds": args.seconds, "maxInflight": 512,
              "population": {"workspaces": 5, "agentsPerWorkspace": 10, "websockets": 50},
              "populationMode": "fixed_assumed", "socketLifetime": "replaced by observed upgrade traffic"}
    s.apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": pod_name, "namespace": NS},
        "data": {"run.mjs": Path(__file__).with_name("run.mjs").read_text(), "config.json": json.dumps(config)}})
    s.apply({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": pod_name, "namespace": NS,
        "labels": {"local.agentrelay.dev/benchmark": run_id}}, "spec": {"restartPolicy": "Never",
        "automountServiceAccountToken": False, "securityContext": {"runAsUser": 10000, "runAsGroup": 10000, "fsGroup": 10000},
        "containers": [{"name": "generator", "image": NODE_IMAGE, "command": ["node", "/scripts/run.mjs"],
            "resources": {"requests": {"cpu": "100m", "memory": "128Mi"}, "limits": {"memory": "1Gi"}},
            "volumeMounts": [{"name": "scripts", "mountPath": "/scripts", "readOnly": True},
                {"name": "credentials", "mountPath": "/credentials", "readOnly": True}, {"name": "results", "mountPath": "/results"}]}],
        "volumes": [{"name": "scripts", "configMap": {"name": pod_name}},
            {"name": "credentials", "secret": {"secretName": "benchmark-credentials", "items": [{"key": "internal-secret", "path": "internal"}]}},
            {"name": "results", "emptyDir": {}}]}})
    observations = []
    deadline = time.monotonic() + 180 + (args.seconds + 45) * len(plan["steps"])
    while time.monotonic() < deadline:
        pod = json.loads(s.k("get", "pod", pod_name, "-o", "json").stdout)
        status = pod.get("status", {})
        observations.append({"at": time.time(), "podPhase": status.get("phase"),
            "actorPods": json.loads(s.k("get", "pods", "-l", "app.kubernetes.io/name=relaycast", "-o", "json").stdout),
            "nodeStats": json.loads(s.k("get", "--raw", "/api/v1/nodes/" + NAME + "-control-plane/proxy/stats/summary", namespace=None).stdout)})
        if status.get("phase") in {"Failed", "Succeeded"}:
            break
        # The script stays alive after writing its report so it can be read.
        found = s.k("exec", pod_name, "--", "test", "-f", "/results/report.json", check=False)
        if found.returncode == 0:
            report = json.loads(s.k("exec", pod_name, "--", "cat", "/results/report.json").stdout)
            directory = s.state / "runs" / run_id
            directory.mkdir(parents=True, mode=0o700)
            private_json(directory / "report.json", report)
            private_json(directory / "resources.json", observations)
            private_json(directory / "identity.json", {"clusterUid": s.cluster_uid(s.kubeconfig),
                "build": json.loads((s.state / "actor-build/images.json").read_text()), "infraRevision": s.cmd(["git", "-C", root, "rev-parse", "HEAD"]).stdout.strip()})
            print(json.dumps({"directory": str(directory), "status": report["status"], "steps": report.get("steps", [])}))
            s.k("delete", "pod", pod_name, "--wait=true")
            s.k("delete", "configmap", pod_name)
            return
        time.sleep(5)
    raise StackError("benchmark generator failed or timed out; retained its isolated pod for diagnostics")


if __name__ == "__main__":
    main()
