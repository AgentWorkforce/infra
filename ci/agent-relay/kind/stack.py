#!/usr/bin/env python3
"""Shared local kind helpers. Every Kubernetes call uses a private kubeconfig.

The native installers (local_stack.py for make local-up, native_core_cli.py for
the native core installer) build on this module. Its own single-phase install
(make kind-up) was retired with the standalone RelayHistory server and refuses.
No cloud CLI, registry publication, global Docker configuration or host trust
store changes. PyYAML is a prerequisite, shared with the chart verification.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
NS = "agent-relay"
RELEASE = "agent-relay"
NODE = "kindest/node:v1.34.3@sha256:08497ee19eace7b4b5348db5c6a1591d7752b164530a36f855cb0f2bdcbadd48"
POSTGRES = "pgvector/pgvector:pg17@sha256:7d0a41464797aeb9862dfdc0bbf1526b82cfd324cdd8036df19e3545f4a9ccb8"
PROBE = "busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec"
CALICO_URL = "https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/calico.yaml"
CALICO_SHA = "4b2e4053abc87427c214128f0e1b065d2f0dbadeb6be4ca3bdc6754e33af0ca7"
TRAEFIK_CHART = "42.3.1"
HOSTS = [f"{s}.kind.agentrelay.com" for s in ("relay", "cast", "history", "files")]
RETIRED = ("the single-phase kind profile (make kind-up, kind-render, kind-proof, kind-reconcile-names) "
           "was retired with the standalone RelayHistory server; History is always the native Sessions "
           "path now. Use make local-up (docs/local-development.md) or the native core installer "
           "(docs/native-kind-core-lifecycle.md). make kind-down PROFILE=core|addons still deletes an "
           "owned legacy cluster. Nothing was changed.")


class StackError(Exception):
    def __init__(self, message, *, safe_code="transport_failure", details=None):
        super().__init__(message)
        self.safe_code = safe_code if safe_code in {"transport_failure", "command_failed", "command_timeout"} else "transport_failure"
        from native_diagnostics import validate_details
        self.safe_details = validate_details(details)


def helm_list_all_args(version):
    """List every release state on Helm 3 and 4, including failed/pending."""
    match = re.fullmatch(r"v([34])\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", version.strip())
    if match is None:
        raise StackError("unsupported Helm release-list version")
    return ["helm", "list", "-n", NS, *(["--all"] if match[1] == "3" else []), "-o", "json"]


def run(argv, *, data=None, timeout=600, sensitive=False, check=True, env=None):
    """Capture output so commands with secrets on stdin never echo them."""
    try:
        p = subprocess.run([str(a) for a in argv], input=data, capture_output=True,
                           text=True, timeout=timeout, cwd=ROOT, env=env)
    except subprocess.TimeoutExpired:
        from native_diagnostics import command_details
        raise StackError(f"{argv[0]} timed out after {timeout}s", safe_code="command_timeout",
                         details=command_details(argv, timeout=True)) from None
    if check and p.returncode:
        detail = "credential-bearing operation failed; output withheld" if sensitive else (p.stderr or p.stdout)[-2500:]
        from native_diagnostics import command_details
        raise StackError(f"{argv[0]} exited {p.returncode}: {detail}", safe_code="command_failed",
                         details=command_details(argv, exit_code=p.returncode, stdout=p.stdout, stderr=p.stderr))
    return p


def private_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")
    path.chmod(0o600)


class Stack:
    def __init__(self, profile):
        if profile not in ("core", "addons"):
            raise StackError("profile must be core or addons")
        self.profile = profile
        self.root = ROOT
        # Select the identity before any state-directory filesystem access.
        self.name, self.state = self.identity_layout(profile)
        # State contains local credentials. Keep it on the checkout's volume.
        self.prepare_private_directory(self.state, chmod=True)
        self.kubeconfig = self.state / "kubeconfig"
        self.env = dict(os.environ, KUBECONFIG=str(self.kubeconfig), TMPDIR=str(self.state / "tmp"))
        self.prepare_private_directory(Path(self.env["TMPDIR"]))
        for suffix in ("CACHE", "CONFIG", "DATA"):
            self.env[f"HELM_{suffix}_HOME"] = str(ROOT / ".kind" / "helm" / suffix.lower())
        self.overrides = self.state / "values.json"
        self.marker = self.state / "cluster.json"
        self.docker_args = ["docker"]

    def identity_layout(self, profile):
        return f"agent-relay-{profile}", self.root / ".kind" / profile

    def prepare_private_directory(self, path, chmod=False):
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        if chmod:
            path.chmod(0o700)

    def native_port_mappings(self):
        return [{"containerPort": container, "hostPort": host, "listenAddress": "127.0.0.1"}
                for container, host in ((30080, 8080), (30443, 443), (30443, 8443))]

    def cmd(self, argv, **kw):
        return run(argv, env=self.env, **kw)

    def k(self, *args, namespace=NS, **kw):
        scope = [] if namespace is None else ["-n", namespace]
        return self.cmd(["kubectl", "--kubeconfig", self.kubeconfig,
                         "--context", f"kind-{self.name}", *scope, *args], **kw)

    def apply(self, doc, chart=False):
        if chart:
            meta = doc.setdefault("metadata", {})
            meta.setdefault("labels", {})["app.kubernetes.io/managed-by"] = "Helm"
            meta.setdefault("annotations", {}).update({"meta.helm.sh/release-name": RELEASE,
                                                        "meta.helm.sh/release-namespace": NS})
        secret = doc.get("kind") == "Secret"
        # create/replace avoids kubectl's plaintext last-applied annotation.
        # Replace uses the observed resourceVersion so concurrent changes fail
        # instead of silently overwriting another writer. Preserve metadata.
        if secret:
            doc.setdefault("data", {}).update({key: base64.b64encode(value.encode()).decode()
                                                for key, value in doc.pop("stringData", {}).items()})
            namespace = doc["metadata"].get("namespace")
            existing = self.k("get", "secret", doc["metadata"]["name"], "-o", "json", "--ignore-not-found=true",
                              namespace=namespace, sensitive=True).stdout.strip()
            if existing:
                metadata = json.loads(existing)["metadata"]
                metadata.pop("managedFields", None)
                for field in ("labels", "annotations"):
                    metadata.setdefault(field, {}).update(doc["metadata"].get(field, {}))
                doc["metadata"] = metadata
            doc["metadata"].setdefault("annotations", {}).pop("kubectl.kubernetes.io/last-applied-configuration", None)
            self.k("replace" if existing else "create", "-f", "-", namespace=namespace,
                   data=json.dumps(doc), sensitive=True)
            return
        self.k("apply", "-f", "-", namespace=doc.get("metadata", {}).get("namespace"),
               data=json.dumps(doc), sensitive=secret)

    def dependencies(self):
        for name, url in [("cnpg", "https://cloudnative-pg.github.io/charts"),
                          ("minio", "https://charts.min.io/"),
                          ("open-telemetry", "https://open-telemetry.github.io/opentelemetry-helm-charts"),
                          ("traefik", "https://traefik.github.io/charts")]:
            self.cmd(["helm", "repo", "add", name, url, "--force-update"])
        self.cmd(["helm", "dependency", "build", "charts/sessions-pipeline"])
        self.cmd(["helm", "dependency", "build", "charts/agent-relay"])

    def values_args(self):
        args = ["-f", ROOT / "charts/agent-relay/values-kind-core.yaml"]
        if self.profile == "addons":
            args += ["-f", ROOT / "charts/agent-relay/values-kind-addons.yaml"]
        if self.overrides.exists():
            args += ["-f", self.overrides]
        return args

    def recipe_hash(self):
        files = [ROOT / "Makefile", ROOT / "ci/agent-relay/kind/stack.py", ROOT / "ci/agent-relay/kind/addons.py",
                 ROOT / "ci/agent-relay/kind/edge.py", ROOT / "ci/agent-relay/kind/tls.py",
                 ROOT / "ci/agent-relay/kind/native_network.py",
                 *[ROOT / "ci/agent-relay/kind" / (name + ".py") for name in
                   ("native_recipe", "native_inspect", "native_bootstrap", "native_pipeline", "native_control", "native_control_artifact",
                    "native_core_values", "native_core", "native_core_cli", "native_webapp", "native_target", "native_diagnostics")],
                 ROOT / "ci/agent-relay/kind/bootstrap.mjs", ROOT / "ci/agent-relay/kind/control.py",
                 ROOT / "ci/agent-relay/kind/storage-name-renderer/plugin.yaml",
                 ROOT / "ci/agent-relay/kind/storage-name-renderer/postrender.py",
                 ROOT / "ci/agent-relay/kind/flows-sdk/package.json",
                 ROOT / "ci/agent-relay/kind/flows-sdk/package-lock.json"]
        return hashlib.sha256(b"".join(p.read_bytes() for p in files)).hexdigest()

    def docker(self, require_space=True):
        # A broken daemon must fail before a cluster is created or images pulled.
        host = self.env.get("DOCKER_HOST") or self.cmd(
            ["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], timeout=10).stdout.strip()
        if not host.startswith("unix://"):
            raise StackError("local kind requires a local unix Docker socket; remote Docker contexts are refused")
        self.env["DOCKER_HOST"] = host
        if require_space:
            self.check_space(20 * 1024**3)
        self.cmd(["docker", "--host", host, "info", "--format", "{{.ServerVersion}}"], timeout=10)
        config = self.state / "docker-public"
        config.mkdir(mode=0o700, exist_ok=True)
        # An empty auths map makes Docker CLI auto-detect the native credential
        # helper, which can prompt for a locked login keychain over SSH. Explicit
        # anonymous entries select the file store without supplying credentials.
        public_config = {"auths": {"https://index.docker.io/v1/": {}, "ghcr.io": {}}}
        # Docker Desktop normally exposes Buildx through the user's config.
        # Our isolated credential-free config must discover the bundled plugin
        # explicitly, without adopting that user's config or credential helper.
        desktop_plugins = Path("/Applications/Docker.app/Contents/Resources/cli-plugins")
        if sys.platform == "darwin" and desktop_plugins.is_dir():
            public_config["cliPluginsExtraDirs"] = [str(desktop_plugins)]
        private_json(config / "config.json", public_config)
        # Only public images are pulled. Do not inherit a separate credential
        # source or touch the user's credential helper/global configuration.
        self.env.pop("DOCKER_AUTH_CONFIG", None)
        self.docker_args = ["docker", "--config", config, "--host", host]
        self.env.update(DOCKER_HOST=host, DOCKER_CONFIG=str(config))
        arch = self.cmd([*self.docker_args, "info", "--format", "{{.Architecture}}"], timeout=10).stdout.strip()
        self.arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(arch, arch)
        if self.arch not in ("amd64", "arm64"):
            raise StackError(f"unsupported kind host architecture: {self.arch}")

    def check_space(self, needed):
        configured = self.env.get("KIND_DOCKER_DATA_PATH")
        if configured:
            backing = Path(configured).expanduser()
        elif sys.platform == "darwin":
            backing = Path.home() / "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        else:
            host = self.env.get("DOCKER_HOST", "")
            if not host.startswith("unix://"):
                raise StackError("disk preflight requires the admitted local Docker socket")
            root = self.cmd(["docker", "--host", host, "info", "--format", "{{.DockerRootDir}}"], timeout=10).stdout.strip()
            if not root or not Path(root).is_absolute():
                raise StackError("Docker did not report an absolute storage path")
            backing = Path(root)
        if not backing.exists():
            raise StackError("cannot inspect Docker backing storage; set KIND_DOCKER_DATA_PATH to its existing host-side backing file or directory")
        free = shutil.disk_usage(backing).free
        if free < needed:
            raise StackError(f"Docker backing volume has {free / 1024**3:.1f} GiB free; this image preparation needs {needed / 1024**3:.1f} GiB. No cleanup is performed.")

    def load(self, image):
        print(f"Prepare node image {image}", flush=True)
        if not image.startswith("agent-relay-kind/"):
            # A digest-only Docker OCI archive has no RepoTags. Importing it
            # creates generic import-date aliases, which can leave stale CRI
            # names after the next archive import. Pull immutable public refs
            # through the node's CRI before any suite workload starts instead.
            nodes = self.cmd(["kind", "get", "nodes", "--name", self.name]).stdout.splitlines()
            for node in nodes:
                self.cmd([*self.docker_args, "exec", node, "crictl", "pull", image], timeout=600)
            return
        # Local add-on images have real tags and no remote registry. Keep their
        # native-platform archive transport separate from digest-only refs.
        from control import REPOSITORY, resolve, inspect_archive, alias
        local_tag = resolve(self, image)
        archive = self.state / "image.tar"
        self.cmd([*self.docker_args, "image", "save", "--platform", f"linux/{self.arch}", "-o", archive, local_tag], timeout=300)
        metadata = inspect_archive(archive, self.arch) if image.startswith(REPOSITORY + "@") else None
        if metadata and metadata["reference"] != image:
            raise StackError("local control tag changed since its pinned build receipt")
        self.cmd(["kind", "load", "image-archive", "--name", self.name, archive], timeout=300)
        if metadata:
            alias(self, image, metadata)
        archive.unlink()  # Only our own transient image transport, not Docker data.

    def pull(self, image):
        print(f"Pull {image}", flush=True)
        self.cmd([*self.docker_args, "pull", image], timeout=900)

    def cluster_uid(self, kubeconfig):
        uid = self.cmd(["kubectl", "--kubeconfig", kubeconfig,
                        "--context", f"kind-{self.name}", "get", "namespace", "kube-system",
                        "-o", "jsonpath={.metadata.uid}"], sensitive=True).stdout.strip()
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", uid):
            raise StackError("cluster returned a missing or malformed native identity")
        return uid

    def require_owned_cluster(self):
        """Validate native identity before replacing kubeconfig or mutating a cluster.

        A name and a generic node label survive cluster replacement. Old receipts
        without a native UID cannot be upgraded implicitly into deletion authority.
        """
        try:
            record = json.loads(self.marker.read_text())
        except (OSError, ValueError):
            raise StackError("missing or malformed cluster ownership receipt; explicit recovery required") from None
        expected = {"version": 1, "name": self.name, "profile": self.profile,
                    "nodeImage": NODE, "dockerHost": self.env.get("DOCKER_HOST")}
        if (not isinstance(record, dict) or type(record.get("version")) is not int or not expected["dockerHost"]
                or not expected["dockerHost"].startswith("unix://")
                or any(record.get(k) != v for k, v in expected.items())
                or not isinstance(record.get("clusterUid"), str)
                or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", record["clusterUid"])):
            raise StackError("cluster ownership receipt does not match this profile and Docker endpoint")
        from native_target import require_record
        from native_recipe import NativeRecipeError
        try:
            require_record(self, record)
        except NativeRecipeError:
            raise StackError("native instance ownership binding differs") from None
        candidate = self.state / ("ownership-" + secrets.token_hex(8) + ".kubeconfig")
        try:
            self.cmd(["kind", "export", "kubeconfig", "--name", self.name,
                      "--kubeconfig", candidate], sensitive=True)
            if self.cluster_uid(candidate) != record["clusterUid"]:
                raise StackError("cluster UID differs from the ownership receipt; refusing replacement cluster")
            nodes = json.loads(self.cmd(["kubectl", "--kubeconfig", candidate,
                "--context", f"kind-{self.name}", "get", "nodes", "-o", "json"], sensitive=True).stdout)["items"]
            if not nodes or any(n["metadata"].get("labels", {}).get("agentrelay-kind-owner") != "infra" for n in nodes):
                raise StackError("cluster node ownership labels do not match")
            candidate.chmod(0o600)
            os.replace(candidate, self.kubeconfig)
        finally:
            candidate.unlink(missing_ok=True)

    def recover(self, expected_uid):
        """Explicitly recover our legacy receipt from a prior readiness identity.

        Never derive authority from a name, labels or the live UID alone. The
        operator's expected UID must also exist in the pre-existing ready receipt.
        This action changes local records only; normal reuse still refuses legacy
        records and validates the native identity again on every invocation.
        """
        if not isinstance(expected_uid, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", expected_uid):
            raise StackError("recover requires --expected-cluster-uid from the original readiness receipt")
        try:
            legacy_bytes = self.marker.read_bytes()
            legacy = json.loads(legacy_bytes)
            ready = json.loads((self.state / "ready.json").read_text())
        except (OSError, ValueError):
            raise StackError("recovery needs the original legacy ownership and readiness receipts") from None
        if legacy != {"name": self.name, "profile": self.profile, "nodeImage": NODE}:
            raise StackError("recovery requires this profile's exact legacy receipt; versioned or foreign receipts are refused")
        if (not isinstance(ready, dict) or ready.get("profile") != self.profile
                or ready.get("clusterUid") != expected_uid
                or any(not isinstance(ready.get(k), str) or not re.fullmatch(r"[a-f0-9]{64}", ready[k])
                       for k in ("recipeSha256", "renderSha256"))):
            raise StackError("expected UID is not anchored in this profile's original readiness receipt")
        self.docker(require_space=False)
        candidate = self.state / ("ownership-" + secrets.token_hex(8) + ".kubeconfig")
        pending = self.state / ("ownership-" + secrets.token_hex(8) + ".json")
        try:
            self.cmd(["kind", "export", "kubeconfig", "--name", self.name,
                      "--kubeconfig", candidate], sensitive=True)
            if self.cluster_uid(candidate) != expected_uid:
                raise StackError("live cluster UID differs from the original receipt; recovery refused")
            nodes = json.loads(self.cmd(["kubectl", "--kubeconfig", candidate,
                "--context", f"kind-{self.name}", "get", "nodes", "-o", "json"], sensitive=True).stdout)["items"]
            if not nodes or any(n["metadata"].get("labels", {}).get("agentrelay-kind-owner") != "infra" for n in nodes):
                raise StackError("cluster node ownership labels do not match; recovery refused")
            backup = self.state / ("legacy-ownership-" + secrets.token_hex(8) + ".json")
            backup.write_bytes(legacy_bytes)
            backup.chmod(0o600)
            private_json(pending, {"version": 1, "name": self.name, "nodeImage": NODE,
                         "profile": self.profile, "dockerHost": self.env["DOCKER_HOST"],
                         "clusterUid": expected_uid})
            os.replace(pending, self.marker)
            print(f"Recovered local ownership receipt from prior UID; backup: {backup}")
            print("Cluster and kubeconfig unchanged. make kind-down can now delete it; reinstall with make local-up.")
        finally:
            candidate.unlink(missing_ok=True)
            pending.unlink(missing_ok=True)

    def cluster(self):
        if getattr(self, "native_target", None) is not None:
            raise StackError("native instance requires the explicit native core transport")
        clusters = self.cmd(["kind", "get", "clusters"], timeout=30).stdout.splitlines()
        if self.name in clusters:
            self.require_owned_cluster()
            return
        config = {"kind": "Cluster", "apiVersion": "kind.x-k8s.io/v1alpha4",
                  "networking": {"disableDefaultCNI": True, "podSubnet": "192.168.0.0/16"},
                  "nodes": [{"role": "control-plane", "labels": {"agentrelay-kind-owner": "infra"},
                             "extraPortMappings": [{"containerPort": 30080, "hostPort": 8080, "listenAddress": "127.0.0.1"},
                                                   {"containerPort": 30443, "hostPort": 8443, "listenAddress": "127.0.0.1"}]}]}
        path = self.state / "kind.yaml"
        # Retirement and cleanup commands need only the standard library.
        import yaml
        path.write_text(yaml.safe_dump(config))
        self.cmd(["kind", "create", "cluster", "--name", self.name, "--image", NODE,
                  "--config", path, "--kubeconfig", self.kubeconfig], timeout=300)
        private_json(self.marker, {"version": 1, "name": self.name, "nodeImage": NODE,
                     "profile": self.profile, "dockerHost": self.env["DOCKER_HOST"],
                     "clusterUid": self.cluster_uid(self.kubeconfig)})

    def cni(self):
        print("Install and wait for enforcing Calico CNI", flush=True)
        path = self.state / "calico.yaml"
        data = urllib.request.urlopen(CALICO_URL, timeout=30).read()
        if hashlib.sha256(data).hexdigest() != CALICO_SHA:
            raise StackError("Calico manifest checksum mismatch")
        path.write_bytes(data)
        self.k("apply", "-f", path, namespace=None, timeout=120)
        self.k("rollout", "status", "daemonset/calico-node", "--timeout=300s", namespace="kube-system", timeout=330)
        self.k("wait", "--for=condition=Ready", "nodes", "--all", "--timeout=180s", namespace=None, timeout=210)
        print("Calico and kind node ready", flush=True)

    def secret(self, name, values):
        self.apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": name, "namespace": NS},
                    "type": "Opaque", "stringData": values})

    def psql(self, database, text, variables=(), sensitive=False):
        args = ["exec", "-i", "postgres-0", "--", "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", database]
        for value in variables:
            args += ["-v", value]
        return self.k(*args, data=text, sensitive=sensitive).stdout

    def tls(self):
        from tls import create
        create(self, HOSTS, NS)

    def wait_job(self, name, seconds=600):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            status = json.loads(self.k("get", "job", name, "-o", "json").stdout).get("status", {})
            conditions = {c["type"]: c["status"] for c in status.get("conditions", [])}
            if conditions.get("Failed") == "True":
                raise StackError(f"Job {name} failed; inspect its redacted application error before retrying")
            if conditions.get("Complete") == "True":
                return status
            time.sleep(2)
        raise StackError(f"Job {name} did not complete in {seconds}s")

    def up(self):
        """Retired: the single-phase profile ran the removed standalone History.

        Refuse before any tool, Docker, readiness or cluster access so an old
        checkout's state (ready.json, ownership receipt, kubeconfig) is kept.
        """
        raise StackError(RETIRED)

    def build_addons(self):
        from addons import build
        build(self)

    def prepare_native_network(self, values_path):
        """Prepare source-owned local networking, never install the app/profile."""
        from native_network import preflight, ensure, selected_values, selection
        from edge import install
        path = Path(values_path)
        if path.is_symlink() or not path.is_file():
            raise StackError("--native-values must be a regular selected-values JSON file")
        values = json.loads(path.read_text())
        if selection(values) is None:
            raise StackError("prepare-native-network requires an enabled nativeRouting selection")
        self.docker(require_space=False)
        # This explicit preparation command operates on an existing owned
        # fixture. Full native first-boot/bootstrap is a separate recipe.
        self.require_owned_cluster()
        preflight(self, values)  # no gateway/ready/images mutation on refusal
        self.dependencies()
        base_args = ["-f", ROOT / "charts/agent-relay/values-kind-core.yaml"]
        if self.profile == "addons":
            base_args += ["-f", ROOT / "charts/agent-relay/values-kind-addons.yaml"]
        selected_args = [*base_args, "-f", path.resolve()]
        self.cmd(["helm", "template", RELEASE, "charts/agent-relay", "-n", NS, *selected_args])
        install(self, TRAEFIK_CHART, NS, wait_for_route=False)
        observation = ensure(self, values)
        selected = selected_values(values, observation)
        proposal = self.state / "native-network-values.json"
        private_json(proposal, selected)
        # Validate the allocated mapping too, before presenting the proposal.
        self.cmd(["helm", "template", RELEASE, "charts/agent-relay", "-n", NS,
                  *base_args, "-f", proposal])
        print("Prepared owned edge networking and proposed values at " + str(proposal))
        print("Active values, Helm app release, database, readiness and proof were not changed. "
              "Review/install the complete selected app values separately.")

    def down(self):
        self.docker(require_space=False)
        self.require_owned_cluster()
        self.cmd(["kind", "delete", "cluster", "--name", self.name, "--kubeconfig", self.kubeconfig], timeout=180)
        self.marker.unlink()
        ready = self.state / "ready.json"
        if ready.exists():
            ready.unlink()
        print(f"Deleted local kind cluster {self.name}; retained private state at {self.state}")


def pod_spec(doc):
    spec = doc.get("spec", {})
    if doc.get("kind") == "CronJob":
        spec = spec.get("jobTemplate", {}).get("spec", {})
    return spec.get("template", {}).get("spec", {})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("up", "down", "render", "build-addons", "build-control", "recover",
                                           "reconcile-names", "prepare-native-network"))
    parser.add_argument("--profile", choices=("core", "addons"), default="core")
    parser.add_argument("--expected-cluster-uid", help="original readiness UID; required only for explicit recover")
    parser.add_argument("--native-values", help="selected values JSON; required only for prepare-native-network")
    args = parser.parse_args()
    if args.expected_cluster_uid and args.action != "recover":
        parser.error("--expected-cluster-uid is only valid for recover")
    if (args.action == "prepare-native-network") != bool(args.native_values):
        parser.error("prepare-native-network requires --native-values; other actions must omit it")
    os.umask(0o077)
    try:
        if args.action in ("up", "render", "reconcile-names"):
            raise StackError(RETIRED)  # before any state directory is created
        stack = Stack(args.profile)
        if args.action == "build-control":
            stack.docker(require_space=False)
            from control import build
            build(stack)
        elif args.action == "recover":
            stack.recover(args.expected_cluster_uid)
        elif args.action == "build-addons":
            stack.docker(require_space=False)
            stack.build_addons()
        elif args.action == "prepare-native-network":
            stack.prepare_native_network(args.native_values)
        else:
            stack.down()
    except (StackError, OSError, ValueError) as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
