#!/usr/bin/env python3
"""An explicit, existing-Kind development session. No provisioning or migrations."""
import argparse
import copy
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import signal
import subprocess
import sys
import tarfile
import time
import uuid
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
HEX = re.compile(r"^[0-9a-f]{40}$")
NAME = re.compile(r"^[a-z0-9][a-z0-9.-]{0,62}$")
IGNORE = {".git", "node_modules", "target", "dist", ".kind", ".next", "__pycache__"}
MAX_BYTES = 256 * 1024 * 1024
ROLES = {"webapp", "control", "ingest", "reader", "consumer", "brief", "cast", "collector", "file", "flows"}


class Refused(Exception):
    def __init__(self, code, diagnostics=None):
        super().__init__(code)
        self.diagnostics = diagnostics or []


class BuildFailed(Refused):
    """A completed, failed build did not replace the running application."""


def need(ok, code):
    if not ok:
        raise Refused(code)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def emit(stage, **data):
    print(json.dumps({"stage": stage, **data}, sort_keys=True), flush=True)


def compiler_diagnostics(raw):
    # File/line/compiler-code only. Never echo source snippets, quoted values,
    # process environment, URLs, SQL or arbitrary compiler/plugin messages.
    text = re.sub(r"\x1b\[[0-9;]*m", "", raw[:131072].decode("utf8", "replace"))
    found = []
    for line in text.splitlines():
        match = re.search(r"((?:src|packages|crates|cmd|internal|apps)/[A-Za-z0-9_./-]+\.(?:tsx?|jsx?|rs|go|mjs))[:(](\d+)(?:[:,](\d+))?", line)
        code = re.search(r"\b(?:TS\d{4,5}|E\d{4})\b", line)
        if match or code:
            row = {}
            if match: row.update(file=match[1], line=int(match[2]), column=int(match[3] or 0))
            if code: row["code"] = code[0]
            if row not in found: found.append(row)
        if len(found) >= 20: break
    return found


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write("\n")


class Commands:
    def __init__(self):
        self.docker_context = None
        self.public_docker_config = None
        self.docker_host = None

    def run(self, argv, data=None, timeout=120):
        # Never echo environment, subprocess output or cluster error bodies.
        try:
            env = dict(os.environ)
            if self.docker_context:
                env["DOCKER_CONTEXT"] = self.docker_context
            if self.public_docker_config:
                env["DOCKER_CONFIG"] = self.public_docker_config
                # The anonymous config has no context metadata. Bind the same
                # explicitly selected local socket for Docker and Kind.
                env.pop("DOCKER_CONTEXT", None)
                env["DOCKER_HOST"] = self.docker_host
                for key in ("DOCKER_AUTH_CONFIG", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"):
                    env.pop(key, None)
            p = subprocess.run([str(x) for x in argv], input=data, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=timeout, check=False, env=env)
        except subprocess.TimeoutExpired:
            raise Refused("command_deadline_exceeded") from None
        except OSError:
            raise Refused("command_unavailable") from None
        if p.returncode:
            raise Refused("command_failed_" + str(p.returncode), compiler_diagnostics(p.stdout + p.stderr))
        return p.stdout

    def json(self, argv):
        return json.loads(self.run(argv))


def load_config(path):
    c = json.loads(Path(path).read_text())
    need(c.get("version") == 1, "config_version")
    need(c.get("developmentOnly") is True, "dev_only_required")
    for key in ("context", "cluster", "namespace", "clusterUid", "namespaceUid"):
        need(isinstance(c.get(key), str) and c[key] and "\n" not in c[key], "target_binding_required")
    need(c["context"] == "kind-" + c["cluster"], "kind_context_required")
    need(c.get("architecture") in ("arm64", "amd64"), "architecture_required")
    need(isinstance(c.get("dockerContext"), str) and c["dockerContext"], "docker_context_required")
    need(bool(c.get("publicDockerConfig")) == bool(c.get("dockerHost")), "anonymous_local_docker_endpoint_required")
    if c.get("publicDockerConfig"):
        validate_public_docker_config(c["publicDockerConfig"])
        endpoint = urlsplit(c.get("dockerHost", ""))
        need(endpoint.scheme == "unix" and not endpoint.netloc and endpoint.path.startswith("/") and
             not endpoint.query and not endpoint.fragment and not any(ord(x) < 32 for x in c["dockerHost"]), "anonymous_local_docker_endpoint_required")
    need(Path(c["kubeconfig"]).is_file(), "explicit_kubeconfig_required")
    need(c.get("groups") and c.get("protectedDeployments"), "coverage_required")
    roles, names = set(), set()
    for g in c["groups"]:
        need(NAME.fullmatch(g["name"]), "group_name")
        repo = Path(g["repo"]).resolve()
        need((g.get("sourceUnavailable") is True and g.get("baselineRevision") is None) or
             (isinstance(g.get("baselineRevision"), str) and HEX.fullmatch(g["baselineRevision"])), "source_binding")
        need(g["mode"] in ("rebuild", "frontend-hmr"), "mode")
        need(g.get("targets"), "targets_required")
        for t in g["targets"]:
            need(t["role"] in ROLES and t["role"] not in roles, "role_duplicate_or_unknown")
            need(NAME.fullmatch(t["deployment"]) and NAME.fullmatch(t["container"]), "workload_name")
            need(t["deployment"] not in names, "duplicate_deployment")
            need(isinstance(t["uid"], str) and t["uid"], "uid_required")
            roles.add(t["role"]); names.add(t["deployment"])
        need((g["mode"] == "frontend-hmr") == ({t["role"] for t in g["targets"]} == {"webapp"}), "frontend_group")
        if g["mode"] == "frontend-hmr":
            url = urlsplit(c.get("publicOrigin", ""))
            need(url.scheme == "https" and url.hostname and not url.username and not url.password and
                 url.path in ("", "/") and not url.query and not url.fragment, "https_origin_required")
    need({"webapp", "control", "ingest", "reader", "consumer", "brief", "cast", "collector"} <= roles,
         "whole_core_coverage_required")
    need(not names.intersection(c["protectedDeployments"]), "stateful_target_forbidden")
    for role in ("file", "flows", "desktop", "chief"):
        need(role in roles or isinstance(c.get("excluded", {}).get(role), str), "optional_coverage_reason_required")
    return c


def validate_public_docker_config(path):
    """Opt-in anonymous pulls; never change the developer's credential store."""
    try:
        value = json.loads((Path(path) / "config.json").read_text())
    except (OSError, ValueError, TypeError):
        raise Refused("anonymous_docker_config_required") from None
    need(isinstance(value, dict) and set(value) == {"auths"} and isinstance(value["auths"], dict)
         and bool(value["auths"]) and all(item == {} for item in value["auths"].values()), "anonymous_docker_config_required")


def select_components(config, value):
    if value == "all":
        return copy.deepcopy(config)
    requested = set(value.split(","))
    available = {g["name"] for g in config["groups"]} | {t["role"] for g in config["groups"] for t in g["targets"]}
    need(requested and requested <= available, "unknown_component_selection")
    selected = copy.deepcopy(config)
    selected["groups"] = []
    protected = set(config["protectedDeployments"])
    for g in config["groups"]:
        targets = [t for t in g["targets"] if g["name"] in requested or t["role"] in requested]
        protected.update(t["deployment"] for t in g["targets"] if t not in targets)
        if targets:
            group = copy.deepcopy(g); group["targets"] = targets; selected["groups"].append(group)
    selected["protectedDeployments"] = sorted(protected)
    selected["selectedComponents"] = sorted(requested)
    return selected


class SourceFiles(dict):
    gitlinks = ()


def source_files(repo, cmd):
    need(repo.is_dir(), "source_checkout_required")
    top = cmd.run(["git", "-C", repo, "rev-parse", "--show-toplevel"]).decode().strip()
    need(Path(top).resolve() == repo, "source_is_not_git_root")
    raw = cmd.run(["git", "-C", repo, "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    tracked = set(x.decode() for x in cmd.run(["git", "-C", repo, "ls-files", "--cached", "-z"]).split(b"\0") if x)
    index = cmd.run(["git", "-C", repo, "ls-files", "--stage", "-z"])
    gitlinks = {row.split(b"\t", 1)[1].decode() for row in index.split(b"\0") if row.startswith(b"160000 ")}
    paths, total = SourceFiles(), 0
    paths.gitlinks = sorted(gitlinks)
    for name in sorted(set(x.decode() for x in raw.split(b"\0") if x)):
        parts = PurePosixPath(name).parts
        need(not name.startswith("/") and ".." not in parts, "unsafe_source_path")
        if set(parts) & IGNORE:
            continue
        if name in gitlinks:
            continue  # No recursive submodule checkout or dependency adoption.
        p = repo / name
        need(not p.is_symlink(), "source_symlink_refused")
        if not p.exists():  # A legitimate working-tree deletion.
            continue
        need(p.is_file(), "source_nonregular")
        data = p.read_bytes()
        sensitive_name = any(part == ".env" or part.startswith(".env.") or part.endswith((".key", ".p12", ".pfx")) for part in parts)
        standalone_key = bool(re.match(rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----", data.lstrip()[:128]))
        if sensitive_name or standalone_key:
            template = name.endswith((".example", ".sample", ".template"))
            fixture = bool(set(parts) & {"test", "tests", "testdata", "fixtures", "__tests__", "__fixtures__"})
            known_public = False
            if name in tracked and (fixture or template):
                try: known_public = cmd.run(["git", "-C", repo, "show", "HEAD:" + name]) == data
                except Refused: pass
            need(known_public, "credential_file_in_context" if sensitive_name else "private_key_in_context")
        total += len(data)
        need(len(paths) < 50000 and total <= MAX_BYTES, "source_context_bound")
        paths[name] = data
    return paths


def validate_dockerfile(files, dockerfile):
    need(dockerfile in files, "dockerfile_missing")
    lines = files[dockerfile].decode("utf8").replace("\\\n", " ").splitlines()
    for line in lines:
        if not re.match(r"\s*(?:COPY|ADD)\s", line, re.I): continue
        tokens = re.findall(r"[A-Za-z0-9_./-]+", line)
        for link in getattr(files, "gitlinks", []):
            need(not any(token.rstrip("/") == link or link.startswith(token.rstrip("/") + "/")
                         for token in tokens if token not in (".", "..", "/")), "dockerfile_submodule_context_unsupported")


def protected_source(files):
    # Edits to schemas/roles, lockfiles, scrubber authority or entrypoints require
    # a new reviewed dev plan, never an automatic migration/dependency upgrade.
    return {p: hashlib.sha256(v).hexdigest() for p, v in files.items()
            if p.endswith((".sql", "lock.json", "bun.lock", "Cargo.lock", "Cargo.toml", "go.sum", "go.mod")) or
            "scrub" in p.lower() or p.endswith("entrypoint.sh") or p == "docker/40-runtime-config.sh" or p.startswith("vite.config.") or p == "versions.lock.json" or
            p == "package.json" or p.endswith("/package.json") or "Dockerfile" in p}


def context_archive(files, frontend=False, repo=None):
    files = dict(files)
    if frontend:
        for name in ("frontend.Dockerfile", "frontend.mjs", "sync.mjs"):
            files["__kind_dev/" + name] = (HERE / name).read_bytes()
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w") as tar:
        for name, data in sorted(files.items()):
            item = tarfile.TarInfo(name); item.size = len(data)
            item.mode = 0o755 if repo and name in files and (repo / name).exists() and (repo / name).stat().st_mode & 0o111 else 0o644
            tar.addfile(item, io.BytesIO(data))
    return out.getvalue()


def sync_batches(wanted, removed):
    import base64
    files, size = {}, 0
    for path, data in wanted.items():
        # Keep canonical base64 plus JSON overhead inside the 32MiB stdin cap.
        need(len(data) <= 24 * 1024 * 1024 - 65536, "frontend_single_file_sync_bound")
        if files and (len(files) >= 4000 or size + len(data) > 8 * 1024 * 1024):
            yield json.dumps({"files": files, "removed": []}).encode()
            files, size = {}, 0
        files[path] = base64.b64encode(data).decode(); size += len(data)
    if files: yield json.dumps({"files": files, "removed": []}).encode()
    for start in range(0, len(removed), 4000):
        yield json.dumps({"files": {}, "removed": removed[start:start + 4000]}).encode()


def identity(doc):
    return {"uid": doc["metadata"]["uid"], "specSha256": digest(doc["spec"])}


class Cluster:
    def __init__(self, config, cmd):
        self.c, self.cmd = config, cmd

    def k(self, *args, data=None, timeout=120):
        c = self.c
        return self.cmd.run([c["kubectl"], "--kubeconfig", c["kubeconfig"], "--context", c["context"],
                             "-n", c["namespace"], *args], data, timeout)

    def get(self, kind, name=None):
        return json.loads(self.k("get", kind, *([name] if name else []), "-o", "json"))

    def target(self):
        need(self.get("namespace", "kube-system")["metadata"]["uid"] == self.c["clusterUid"], "cluster_uid_changed")
        need(self.get("namespace", self.c["namespace"])["metadata"]["uid"] == self.c["namespaceUid"], "namespace_uid_changed")

    def inventory(self):
        self.target()
        return {x["metadata"]["name"]: x for x in self.get("deployments")["items"]}

    def patch(self, doc, spec):
        patch = [{"op": "test", "path": "/metadata/uid", "value": doc["metadata"]["uid"]},
                 {"op": "test", "path": "/metadata/resourceVersion", "value": doc["metadata"]["resourceVersion"]},
                 {"op": "test", "path": "/spec", "value": doc["spec"]},
                 {"op": "replace", "path": "/spec", "value": spec}]
        self.k("patch", "deployment", doc["metadata"]["name"], "--type=json", "--patch-file=/dev/stdin",
               data=json.dumps(patch).encode())

    def ready(self, name):
        self.k("rollout", "status", "deployment/" + name, "--timeout=180s", timeout=200)


def prepare(config, cmd):
    for group in config["groups"]:
        need(not group.get("sourceUnavailable"), "source_checkout_required_" + group["name"])
    k = Cluster(config, cmd); docs = k.inventory()
    images, source_heads = {}, {}
    for g in config["groups"]:
        files = source_files(Path(g["repo"]).resolve(), cmd)
        rev = cmd.run(["git", "-C", g["repo"], "rev-parse", "HEAD"]).decode().strip()
        need(HEX.fullmatch(rev), "source_head_invalid")
        need(g.get("protectedSourceSha256") == digest(protected_source(files)), "source_admission_required")
        source_heads[g["name"]] = rev
        for t in g["targets"]:
            d = docs[t["deployment"]]
            need(d["metadata"]["uid"] == t["uid"], "deployment_uid_changed")
            need(d["spec"].get("replicas", 1) == 1, "single_replica_runtime_required")
            need(d["status"].get("availableReplicas", 0) == 1, "baseline_not_ready")
            pod = d["spec"]["template"]["spec"]
            container = next(x for x in pod["containers"] if x["name"] == t["container"])
            need(container["image"] == t["image"], "baseline_image_changed")
            need(digest(pod.get("initContainers", [])) == t.get("reviewedInitSha256"), "init_command_review_required")
            if g["mode"] == "frontend-hmr":
                need(any(x.get("mountPath") == "/usr/share/nginx/html" for x in container.get("volumeMounts", [])),
                     "runtime_config_volume_required")
                public = next((e.get("value") for e in container.get("env", []) if e["name"] == "DASHBOARD_PUBLIC_URL"), None)
                need(public and public.rstrip("/") == config["publicOrigin"].rstrip("/"), "public_origin_binding")
                need(not any(e["name"] == "DASHBOARD_API_ORIGIN" for e in container.get("env", [])), "frontend_proxy_override_refused")
                need(pod.get("securityContext", {}).get("fsGroup") == 101 and
                     container.get("securityContext", {}).get("runAsUser", pod.get("securityContext", {}).get("runAsUser")) == 101,
                     "frontend_uid_and_fsgroup_required")
                need(any(v["name"] == "tmp" and "emptyDir" in v for v in pod.get("volumes", [])), "frontend_tmp_volume_required")
            images[t["deployment"]] = identity(d)
    protected = {n: identity(docs[n]) for n in config["protectedDeployments"]}
    engine = cmd.json([config["docker"], "info", "--format", "{{json .}}"])
    need(engine["OSType"] == "linux" and engine["Architecture"] in
         ({"arm64", "aarch64"} if config["architecture"] == "arm64" else {"amd64", "x86_64"}), "engine_platform")
    nodes = {}
    for node in k.get("nodes")["items"]:
        name = node["metadata"]["name"]
        observed = cmd.json([config["docker"], "inspect", name])[0]
        need(observed["Config"].get("Labels", {}).get("io.x-k8s.kind.cluster") == config["cluster"], "kind_node_engine_mismatch")
        need(observed["State"]["Running"] is True, "kind_node_stopped")
        nodes[name] = {"uid": node["metadata"]["uid"], "containerId": observed["Id"]}
    need(nodes, "kind_nodes_required")
    return {"version": 1, "preparedAt": int(time.time()), "configSha256": digest(config),
            "engineId": engine["ID"], "nodes": nodes, "targets": images, "protected": protected,
            "sourceHeads": source_heads,
            "sourceSha256": digest({p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                    for p in HERE.iterdir() if p.suffix in (".py", ".mjs", ".Dockerfile")})}


def frontend_spec(spec, target, image):
    pod = spec["template"]["spec"]
    need(not any(v["name"] == "kind-dev-source" for v in pod.get("volumes", [])), "dev_volume_already_present")
    pod.setdefault("volumes", []).append({"name": "kind-dev-source", "emptyDir": {"sizeLimit": "256Mi"}})
    c = next(x for x in pod["containers"] if x["name"] == target["container"])
    c["image"] = image
    c["command"] = ["node", "/seed/__kind_dev/frontend.mjs"]
    c.pop("args", None)  # Kubernetes omits an empty args slice on serialization.
    resources = c.setdefault("resources", {})
    resources.setdefault("requests", {})["memory"] = "256Mi"
    resources.setdefault("limits", {})["memory"] = "1Gi"
    c.setdefault("volumeMounts", []).append({"name": "kind-dev-source", "mountPath": "/devsrc"})
    c["imagePullPolicy"] = "Never"
    return spec


class Session:
    def __init__(self, config, plan, cmd, journal):
        self.c, self.plan, self.cmd, self.journal = config, plan, cmd, Path(journal)
        self.k = Cluster(config, cmd)
        self.expected = {**plan["targets"], **plan["protected"]}
        self.original, self.applied, self.seen = {}, {}, {}
        self.pending = {}
        self.frontend_seeds, self.frontend_instances = {}, {}
        self.stopping = False
        self.nonce = uuid.uuid4().hex[:10]

    def guard(self):
        engine = self.cmd.json([self.c["docker"], "info", "--format", "{{json .}}"])
        need(engine["ID"] == self.plan["engineId"], "engine_changed")
        for name, expected in self.plan.get("nodes", {}).items():
            node = self.k.get("node", name)
            actual = self.cmd.json([self.c["docker"], "inspect", name])[0]
            need(node["metadata"]["uid"] == expected["uid"] and actual["Id"] == expected["containerId"] and
                 actual["State"]["Running"] is True and
                 actual["Config"].get("Labels", {}).get("io.x-k8s.kind.cluster") == self.c["cluster"], "kind_node_changed")
        docs = self.k.inventory()
        for n, expected in self.expected.items():
            need(identity(docs[n]) == expected, "workload_drift_" + n)
        return docs

    def build(self, group, files):
        need(digest(protected_source(files)) == group["protectedSourceSha256"], "protected_source_changed")
        sha = digest({p: hashlib.sha256(v).hexdigest() for p, v in files.items()})
        tag = "agent-relay-dev/" + group["name"] + ":" + self.nonce + "-" + sha[:12]
        frontend = group["mode"] == "frontend-hmr"
        dockerfile = "__kind_dev/frontend.Dockerfile" if frontend else group["dockerfile"]
        validate_dockerfile(files, group["dockerfile"])
        emit("build", group=group["name"], sourceSha256=sha)
        try:
            self.cmd.run([self.c["docker"], "buildx", "build", "--load", "--platform=linux/" + self.c["architecture"],
                          "--label", "dev.agentrelay.session=" + self.nonce, "--tag", tag, "-f", dockerfile, "-"],
                         context_archive(files, frontend, Path(group["repo"])), timeout=900)
        except Refused as error:
            if str(error).startswith("command_failed_"):
                raise BuildFailed("build_failed_last_good_retained", error.diagnostics) from None
            raise
        image = self.cmd.json([self.c["docker"], "image", "inspect", tag])[0]
        need(image["Os"] == "linux" and image["Architecture"] == self.c["architecture"], "built_platform")
        self.guard()
        if self.stopping:
            return None
        self.cmd.run([self.c["kind"], "load", "docker-image", "--name", self.c["cluster"], tag], timeout=300)
        return tag

    def apply(self, group, image):
        for target in group["targets"]:
            if self.stopping:
                return
            name = target["deployment"]
            doc = self.guard()[name]
            before = copy.deepcopy(doc["spec"])
            after = copy.deepcopy(before)
            if group["mode"] == "frontend-hmr":
                after = frontend_spec(after, target, image)
            else:
                container = next(x for x in after["template"]["spec"]["containers"] if x["name"] == target["container"])
                container["image"] = image; container["imagePullPolicy"] = "Never"
            # Keep the original only in RAM: no env values, Secret data or argv on disk.
            self.original.setdefault(name, before)
            # Journal contains hashes only. A crash requires explicit operator recovery.
            save(self.journal / (str(time.time_ns()) + ".json"),
                 {"deployment": name, "uid": doc["metadata"]["uid"], "beforeSha256": digest(before),
                  "intendedSha256": digest(after), "devImage": image, "planned": True})
            if self.stopping:
                return
            # Keep the last confirmed spec. An in-flight CAS may have reached
            # the API even when its transport returns an error.
            self.pending[name] = after
            self.k.patch(doc, after)
            # Kubernetes defaults may canonicalize only our new emptyDir/volumeMount.
            actual = self.k.get("deployment", name)
            need(actual["metadata"]["uid"] == doc["metadata"]["uid"] and actual["spec"] == after,
                 "unexpected_apiserver_spec_change")
            self.applied[name] = after
            self.expected[name] = {"uid": doc["metadata"]["uid"], "specSha256": digest(after)}
            self.pending.pop(name, None)
            if self.stopping:
                return
            self.k.ready(name)
            emit("ready", role=target["role"], deployment=name)

    def frontend_pod(self, group):
        target = group["targets"][0]
        deadline = time.monotonic() + 180
        while not self.stopping:
            doc = self.k.get("deployment", target["deployment"])
            pods = self.k.get("pods")["items"]
            rs = {x["metadata"]["uid"] for x in self.k.get("replicasets")["items"]
                  if any(o["uid"] == doc["metadata"]["uid"] for o in x["metadata"].get("ownerReferences", []))}
            desired = next(c["image"] for c in doc["spec"]["template"]["spec"]["containers"] if c["name"] == target["container"])
            matches = [p for p in pods if not p["metadata"].get("deletionTimestamp") and
                       any(o["uid"] in rs for o in p["metadata"].get("ownerReferences", [])) and
                       any(c["name"] == target["container"] and c["image"] == desired for c in p.get("spec", {}).get("containers", [])) and
                       any(x.get("name") == target["container"] and x.get("ready") is True for x in p.get("status", {}).get("containerStatuses", []))]
            if len(matches) == 1:
                pod = matches[0]
                status = next(x for x in pod["status"]["containerStatuses"] if x["name"] == target["container"])
                need(isinstance(status.get("containerID"), str) and status["containerID"] and
                     type(status.get("restartCount")) is int, "frontend_running_identity_required")
                return pod["metadata"]["name"], {"podUid": pod["metadata"]["uid"],
                                                  "containerId": status["containerID"], "restartCount": status["restartCount"]}
            need(time.monotonic() < deadline, "frontend_owned_pod_required")
            time.sleep(1)  # Bounded read-only wait for container/pod recovery.
        return None

    def sync(self, group, old, files, replay=False, running=None):
        basis = self.frontend_seeds.get(group["name"], {}) if replay else old
        wanted = {p: b for p, b in files.items() if frontend_path(p) and basis.get(p) != b}
        removed = [p for p in old if frontend_path(p) and p not in files]
        if not wanted and not removed: return
        self.guard()
        if self.stopping: return
        running = running or self.frontend_pod(group)
        if running is None or self.stopping: return
        self.guard()  # A readiness wait may span an unrelated operator change.
        if self.stopping: return
        target = group["targets"][0]
        batches = 0
        for payload in sync_batches(wanted, removed):
            need(len(payload) <= 32 * 1024 * 1024, "frontend_sync_bound")
            self.guard()
            if self.stopping: return
            self.k.k("exec", "-i", running[0], "-c", target["container"], "--",
                     "node", "/seed/__kind_dev/sync.mjs", data=payload)
            batches += 1
        self.frontend_instances[group["name"]] = running[1]
        emit("hmr_replay" if replay else "hmr_sync", files=len(wanted), removed=len(removed), batches=batches)

    def frontend_replay(self, group, previous, files):
        running = self.frontend_pod(group)
        if running is None or self.stopping: return False
        if self.frontend_instances.get(group["name"]) == running[1]: return False
        # Startup recopies the seed image. Restore current host contents and
        # remove both seeded and previously synced files deleted on the host.
        old = {**self.frontend_seeds.get(group["name"], {}), **previous}
        self.sync(group, old, files, replay=True, running=running)
        self.frontend_instances[group["name"]] = running[1]
        return True

    def restore(self):
        errors = []
        # Always attempt every independently owned target, even if another drifts.
        for name, original in reversed(list(self.original.items())):
            try:
                self.k.target()
                doc = self.k.get("deployment", name)
                need(doc["metadata"]["uid"] == self.expected[name]["uid"], "restore_uid_changed")
                if doc["spec"] == original:
                    continue
                need(doc["spec"] in [self.applied.get(name), self.pending.get(name)], "restore_spec_drift")
                self.k.patch(doc, original)
                self.k.ready(name)
            except (Refused, KeyError) as e:
                errors.append({"deployment": name, "code": str(e) if isinstance(e, Refused) else "restore_missing_resource"})
        emit("restore_complete" if not errors else "restore_incomplete", failures=errors)
        return not errors

    def run(self):
        need(time.time() - self.plan["preparedAt"] < 1800, "plan_expired")
        fresh = prepare(self.c, self.cmd)
        need({k: v for k, v in fresh.items() if k != "preparedAt"} ==
             {k: v for k, v in self.plan.items() if k != "preparedAt"}, "plan_changed")
        admission(self.c, self.plan)
        def stop(*_): self.stopping = True
        for sig in (signal.SIGINT, signal.SIGTERM): signal.signal(sig, stop)
        failure = None
        try:
            for group in self.c["groups"]:
                if self.stopping: break
                files = source_files(Path(group["repo"]).resolve(), self.cmd)
                self.apply(group, self.build(group, files))
                if group["mode"] == "frontend-hmr" and not self.stopping:
                    self.frontend_seeds[group["name"]] = files
                    running = self.frontend_pod(group)
                    if running: self.frontend_instances[group["name"]] = running[1]
                self.seen[group["name"]] = files
            emit("watching", intervalSeconds=1, developmentOnly=True)
            while not self.stopping:
                time.sleep(1)
                self.guard()
                for group in self.c["groups"]:
                    files = source_files(Path(group["repo"]).resolve(), self.cmd)
                    need(digest(protected_source(files)) == group["protectedSourceSha256"], "protected_source_changed")
                    previous = self.seen.get(group["name"], {})
                    if group["mode"] == "frontend-hmr" and self.frontend_replay(group, previous, files):
                        self.seen[group["name"]] = files
                        continue
                    if files == previous: continue
                    time.sleep(0.4)  # Coalesce a save before one serial build/sync.
                    try:
                        if group["mode"] == "frontend-hmr": self.sync(group, previous, files)
                        else: self.apply(group, self.build(group, files))
                    except BuildFailed as error:
                        emit("build_failed_last_good_retained", group=group["name"], diagnostics=error.diagnostics)
                    self.seen[group["name"]] = files
        except Exception as e:
            failure = e
        finally:
            restored = self.restore()
        if failure: raise failure
        need(restored, "writer_restore_incomplete")


def frontend_path(p):
    if not isinstance(p, str) or p.startswith("/"): return False
    blocked = {".", "..", ".git", ".kind", ".local", ".aws", ".ssh", ".config", ".npmrc", ".netrc", "node_modules"}
    if any(not x or x in blocked or x == ".env" or x.startswith(".env.") or
           x.endswith((".key", ".p12", ".pfx")) for x in p.split("/")): return False
    return p.startswith(("src/", "public/")) or p in {"index.html", "vite.config.ts", "vite.config.js"} or bool(re.fullmatch(r"tsconfig[^/]*\.json", p))


def admission(config, plan):
    """A coordinator records existing target/source/containment clearance, not a release attestation."""
    if not config.get("admissionFile"):
        return
    p = Path(config["admissionFile"])
    need(p.is_file() and not p.is_symlink(), "external_dev_admission_required")
    a = json.loads(p.read_text())
    need(a.get("result") == "APPROVED_LOCAL_KIND_DEV_SESSION" and a.get("containmentCleared") is True,
         "containment_not_cleared")
    need(a.get("configSha256") == digest(config) and a.get("planSha256") == digest(plan), "admission_binding_changed")
    need(type(a.get("approvedAt")) is int and 0 <= time.time() - a["approvedAt"] < 12 * 3600, "admission_expired")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["plan", "run", "source-digest"])
    parser.add_argument("--config", default=".kind/dev/config.json")
    parser.add_argument("--plan", help="Optional explicit expiring plan; run otherwise prepares a fresh plan")
    parser.add_argument("--state", default=".kind/dev/sessions")
    parser.add_argument("--repo")
    parser.add_argument("--components", default="all", help="Comma-separated groups/roles; default all")
    args = parser.parse_args()
    cmd = Commands()
    if args.action == "source-digest":
        need(args.repo, "repo_required")
        files = source_files(Path(args.repo).resolve(), cmd)
        emit("source_digest", protectedSourceSha256=digest(protected_source(files)), skippedGitlinks=list(files.gitlinks))
        return
    config = select_components(load_config(args.config), args.components)
    cmd.docker_context = config["dockerContext"]
    cmd.public_docker_config = config.get("publicDockerConfig")
    cmd.docker_host = config.get("dockerHost")
    if args.action == "plan":
        path = args.plan or ".kind/dev/plan.json"
        plan = prepare(config, cmd); save(path, plan)
        emit("prepared_no_effects", plan=path, planSha256=digest(plan), targets=len(plan["targets"]))
    else:
        plan = json.loads(Path(args.plan).read_text()) if args.plan else prepare(config, cmd)
        need(plan["configSha256"] == digest(config), "config_changed")
        state = Path(args.state) / uuid.uuid4().hex
        save(state / "plan.json", plan)
        emit("session_plan", path=str(state / "plan.json"), planSha256=digest(plan), targets=len(plan["targets"]))
        Session(config, plan, cmd, state).run()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        emit("refused", code=str(error) if isinstance(error, Refused) else type(error).__name__)
        sys.exit(1)
