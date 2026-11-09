#!/usr/bin/env python3
"""Local-only kind lifecycle. Every Kubernetes call uses a private kubeconfig.

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
import tempfile
import time
import urllib.request

import yaml

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


class StackError(Exception):
    pass


def run(argv, *, data=None, timeout=600, sensitive=False, check=True, env=None):
    """Capture output so commands with secrets on stdin never echo them."""
    try:
        p = subprocess.run([str(a) for a in argv], input=data, capture_output=True,
                           text=True, timeout=timeout, cwd=ROOT, env=env)
    except subprocess.TimeoutExpired:
        raise StackError(f"{argv[0]} timed out after {timeout}s") from None
    if check and p.returncode:
        detail = "credential-bearing operation failed; output withheld" if sensitive else (p.stderr or p.stdout)[-2500:]
        raise StackError(f"{argv[0]} exited {p.returncode}: {detail}")
    return p


def private_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")
    path.chmod(0o600)


def auth_signing_key(stack):
    """RelayAuth requires PKCS#8; preserve legacy RSA identity on conversion."""
    key = stack.state / "auth-signing.pem"
    legacy = key.exists() and key.read_bytes().startswith(b"-----BEGIN RSA PRIVATE KEY-----")
    if key.exists() and not legacy:
        key.chmod(0o600)
        if not key.read_bytes().startswith(b"-----BEGIN PRIVATE KEY-----"):
            raise StackError("local RelayAuth signing key is not unencrypted PKCS#8")
        stack.cmd(["openssl", "pkey", "-in", key, "-pubout"], sensitive=True)
        return key
    fd, name = tempfile.mkstemp(prefix="auth-signing-", suffix=".pem", dir=stack.state)
    os.close(fd)
    temporary = Path(name)
    try:
        if legacy:
            key.chmod(0o600)
            original_public = stack.cmd(["openssl", "pkey", "-in", key, "-pubout"], sensitive=True).stdout
            stack.cmd(["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", key, "-out", temporary], sensitive=True)
        else:
            stack.cmd(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", temporary], sensitive=True)
        temporary.chmod(0o600)
        if not temporary.read_bytes().startswith(b"-----BEGIN PRIVATE KEY-----"):
            raise StackError("OpenSSL did not produce a PKCS#8 RelayAuth signing key")
        public = stack.cmd(["openssl", "pkey", "-in", temporary, "-pubout"], sensitive=True).stdout
        if legacy:
            if public != original_public:
                raise StackError("RelayAuth key conversion changed the signing identity")
            backup = key.with_name("auth-signing.pkcs1-backup.pem")
            if backup.exists():
                if backup.read_bytes() != key.read_bytes():
                    raise StackError("existing RelayAuth key backup differs; refusing to overwrite it")
                backup.chmod(0o600)
            else:
                with backup.open("xb") as stream:
                    os.chmod(backup, 0o600)
                    stream.write(key.read_bytes())
            os.replace(temporary, key)
        else:
            os.link(temporary, key)  # Refuse a concurrently created signing key.
        return key
    finally:
        temporary.unlink(missing_ok=True)  # Only this conversion/generation's file.


def tenant_values(values, ids, profile, arch, recipe):
    """Set discovered tenant IDs without dropping selected images or settings."""
    values.setdefault("global", {}).setdefault("tenant", {})["orgId"] = ids["orgId"]
    pipeline = values.setdefault("sessions-pipeline", {})
    worker = pipeline.setdefault("worker", {})
    worker.setdefault("tenant", {}).update({"orgId": ids["orgId"], "workspaceId": ids["workspaceId"]})
    worker.setdefault("podAnnotations", {})["kind.agentrelay.dev/bootstrap-source"] = recipe
    pipeline.setdefault("alleyoop", {}).setdefault("tenant", {}).update({"orgId": ids["orgId"], "workspaceId": ids["workspaceId"]})
    if profile == "addons":
        values.setdefault("relayflows", {}).setdefault("nodeSelector", {})["kubernetes.io/arch"] = arch
    return values


class Stack:
    def __init__(self, profile):
        if profile not in ("core", "addons"):
            raise StackError("profile must be core or addons")
        self.profile = profile
        self.name = f"agent-relay-{profile}"
        # State contains local credentials. Keep it on the checkout's volume.
        self.state = ROOT / ".kind" / profile
        self.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.state.chmod(0o700)
        self.kubeconfig = self.state / "kubeconfig"
        self.env = dict(os.environ, KUBECONFIG=str(self.kubeconfig), TMPDIR=str(self.state / "tmp"))
        Path(self.env["TMPDIR"]).mkdir(mode=0o700, exist_ok=True)
        for suffix in ("CACHE", "CONFIG", "DATA"):
            self.env[f"HELM_{suffix}_HOME"] = str(ROOT / ".kind" / "helm" / suffix.lower())
        self.overrides = self.state / "values.json"
        self.marker = self.state / "cluster.json"
        self.docker_args = ["docker"]

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

    def render(self):
        raw = self.cmd(["helm", "template", RELEASE, "charts/agent-relay", "-n", NS,
                        *self.values_args()]).stdout
        (self.state / "rendered.yaml").write_text(raw)
        return [d for d in yaml.safe_load_all(raw) if d]

    def recipe_hash(self):
        files = [ROOT / "Makefile", ROOT / "ci/agent-relay/kind/stack.py", ROOT / "ci/agent-relay/kind/addons.py",
                 ROOT / "ci/agent-relay/kind/edge.py", ROOT / "ci/agent-relay/kind/tls.py",
                 ROOT / "ci/agent-relay/kind/bootstrap.mjs", ROOT / "ci/agent-relay/kind/control.py",
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
        private_json(config / "config.json", {"auths": {
            "https://index.docker.io/v1/": {}, "ghcr.io": {}}})
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

    def image_space(self, images):
        # Warm setups need room for native node copies, not another complete
        # cold registry cache. Measure cached native images instead of blocking
        # a small configuration fix behind the cold-install budget.
        size = 2 * 1024**3  # CNI, local volumes and unpacking headroom.
        from control import resolve
        for image in set(images):
            p = self.cmd([*self.docker_args, "image", "inspect", "--format", "{{.Size}} {{.Architecture}}", resolve(self, image)], check=False)
            fields = p.stdout.split()
            if p.returncode or len(fields) != 2 or fields[1] != self.arch:
                self.check_space(20 * 1024**3)
                return
            size += int(fields[0])
        self.check_space(size)

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
            print("Cluster and kubeconfig unchanged. Rerun kind-up before acceptance.")
        finally:
            candidate.unlink(missing_ok=True)
            pending.unlink(missing_ok=True)

    def cluster(self):
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

    def credentials(self):
        path = self.state / "credentials.json"
        s = json.loads(path.read_text()) if path.exists() else {}
        for k in ("postgres", "hoop", "runtime", "history_owner", "history_runtime", "control_owner", "control_api_runtime",
                  "relayfile", "bootstrap", "encryption", "internal", "auth_internal", "auth_key", "cast", "cast_bootstrap", "locker"):
            s.setdefault(k, secrets.token_hex(32))
        private_json(path, s)
        key = auth_signing_key(self)
        db = lambda user, database: f"postgresql://{user}:{s[user]}@postgres.{NS}.svc.cluster.local:5432/{database}"
        self.secret("kind-postgres", {"password": s["postgres"]})
        self.secret("kind-cast", {"internal-secret": s["cast"], "workspace-bootstrap-secret": s["cast_bootstrap"]})
        self.secret("kind-auth", {"internal-secret": s["auth_internal"], "signing-key.pem": key.read_text(), "bootstrap-api-key": s["auth_key"]})
        self.secret("kind-control", {"database-url": db("control_api_runtime", "relaycontrol"),
            "database-migrations-url": db("control_owner", "relaycontrol"), "relayauth-api-key": s["auth_key"],
            "selfhost-bootstrap-token": s["bootstrap"], "selfhost-encryption-key": s["encryption"],
            "selfhost-internal-token": s["internal"], "relaycast-internal-secret": s["cast"]})
        runtime = f"postgresql://sessions_pipeline_runtime:{s['runtime']}@postgres.{NS}.svc.cluster.local:5432/hoopdb"
        self.secret("kind-pipeline", {"HOOPDB_URL": runtime, "HOOPDB_MIGRATION_URL": db("hoop", "hoopdb"),
                    "rootUser": "locker", "rootPassword": s["locker"], "SUMMARY_MASTER_KEYS": "kind1:" + s["encryption"]})
        self.secret("kind-history-db", {"DATABASE_URL": db("history_runtime", "relayhistory"),
                                       "DATABASE_MIGRATIONS_URL": db("history_owner", "relayhistory")})
        if self.profile == "addons":
            self.secret("kind-relayfile", {"RELAYFILE_INTERNAL_HMAC_SECRET": s["internal"],
                                          # lib/pq defaults to TLS; local Postgres has TLS off.
                                          "RELAYFILE_PRODUCTION_DSN": db("relayfile", "relayfile") + "?sslmode=disable"})
            self.secret("kind-addon-license", {"license": Path(os.environ["KIND_LICENSE_FILE"]).read_text()})
        return s

    def postgres(self, s, services_image):
        labels = {"app": "kind-postgres"}
        self.apply({"apiVersion": "v1", "kind": "Service", "metadata": {"name": "postgres", "namespace": NS},
                    "spec": {"selector": labels, "ports": [{"port": 5432}]}})
        self.apply({"apiVersion": "apps/v1", "kind": "StatefulSet", "metadata": {"name": "postgres", "namespace": NS},
          "spec": {"serviceName": "postgres", "replicas": 1, "selector": {"matchLabels": labels},
            "template": {"metadata": {"labels": labels}, "spec": {"containers": [{"name": "postgres", "image": POSTGRES,
              "env": [{"name": "POSTGRES_PASSWORD", "valueFrom": {"secretKeyRef": {"name": "kind-postgres", "key": "password"}}},
                      {"name": "PGDATA", "value": "/var/lib/postgresql/data/pgdata"}],
              "ports": [{"containerPort": 5432}], "volumeMounts": [{"name": "data", "mountPath": "/var/lib/postgresql/data"}],
              "readinessProbe": {"exec": {"command": ["pg_isready", "-U", "postgres"]}, "periodSeconds": 3}}]}},
            "volumeClaimTemplates": [{"metadata": {"name": "data"}, "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "4Gi"}}}}]}})
        self.k("rollout", "status", "statefulset/postgres", "--timeout=180s", timeout=210)
        sql = []
        for role in ("hoop", "history_owner", "history_runtime", "control_owner", "control_api_runtime", "relayfile"):
            sql.append(f"SELECT 'CREATE ROLE {role} LOGIN PASSWORD ''{s[role]}''' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='{role}') \\gexec")
        for database, owner in (("hoopdb", "hoop"), ("relayhistory", "history_owner"),
                                ("relaycontrol", "control_owner"), ("relayfile", "relayfile")):
            sql.append(f"SELECT 'CREATE DATABASE {database} OWNER {owner}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='{database}') \\gexec")
        self.psql("postgres", "\n".join(sql), sensitive=True)
        for database in ("hoopdb", "relayhistory"):
            self.psql(database, "CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pg_trgm;")
        # The migration owner is deliberately not a superuser. Reuse the
        # CNPG chart's compatibility-role definitions before its role shim.
        fixture = yaml.safe_load((ROOT / "charts/sessions-pipeline/values.yaml").read_text())
        for statement in fixture["hoopdb"]["cluster"]["initdb"]["postInitApplicationSQL"]:
            match = re.match(r"CREATE ROLE (anon|authenticated|service_role) ", statement)
            if match:
                role = match.group(1)
                literal = statement.replace("'", "''")
                self.psql("hoopdb", f"SELECT '{literal}' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='{role}') \\gexec")
        # Use bootstrap bytes from exactly the services image being installed.
        for name in ("session_directory_search_worker", "session_token_verifier", "session_ingest_roles",
                     "hoopdb_runtime_role", "hoopdb_function_default_revoke"):
            text = self.cmd([*self.docker_args, "run", "--rm", "--network", "none", "--entrypoint", "cat",
                             services_image, f"/app/supabase/bootstrap/{name}.sql"]).stdout
            self.psql("hoopdb", text, variables=["runtime_role=sessions_pipeline_runtime", "runtime_login=true", "migration_owner=hoop"])
        self.psql("hoopdb", f"ALTER ROLE sessions_pipeline_runtime PASSWORD '{s['runtime']}';", sensitive=True)

    def psql(self, database, text, variables=(), sensitive=False):
        args = ["exec", "-i", "postgres-0", "--", "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", database]
        for value in variables:
            args += ["-v", value]
        return self.k(*args, data=text, sensitive=sensitive).stdout

    def tls(self):
        from tls import create
        create(self, HOSTS, NS)

    def migration(self, docs, app, component=None):
        print(f"Run chart Job {app}/{component or 'migration'}", flush=True)
        jobs = [d for d in docs if d["kind"] == "Job" and d["metadata"].get("labels", {}).get("app.kubernetes.io/name") == app
                and (component is None or d["metadata"].get("labels", {}).get("app.kubernetes.io/component") == component)]
        if len(jobs) != 1:
            raise StackError(f"expected one {app}/{component} Job, found {len(jobs)}")
        job = jobs[0]
        self.apply(job, chart=True)
        status = self.wait_job(job["metadata"]["name"])
        if status.get("failed", 0):
            raise StackError(f"{app}/{component} had failed attempts; refusing to hide a startup race")

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

    def require_no_legacy_storage(self):
        if not self.k("get", "namespace", NS, "--ignore-not-found", "-o", "json", namespace=None).stdout.strip():
            return  # A previously created, owned cluster may still be empty.
        objects = json.loads(self.k("get", "deploy,pvc", "-o", "json").stdout).get("items", [])
        for item in objects:
            metadata = item.get("metadata", {})
            if metadata.get("name") == "locker" or metadata.get("annotations", {}).get("meta.helm.sh/release-name") == "kind-locker":
                raise StackError("legacy kind-locker storage exists: preserve its release/PVC and complete a reviewed data-preserving cutover before kind-up; no reset or replacement was attempted")

    def require_control_webapp_layout(self):
        """A public-name change must not orphan the existing QA resources."""
        if not self.k("get", "namespace", NS, "--ignore-not-found", "-o", "json", namespace=None).stdout.strip():
            return
        resources = json.loads(self.k("get", "deployments,services", "-o", "json").stdout)
        legacy = []
        for resource in resources.get("items", []):
            meta = resource.get("metadata", {})
            name = meta.get("name", "")
            app = meta.get("labels", {}).get("app.kubernetes.io/name", "")
            if name in ("relaycontrol", "relay-app") or app in ("relay-cloud-api", "relay-dashboard"):
                legacy.append(resource.get("kind", "resource") + "/" + name)
        if legacy:
            raise StackError("existing Control/Webapp layout requires a reviewed identity-preserving upgrade; "
                             "kind-up refuses before changing ready.json, images or cluster resources: "
                             + ", ".join(sorted(legacy)))

    def up(self):
        for tool in ("docker", "kind", "kubectl", "helm", "openssl", "git"):
            if not shutil.which(tool):
                raise StackError(f"missing prerequisite: {tool}")
        self.docker(require_space=False)
        # Legacy recovery needs the original ready.json as an independent UID
        # anchor. Refuse foreign/legacy ownership BEFORE invalidating it or
        # preparing any images/resources; cluster() checks again before use.
        if self.name in self.cmd(["kind", "get", "clusters"], timeout=30).stdout.splitlines():
            self.require_owned_cluster()
            self.require_no_legacy_storage()
            self.require_control_webapp_layout()
        ready = self.state / "ready.json"
        if ready.exists():
            ready.unlink()
        if self.profile == "addons":
            if not os.environ.get("KIND_LICENSE_FILE"):
                raise StackError("PENDING: set KIND_LICENSE_FILE to the owner-supplied signed offline license; enforcement is not shipped yet")
        self.dependencies()
        docs = self.render()
        images = sorted({c["image"] for d in docs for c in pod_spec(d).get("containers", []) + pod_spec(d).get("initContainers", [])})
        if self.profile == "addons":
            self.build_addons()
        self.image_space([NODE, POSTGRES, PROBE, *images])
        for image in [NODE, POSTGRES, PROBE, *images]:
            if not image.startswith("agent-relay-kind/"):
                self.pull(image)
        self.cluster()
        self.cni()
        self.apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": NS}})
        for image in [POSTGRES, PROBE, *images]:
            self.load(image)
        s = self.credentials()
        self.tls()
        for d in docs:
            if d["kind"] in ("NetworkPolicy", "ServiceAccount", "ConfigMap", "PersistentVolumeClaim"):
                self.apply(d, chart=True)
        services_image = next(i for i in images if "/96bulls-services@" in i)
        generation = self.cmd([*self.docker_args, "run", "--rm", "--network", "none", "--entrypoint", "bun", services_image,
                               "src/hoopdb/migrate.ts", "--generation"]).stdout.strip()
        if not re.fullmatch(r"[a-f0-9]{64}", generation):
            raise StackError("services image did not return an exact migration generation")
        catalog = yaml.safe_load((ROOT / "self-hosted/customer-images.yaml").read_text())["images"]
        source = next((i["source"]["revision"] for i in catalog
                       if i["current"]["repository"] + "@" + i["current"]["digest"] == services_image), None)
        if not source:
            raise StackError("services image has no exact audited source SHA in customer-images.yaml")
        private_json(self.state / "images.json", {"images": images, "servicesGeneration": generation,
                     "servicesSourceRevision": source,
                     "infraRevision": self.cmd(["git", "rev-parse", "HEAD"]).stdout.strip()})
        self.postgres(s, services_image)
        locker_values = self.state / "locker-values.json"
        defaults = yaml.safe_load((ROOT / "charts/sessions-pipeline/values.yaml").read_text())["session-object-storage"]
        defaults.update(existingSecret="kind-pipeline", persistence={"enabled": True, "size": "2Gi"})
        private_json(locker_values, defaults)
        self.cmd(["helm", "upgrade", "--install", "kind-session-object-storage", "charts/sessions-pipeline/charts/minio-5.4.0.tgz", "-n", NS,
                  "-f", locker_values, "--wait", "--timeout", "5m"], timeout=330)
        for d in docs:
            if d["kind"] in ("Deployment", "Service") and d["metadata"]["name"] in ("relaycast", "relayauth"):
                self.apply(d, chart=True)
        self.migration(docs, "relay-control")
        for d in docs:
            if d["kind"] in ("Deployment", "Service") and d["metadata"]["name"] == "relay-control":
                self.apply(d, chart=True)
        self.k("rollout", "status", "deployment/relay-control", "--timeout=180s", timeout=210)
        # Query the real first-boot records, not a fixture organization id.
        bootstrap = (ROOT / "ci/agent-relay/kind/bootstrap.mjs").read_text()
        self.k("exec", "-i", "deploy/relay-control", "--", "sh", "-c", "cat > /tmp/kind-bootstrap.mjs", data=bootstrap)
        bootstrap_name = next((e["value"] for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "relay-control"
                              for e in pod_spec(d)["containers"][0]["env"] if e["name"] == "SELFHOST_BOOTSTRAP_WORKSPACE_NAME"), "Default")
        ids = json.loads(self.k("exec", "deploy/relay-control", "--", "node", "/tmp/kind-bootstrap.mjs", bootstrap_name).stdout)
        private_json(self.state / "tenant.json", ids)
        values = json.loads(self.overrides.read_text()) if self.overrides.exists() else {}
        private_json(self.overrides, tenant_values(values, ids, self.profile, self.arch, self.recipe_hash()))
        docs = self.render()
        final_images = sorted({c["image"] for d in docs for c in pod_spec(d).get("containers", []) + pod_spec(d).get("initContainers", [])})
        if final_images != images:
            raise StackError("tenant bootstrap changed the selected image set; readiness refused")
        # Helm dependency alias "worker" is the rendered app name.
        self.migration(docs, "worker", "locker-init")
        self.migration(docs, "worker", "hoopdb-migrate")
        # Match the existing EKS installer's database isolation. Each migrator
        # owns its schema in a distinct database; never co-locate both in HoopDB.
        self.migration(docs, "relayhistory")
        acl_job = self.verify_combined_acl(services_image)
        # Bootstrap applies the same release objects client-side before Helm
        # can wait for the whole suite. Keep that mode on Helm 4 as well; its
        # default SSA conflicts when bootstrap changes the control image.
        help_text = self.cmd(["helm", "upgrade", "--help"]).stdout
        apply_mode = ["--server-side=false"] if "--server-side" in help_text else []
        self.cmd(["helm", "upgrade", "--install", RELEASE, "charts/agent-relay", "-n", NS,
                  *self.values_args(), *apply_mode, "--wait", "--wait-for-jobs", "--timeout", "10m"], timeout=660)
        from edge import install
        install(self, TRAEFIK_CHART, NS)
        private_json(ready, {"profile": self.profile, "recipeSha256": self.recipe_hash(),
                     "renderSha256": hashlib.sha256((self.state / "rendered.yaml").read_bytes()).hexdigest(),
                     "clusterUid": self.k("get", "namespace", "kube-system", "-o", "jsonpath={.metadata.uid}", namespace=None).stdout,
                     "ownershipVersion": json.loads(self.marker.read_text())["version"],
                     "combinedAclJob": acl_job, "nodeImage": NODE,
                     "infraRevision": self.cmd(["git", "rev-parse", "HEAD"]).stdout.strip()})
        print(f"Ready: https://{HOSTS[0]}:8443; local trust certificate: {self.state / 'ca.crt'}")
        print(f"Desktop host entries: {self.state / 'hosts'}. Run make kind-proof PROFILE={self.profile}; readiness is not an E2E pass.")

    def verify_combined_acl(self, image):
        # Recheck after BOTH migrators. Database isolation, rather than ordering
        # or a manifest union, must preserve the pipeline's own ACL contract.
        code = '''import {runtimeRoleViolations,sessionsFunctionAclPreview} from "/app/src/hoopdb/migrate-guards.ts";
import {openHoopDb} from "/app/src/shared/db.ts";
const db=openHoopDb();
try {
 const role=await runtimeRoleViolations(db,{mode:"selfhosted",role:"sessions_pipeline_runtime",login:true},{ledger:"sessions.__96bulls_migrations",marker:"sessions.__96bulls_role_validation"},"post");
 const acl=await sessionsFunctionAclPreview(db,"sessions_pipeline_runtime",false);
 const drift=[...role,...acl.function_acl_drift_extra,...acl.function_acl_missing_refused,...acl.function_acl_missing];
 console.log(JSON.stringify({check:"combined-runtime-acl",violations:drift}));
 if(drift.length)process.exitCode=1;
} catch(e) {console.log(JSON.stringify({check:"combined-runtime-acl",error:e.code||"check_failed"}));process.exitCode=1;}
finally {await db.end();}'''
        spec = {"backoffLimit": 0, "activeDeadlineSeconds": 60, "template": {"spec": {
            "restartPolicy": "Never", "automountServiceAccountToken": False, "containers": [
                {"name": "check", "image": image, "command": ["bun", "-e", code], "env": [
                    {"name": "HOOPDB_URL", "valueFrom": {"secretKeyRef": {"name": "kind-pipeline", "key": "HOOPDB_MIGRATION_URL"}}}]}]}}}
        # A terminal Job is not a current database check. Keep every attempt
        # distinct, including failures, rather than adopting a prior result.
        name = "kind-combined-acl-" + secrets.token_hex(8)
        self.apply({"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": name, "namespace": NS}, "spec": spec})
        self.wait_job(name, 90)
        return name

    def build_addons(self):
        from addons import build
        build(self)

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
    parser.add_argument("action", choices=("up", "down", "render", "build-addons", "build-control", "recover"))
    parser.add_argument("--profile", choices=("core", "addons"), default="core")
    parser.add_argument("--expected-cluster-uid", help="original readiness UID; required only for explicit recover")
    args = parser.parse_args()
    if args.expected_cluster_uid and args.action != "recover":
        parser.error("--expected-cluster-uid is only valid for recover")
    os.umask(0o077)
    try:
        stack = Stack(args.profile)
        if args.action == "render":
            stack.dependencies()
            stack.render()
            print(stack.state / "rendered.yaml")
        elif args.action == "build-control":
            stack.docker(require_space=False)
            from control import build
            build(stack)
        elif args.action == "recover":
            stack.recover(args.expected_cluster_uid)
        elif args.action == "build-addons":
            stack.docker(require_space=False)
            stack.build_addons()
        else:
            getattr(stack, args.action)()
    except (StackError, OSError, ValueError) as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
