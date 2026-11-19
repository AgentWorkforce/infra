#!/usr/bin/env python3
"""Local developer process supervisor. No cloud CLI, production app or global trust edits."""
from __future__ import annotations

import argparse
from contextlib import suppress
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
STATE = ROOT / ".kind/dev"
DEV_ID = "com.agentrelay.desktop.dev"
REQUIRED = {
    "relay-desktop": ["scripts/build-app.sh", "scripts/build-probe.sh", "scripts/dev-reload.sh", "desktop-core/Cargo.toml", "macos/Package.swift"],
    "agentrelay.com": ["package.json", "package-lock.json", "web/next.config.mjs"],
    "relay-webapp": ["package.json", "package-lock.json", "vite.config.ts"],
    "relay-control": ["Dockerfile", "package.json"],
    "relayhistory-pipeline": ["docker/services.Dockerfile", "package.json"],
    "relaycast": ["Dockerfile", "package.json", "packages/engine/package.json"],
}
CLUSTER = "agent-relay-local"
NODE = CLUSTER + "-control-plane"  # kind names the single node after the owned cluster.
# Written by local_stack.py when it creates the cluster; names the Docker endpoint it used.
RECEIPT = ROOT / ".kind/local/cluster.json"
# Written by this launcher after the stack proved ownership; binds pause/resume to one container.
NODE_RECORD = STATE / "node.json"
# A backend watcher still restoring deployments after this launcher exited.
RESTORING = STATE / "restoring.json"
# local_tools.py --prepare installs these under .kind/tools; preflight must not require them first.
BOOTSTRAPPED = ("kind", "helm")
PORTS = dict(port=3100, nextPort=3102, dashboardPort=3103, controlPort=33100)


class DevError(Exception):
    pass


def say(message):
    print(f"[dev] {message}", flush=True)


def missing_repos(parent):
    errors = []
    for repo, files in REQUIRED.items():
        if not (parent / repo).is_dir():
            errors.append(f"Missing sibling repository: {parent / repo} (AgentWorkforce/{repo})")
        else:
            for file in files:
                if not (parent / repo / file).is_file():
                    errors.append(f"Incomplete sibling checkout: {parent / repo / file}")
    return errors


def read_config(path, auth):
    if not path.is_file():
        raise DevError(f"Missing local config: {path}\n  mkdir -p '{path.parent}'\n"
                       f"  cp '{ROOT / 'scripts/dev/config.example.json'}' '{path}'\n"
                       f"  chmod 600 '{path}'\nFill adminEmail and the Google OAuth client locally; never commit the secret.")
    if path.stat().st_mode & 0o077:
        raise DevError(f"Config contains credentials; run chmod 600 '{path}'.")
    try:
        raw = json.loads(path.read_text())
    except (ValueError, UnicodeError):
        raise DevError("Local config is not valid JSON (contents withheld).") from None
    if not isinstance(raw, dict):
        raise DevError("Local config must be a JSON object.")
    unknown = set(raw) - set(PORTS) - {"adminEmail", "googleClientId", "googleClientSecret", "googleEnvFile", "autoJoinDomains"}
    if unknown:
        raise DevError("Unknown config keys: " + ", ".join(sorted(unknown)))
    config = {**PORTS, **raw}
    if raw.get("googleEnvFile"):
        if not isinstance(raw["googleEnvFile"], str):
            raise DevError("googleEnvFile must be a local file path string.")
        source = Path(raw["googleEnvFile"]).expanduser()
        if not source.is_absolute():
            source = path.parent / source
        if not source.is_file():
            raise DevError(f"Google credential file does not exist: {source}")
        # Parse only two named values, never execute/source someone else's .env.
        names = {"GOOGLE_CLIENT_ID": "googleClientId", "GOOGLE_CLIENT_SECRET": "googleClientSecret"}
        for line in source.read_text().splitlines():
            key, separator, value = line.removeprefix("export ").partition("=")
            if separator and key.strip() in names:
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                config[names[key.strip()]] = value
    for key in PORTS:
        if type(config[key]) is not int or not 1024 <= config[key] <= 65535:
            raise DevError(f"{key} must be an integer from 1024 to 65535.")
    if len({config[k] for k in PORTS}) != len(PORTS):
        raise DevError("All four local ports must be distinct.")
    email = config.get("adminEmail", "")
    if not isinstance(email, str) or "@" not in email or email == "you@your-company.com" or any(c.isspace() for c in email):
        raise DevError("Set adminEmail to your Google account's email in the local config.")
    if auth == "google":
        for key in ("googleClientId", "googleClientSecret"):
            if not isinstance(config.get(key), str) or not config[key].strip():
                raise DevError(f"Missing {key} in {path}. Register http://localhost:{config['port']}/login/oidc/callback. "
                               "Use --auth operator only when deliberately testing without Google.")
    domains = config.get("autoJoinDomains", [])
    if not isinstance(domains, list) or any(not isinstance(d, str) or not d or any(c in d for c in ' ,/@\n') for d in domains):
        raise DevError("autoJoinDomains must be a list of email domains; empty means invited members only.")
    return config


def environment():
    env = dict(os.environ)
    env.setdefault("LOCAL_RELAYCAST_BACKEND", "sqlite")
    # Homebrew rustup installs proxies outside the default Homebrew PATH.
    env["PATH"] = os.pathsep.join([str(ROOT / ".kind/tools"), str(Path.home() / ".cargo/bin"), "/opt/homebrew/opt/rustup/bin", env.get("PATH", "")])
    if sys.platform == "darwin":
        developer = env.get("DEVELOPER_DIR") or subprocess.run(
            ["xcode-select", "-p"], capture_output=True, text=True).stdout.strip()
        sdk_dir = Path("/Library/Developer/CommandLineTools/SDKs")
        older = sdk_dir / "MacOSX26.5.sdk"
        sdk = env.get("SDKROOT", "").rstrip("/")
        # Some shells export the moving CLT alias. It currently resolves to
        # SDK 27, whose SwiftUI macros require plugins absent from CLT.
        automatic_sdk = sdk in ("", "macosx", str(sdk_dir / "MacOSX.sdk"))
        if developer == "/Library/Developer/CommandLineTools" and automatic_sdk and older.is_dir():
            env["SDKROOT"] = str(older)
            say(f"Using Desktop SDK {older}")
    return env


def check_prerequisites(parent, env, desktop=True, bootstrap=True):
    """Tools the launcher cannot prepare itself. With bootstrap, kind and Helm come from local_tools.py."""
    errors = missing_repos(parent)
    names = ["docker", "kubectl", "openssl", "git", "node", "npm"]
    if not bootstrap:
        names += list(BOOTSTRAPPED)
    if desktop:
        if sys.platform != "darwin":
            errors.append("Desktop hot reload currently requires macOS; use --no-desktop for web/container development.")
        names += ["cargo", "rustc", "swift", "codesign", "iconutil", "plutil", "ditto"]
    for name in names:
        if not shutil.which(name, path=env["PATH"]):
            errors.append(f"Missing executable: {name}")
    if shutil.which("node", path=env["PATH"]):
        version = subprocess.run(["node", "-p", "process.versions.node"], capture_output=True, text=True, env=env).stdout.strip()
        if tuple(int(v) for v in version.split(".")[:2]) < (22, 12):
            errors.append("Node >=22.12 is required by relay-webapp.")
    return errors


def missing_bootstrapped(env):
    return [f"Missing executable after tool preparation: {name}" for name in BOOTSTRAPPED
            if not shutil.which(name, path=env["PATH"])]


def docker_running(env):
    try:
        return subprocess.run(["docker", "info", "--format", "{{.ServerVersion}}"], capture_output=True, env=env, timeout=15).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def ensure_docker(env, timeout=180):
    """Start Docker Desktop when its daemon is down; never switch contexts or start another runtime."""
    if docker_running(env):
        return
    host = env.get("DOCKER_HOST") or subprocess.run(
        ["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], capture_output=True, text=True, env=env).stdout.strip()
    app = Path("/Applications/Docker.app")
    if sys.platform != "darwin" or not host.endswith("/.docker/run/docker.sock") or not app.is_dir():
        raise DevError(f"Docker daemon is not reachable at {host or 'the selected context'}. Start it and rerun dev.sh; "
                       "only Docker Desktop on its own context is started automatically.")
    say("Docker is not running; starting Docker Desktop.")
    if subprocess.run(["open", "-g", "-a", str(app)], env=env).returncode:
        raise DevError("Could not open Docker Desktop. Start it yourself and rerun dev.sh.")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        time.sleep(2)
        if docker_running(env):
            say("Docker is ready.")
            return
    raise DevError(f"Docker Desktop did not become ready within {timeout}s. Check its window, then rerun dev.sh.")


def docker_endpoint(env):
    if env.get("DOCKER_HOST"):
        return env["DOCKER_HOST"]
    with suppress(OSError, subprocess.TimeoutExpired):
        return subprocess.run(["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
                              capture_output=True, text=True, env=env, timeout=15).stdout.strip()
    return ""


def inspect_node(env):
    """(container id, status) of the kind node named for this stack; None when absent or another cluster's."""
    try:
        result = subprocess.run(["docker", "inspect", "--format", '{{.Id}} {{.State.Status}} {{index .Config.Labels "io.x-k8s.kind.cluster"}}', NODE],
                                capture_output=True, text=True, env=env, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        raise DevError(f"Could not inspect {NODE}: Docker did not answer.") from None
    if result.returncode:
        if "no such object" in (result.stderr or "").lower():
            return None
        raise DevError(f"Could not inspect {NODE}: {(result.stderr or '').strip() or 'docker inspect failed'}")
    parts = result.stdout.split()
    if len(parts) != 3 or parts[2] != CLUSTER:
        return None
    return parts[0], parts[1]


def record_node(env):
    """Bind later pause/resume to the container this checkout's stack just proved it owns."""
    found = inspect_node(env)
    if found:
        NODE_RECORD.write_text(json.dumps({"id": found[0], "dockerHost": docker_endpoint(env)}))
        NODE_RECORD.chmod(0o600)


def node_state(env):
    """running/exited/... for this checkout's kind node; None when absent or not provably this checkout's.

    The name and kind label are shared by every checkout on a Docker daemon, so
    ownership also needs the stack's receipt for this Docker endpoint and the
    container identity this launcher recorded after the stack verified it.
    """
    found = inspect_node(env)
    if found is None:
        return None
    try:
        receipt = json.loads(RECEIPT.read_text())
        record = json.loads(NODE_RECORD.read_text())
    except (OSError, ValueError):
        return None
    host = docker_endpoint(env)
    if (receipt.get("name") != CLUSTER or receipt.get("dockerHost") != host or
            record.get("id") != found[0] or record.get("dockerHost") != host):
        return None
    return found[1]


def pause_cluster(env):
    """Stop the kind node so an idle cluster costs nothing; its data and images stay in the container.

    kind's restart policy would bring the node back whenever Docker starts, so
    it is cleared; resume_cluster starts the node explicitly instead. Returns
    False when there is nothing of this checkout's to pause; raises when a
    pause was needed and failed.
    """
    state = node_state(env)
    if state is None:
        return False
    subprocess.run(["docker", "update", "--restart", "no", NODE], capture_output=True, env=env)
    if state != "running":
        return False
    say("Pausing the local cluster (data retained).")
    result = subprocess.run(["docker", "stop", "--time", "60", NODE], capture_output=True, text=True, env=env)
    if result.returncode:
        raise DevError(f"Could not pause the cluster; stop it yourself with: docker stop {NODE}")
    return True


def resume_cluster(env, timeout=240):
    """Start a paused kind node and wait for its API server before the stack is verified or reapplied.

    Docker may also restart the node itself when its daemon starts, so a
    running node is not assumed ready either.
    """
    state = node_state(env)
    if state is None:
        found = inspect_node(env)
        if found and found[1] != "running":
            # Not provably this checkout's (for example another checkout's, or
            # paused before this launcher recorded node identities).
            raise DevError(f"A stopped {NODE} exists that this launcher did not record. If it belongs to this checkout, "
                           f"start it yourself with: docker start {NODE}; otherwise leave it and use another Docker endpoint.")
        return False
    ready = ["docker", "exec", NODE, "kubectl", "--kubeconfig", "/etc/kubernetes/admin.conf", "get", "--raw", "/readyz"]
    def api_ready():
        with suppress(OSError, subprocess.TimeoutExpired):
            return subprocess.run(ready, capture_output=True, env=env, timeout=15).returncode == 0
        return False
    if state == "running":
        if api_ready():
            return False
        say("Waiting for the local cluster's API server.")
    else:
        say("Resuming the paused local cluster.")
        if subprocess.run(["docker", "start", NODE], capture_output=True, env=env).returncode:
            raise DevError(f"Could not start the paused cluster node {NODE}. Inspect it with: docker logs {NODE}")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        time.sleep(2)
        if api_ready():
            return True
    raise DevError(f"The local cluster's API server was not ready within {timeout}s. Inspect it with: docker logs {NODE}")


def available_ports(config):
    errors = []
    for key in PORTS:
        with socket.socket() as sock:
            try:
                # Match the servers' restart behavior: closed connections in
                # TIME_WAIT do not mean another server owns this port.
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.bind(("127.0.0.1", config[key]))
                sock.listen(1)
            except OSError:
                errors.append(f"{key} {config[key]} is occupied. Inspect with: lsof -nP -iTCP:{config[key]} -sTCP:LISTEN. "
                              "Stop that server yourself or select another port; dev.sh never kills an unknown process.")
    return errors


def verify_bundle(app, origin):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    job = plistlib.loads((app / f"Contents/Library/LaunchAgents/{DEV_ID}.core.plist").read_bytes())
    schemes = [s for item in info.get("CFBundleURLTypes", []) for s in item.get("CFBundleURLSchemes", [])]
    if info.get("CFBundleIdentifier") != DEV_ID or "agentrelay-dev" not in schemes or job.get("Label") != DEV_ID + ".core":
        raise DevError("Refusing to launch: the bundle is not the isolated Agent Relay Dev identity.")
    if "AgentRelayProduct" in info or "AgentRelayProduct" in job:
        raise DevError("Refusing to launch: AgentRelayProduct would enable takeover of production. Build with --dev-site-url.")
    if (app / "Contents/Resources/site-url.txt").read_text().strip() != origin:
        raise DevError("Refusing to launch a Desktop build for another origin.")


def source_snapshot(desktop):
    roots = [desktop / p for p in ("macos/Sources", "shared", "desktop-core/src", "scripts")]
    roots += [desktop / p for p in ("desktop-core/Cargo.toml", "desktop-core/build.rs", "desktop-core/Cargo.lock", "macos/Package.swift")]
    result = {}
    for root in roots:
        try:
            paths = [root] if root.is_file() else list(root.rglob("*"))
        except FileNotFoundError:
            continue  # A directory removed mid-walk.
        for path in paths:
            if path.is_file() and not any(p in {".build", "target", ".git", "node_modules", "__pycache__"} for p in path.parts):
                try:
                    stat = path.stat()
                except FileNotFoundError:
                    continue  # Deleted mid-scan: the next scan sees the deletion as a change.
                result[str(path)] = (stat.st_mtime_ns, stat.st_size)
    return result


class Supervisor:
    def __init__(self, env):
        self.env = env
        self.children = []
        self.logs = []
        self.backend_log_offset = None  # Where this invocation's backends.log events begin.
        self.desktop_process = None

    def log(self, name):
        path = STATE / f"{name}.log"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        os.chmod(path, 0o600)
        stream = os.fdopen(fd, "a")
        self.logs.append(stream)
        return stream

    def run(self, name, args, cwd=ROOT, env=None, data=None, timeout=1200):
        say(f"{name} (log: {STATE / (name + '.log')})")
        with subprocess.Popen([str(a) for a in args], cwd=cwd, env=env or self.env,
                              stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
                              stdout=self.log(name), stderr=subprocess.STDOUT, text=True, start_new_session=True) as process:
            try:
                process.communicate(data, timeout=timeout)
            except BaseException:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                raise
            if process.returncode:
                raise DevError(f"{name} failed ({process.returncode}); inspect {STATE / (name + '.log')}. Log may contain private data; do not paste it wholesale.")

    def start(self, name, args, cwd=ROOT, env=None):
        process = subprocess.Popen([str(a) for a in args], cwd=cwd, env=env or self.env,
                                   stdout=self.log(name), stderr=subprocess.STDOUT, start_new_session=True)
        self.children.append((name, process))
        return process

    def backends_restored(self, process):
        """The watcher's own restore result for this run, not its exit status.

        ci/agent-relay/dev/dev.py restores in a finally block and then re-raises
        whatever stopped it (for example protected_source_changed), so exit 1 can
        follow a complete restore. Its last restore event in this run decides.
        """
        result = None
        try:
            with (STATE / "backends.log").open() as stream:
                stream.seek(self.backend_log_offset or 0)
                for line in stream:
                    with suppress(ValueError, AttributeError):
                        stage = json.loads(line).get("stage")
                        if stage in {"restore_complete", "restore_incomplete"}:
                            result = stage
        except OSError:
            pass
        return result == "restore_complete"

    def check(self):
        for name, process in self.children:
            if process.poll() is not None:
                raise DevError(f"{name} exited ({process.returncode}); see {STATE / (name + '.log')}.")

    def close(self):
        """Stop this invocation's processes. Returns False while the backend watcher is still restoring."""
        restored = True
        if self.desktop_process and self.desktop_process.poll() is None:
            with suppress(ProcessLookupError):
                self.desktop_process.terminate()  # Exactly the UI process this invocation started.
            with suppress(subprocess.TimeoutExpired):
                self.desktop_process.wait(timeout=8)
        for name, process in reversed(self.children):
            if process.poll() is None:
                with suppress(ProcessLookupError):
                    if name == "backends":
                        process.terminate()  # The upstream loop finishes its build and restores deployments.
                    else:
                        os.killpg(process.pid, signal.SIGTERM)
        for name, process in self.children:
            try:
                if name == "backends" and process.poll() is None:
                    say("Waiting for the backend development loop to restore its deployments.")
                    # Recorded first, so a second interrupt during the wait still leaves the marker.
                    RESTORING.write_text(json.dumps({"pid": process.pid}))
                    RESTORING.chmod(0o600)
                process.wait(timeout=1800 if name == "backends" else 8)
                if name == "backends":
                    if self.backends_restored(process):
                        with suppress(FileNotFoundError):
                            RESTORING.unlink()
                    else:
                        # Kept until the developer recovers: a later run must not adopt
                        # leftover development images as its starting state.
                        RESTORING.write_text(json.dumps({"pid": process.pid, "failed": True}))
                        RESTORING.chmod(0o600)
                        say("Backend restoration did not complete; see backends.log and the source-loop recovery guide.")
                        restored = False
            except subprocess.TimeoutExpired:
                if name == "backends":
                    say("Backend restoration is still running; inspect backends.log before another startup.")
                    restored = False
                    continue
                with suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        for stream in self.logs:
            stream.close()
        say("Stopped this launcher's web servers, tunnels and UI. Cluster data and Desktop background core are retained.")
        return restored


def restore_block():
    """Why an earlier backend watcher's restoration blocks this run, or None.

    A watcher still running holds the deployments; one that exited without
    confirming restore_complete may have left development images behind.
    """
    try:
        record = json.loads(RESTORING.read_text())
        pid = record["pid"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    listing = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True)
    if listing.returncode == 0 and "ci/agent-relay/dev/dev.py" in listing.stdout:
        return f"An earlier backend watcher (pid {pid}) is still restoring deployments. Wait for it to exit; see .kind/dev/backends.log."
    if record.get("failed"):
        return ("The last backend restoration did not complete, so deployments may still run development images. "
                "Follow source-loop recovery in docs/kind-development.md, then delete .kind/dev/restoring.json.")
    with suppress(OSError):
        RESTORING.unlink()
    return None


def stop_desktop_ui(supervisor):
    """Stop the Dev UI before a rebuild; after a failed rebuild there is none, and the retry proceeds."""
    if supervisor.desktop_process is not None:
        supervisor.desktop_process.terminate()
        supervisor.desktop_process.wait(timeout=15)
        supervisor.desktop_process = None


def wait_http(url, supervisor, timeout=120):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        supervisor.check()
        try:
            with urllib.request.urlopen(url, timeout=3) as response:
                if response.status == 200:
                    return
        except (OSError, ValueError):
            pass
        time.sleep(.5)
    raise DevError(f"Readiness timed out: {url}")


def configure_control(stack, config, auth):
    """Dev-only patch after the normal chart install; next kind-up restores chart defaults."""
    stack.docker(require_space=False)
    stack.require_owned_cluster()
    origin = f"http://localhost:{config['port']}"
    env = {
        "SELFHOST_DASHBOARD_URL": origin + "/cloud/dashboard/",
        "SELFHOST_BOOTSTRAP_ADMIN_EMAIL": config["adminEmail"],
        "SELFHOST_BOOTSTRAP_ORG_NAME": "Local development",
        "SELFHOST_AUTO_JOIN_DOMAINS": ",".join(config.get("autoJoinDomains", [])),
    }
    if auth == "google":
        stack.apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "local-dev-google", "namespace": "agent-relay"},
                     "stringData": {"client-id": config["googleClientId"], "client-secret": config["googleClientSecret"]}})
        env.update(SELFHOST_OIDC_ISSUER="https://accounts.google.com", SELFHOST_OIDC_DISPLAY_NAME="Google",
                   SELFHOST_OIDC_REDIRECT_URL=origin + "/login/oidc/callback")
    changes = [{"name": k, "value": v} for k, v in env.items()]
    for name, key in [("SELFHOST_OIDC_CLIENT_ID", "client-id"), ("SELFHOST_OIDC_CLIENT_SECRET", "client-secret")]:
        # value: null clears a chart-rendered literal (native make local-google-oidc sets
        # the client id as value); Kubernetes rejects an entry with both value and valueFrom.
        changes.append({"name": name, "value": None, "valueFrom": {"secretKeyRef": {"name": "local-dev-google", "key": key}}}
                       if auth == "google" else {"name": name, "$patch": "delete"})
    if auth != "google":
        changes.extend({"name": name, "$patch": "delete"} for name in ["SELFHOST_OIDC_ISSUER", "SELFHOST_OIDC_DISPLAY_NAME", "SELFHOST_OIDC_REDIRECT_URL"])
    # The chart renders these when the native stack has its own Google client
    # (make local-google-oidc). This launcher's sign-in is configured only by its
    # own config: adminEmail plus autoJoinDomains, not the native allowed domains.
    for name in ("SELFHOST_OIDC_CLIENT_SECRET_FILE", "SELFHOST_OIDC_ALLOWED_DOMAINS", "SELFHOST_OIDC_SCOPES", "SELFHOST_OIDC_ALLOW_HTTP_ISSUER"):
        changes.append({"name": name, "$patch": "delete"})
    fingerprint = hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()
    patch = {"spec": {"template": {"metadata": {"annotations": {"dev.agentrelay.local/config": fingerprint}},
                                    "spec": {"containers": [{"name": "api", "env": changes}]}}}}
    stack.k("patch", "deployment", "relay-control", "--type=strategic", "--patch-file=/dev/stdin", data=json.dumps(patch), sensitive=True)
    if auth == "google":
        # OIDC discovery, token exchange and JWKS require Google HTTPS. Only Control
        # gets this dev exception; workers and every other pod retain their policy.
        stack.apply({"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
            "metadata": {"name": "local-dev-control-oidc", "namespace": "agent-relay"}, "spec": {
                "podSelector": {"matchLabels": {"app.kubernetes.io/name": "relay-control"}},
                "policyTypes": ["Egress"], "egress": [{"to": [{"ipBlock": {"cidr": "0.0.0.0/0", "except": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "127.0.0.0/8"]}}],
                    "ports": [{"protocol": "TCP", "port": 443}]}]}})
    else:
        stack.k("delete", "networkpolicy", "local-dev-control-oidc", "--ignore-not-found=true")
    stack.k("rollout", "status", "deployment/relay-control", "--timeout=180s", timeout=210)


def install_node(repo, supervisor):
    digest = hashlib.sha256((repo / "package-lock.json").read_bytes()).hexdigest()
    marker = STATE / f"{repo.name}-npm.sha256"
    if not (repo / "node_modules").is_dir() or not marker.exists() or marker.read_text() != digest:
        supervisor.run(f"install-{repo.name}", ["npm", "ci", "--no-audit", "--no-fund"], cwd=repo)
        marker.write_text(digest)


def build_desktop(repo, origin, supervisor):
    arch = "arm64" if platform.machine() == "arm64" else "x64"
    target = "aarch64-apple-darwin" if arch == "arm64" else "x86_64-apple-darwin"
    app = repo / "out/dev/Agent Relay Dev.app"
    supervisor.run("desktop-helper", ["bash", "scripts/build-probe.sh", "--target", target, "--version", "0.0.0", "--out", "out/dev-probe", "--site-url", origin, "--url-scheme", "agentrelay-dev"], cwd=repo)
    supervisor.run("desktop-build", ["bash", "scripts/build-app.sh", "--debug", "--arch", arch, "--version", "0.0.0", "--probe", "out/dev-probe", "--out", "out/dev", "--dev-site-url", origin], cwd=repo)
    verify_bundle(app, origin)
    return app, arch


def launch_desktop(app, origin, supervisor, restart=False):
    verify_bundle(app, origin)
    if restart:
        # Never discover/kill a core by process name. Restart only the known Dev
        # service, and only if launchd's recorded program belongs to this bundle.
        for suffix in ("core", "core.local", "core.session"):
            label = f"gui/{os.getuid()}/{DEV_ID}.{suffix}"
            job = subprocess.run(["launchctl", "print", label], capture_output=True, text=True)
            if job.returncode == 0:
                if str(app) not in job.stdout:
                    raise DevError("Another Dev bundle owns the background service. Close it before using this launcher.")
                supervisor.run("desktop-core-restart", ["launchctl", "kickstart", "-k", label])
    supervisor.desktop_process = subprocess.Popen([str(app / "Contents/MacOS/RelayDesktop")], env=supervisor.env,
                                                  stdout=supervisor.log("desktop-ui"), stderr=subprocess.STDOUT)


def start_backends(parent, python, supervisor):
    sources = {"control": str(parent / "relay-control"), "webapp": str(parent / "relay-webapp"),
               "pipeline": str(parent / "relayhistory-pipeline"), "cast": str(parent / "relaycast")}
    source_file = STATE / "backend-sources.json"
    source_file.touch(mode=0o600, exist_ok=True)
    source_file.chmod(0o600)
    source_file.write_text(json.dumps(sources))
    backend_config = STATE / f"backend-config-{time.time_ns()}.json"
    docker_context = subprocess.check_output(["docker", "context", "show"], env=supervisor.env, text=True).strip()
    supervisor.run("configure-backends", [python, ROOT / "ci/agent-relay/dev/configure.py",
        "--kubeconfig", ROOT / ".kind/local/kubeconfig", "--context", "kind-agent-relay-local",
        "--namespace", "agent-relay", "--docker-context", docker_context, "--workspace", parent,
        "--sources", source_file, "--output", backend_config,
        "--kind", shutil.which("kind", path=supervisor.env["PATH"]),
        "--kubectl", shutil.which("kubectl", path=supervisor.env["PATH"])])
    log = STATE / "backends.log"
    offset = log.stat().st_size if log.exists() else 0
    supervisor.backend_log_offset = offset
    supervisor.start("backends", [python, ROOT / "ci/agent-relay/dev/dev.py", "run",
        "--config", backend_config, "--components", "control,pipeline,cast"])
    say("Building backend services from sibling sources; cold container builds can take several minutes.")
    deadline = time.monotonic() + 3600
    with log.open() as stream:
        stream.seek(offset)
        while time.monotonic() < deadline:
            supervisor.check()
            for line in stream:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if event.get("stage") == "watching":
                    say("Backend source watch active: Control, collector, pipeline and Relaycast rebuild and roll out on edits.")
                    return
                if event.get("stage") in {"build", "ready"}:
                    say("Backend " + event["stage"] + ": " + str(event.get("group", event.get("role", "service"))))
            time.sleep(1)
    raise DevError("Backend initial builds exceeded one hour; inspect backends.log.")


def main():
    parser = argparse.ArgumentParser(description="Run the kind stack, Next front door, dashboard and isolated Desktop with reload.")
    parser.add_argument("--config", type=Path, default=STATE / "config.json")
    parser.add_argument("--check", action="store_true", help="Check sibling repos, tools, config and port availability; change nothing")
    parser.add_argument("--auth", choices=("google", "operator"), default="google")
    parser.add_argument("--no-desktop", action="store_true", help="Run web and containers only")
    parser.add_argument("--no-service-watch", action="store_true", help="Use the native stack's release images without backend source rebuilds")
    parser.add_argument("--reuse-containers", action="store_true", help="Verify and reuse the ready owned native local cluster")
    parser.add_argument("--keep-running", action="store_true", help="Leave the cluster running on exit instead of pausing it")
    parser.add_argument("--stop", action="store_true", help="Pause the local cluster left running by an earlier run, then exit")
    parser.add_argument("--proof", action="store_true", help="Show the native-stack acceptance command")
    args = parser.parse_args()
    if args.proof:
        raise DevError("Use make local-acceptance with the actor configuration in docs/local-acceptance.md. Its implemented API checks and remaining qualification gates are documented there.")
    args.config = args.config.expanduser().resolve()
    parent = ROOT.parent
    env = environment()
    if args.stop:
        STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (STATE / "launcher.lock").open("w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise DevError("A dev.sh is running in this checkout. Stop it with Ctrl-C; it pauses the cluster on exit.") from None
            blocked = restore_block()
            if blocked and "still restoring" in blocked:
                raise DevError(blocked + " Pause after it exits.")
            if not docker_running(env):
                say("Docker is not running, so the local cluster is not either; nothing to pause.")
                return 0
            if not pause_cluster(env):
                say("This checkout's local cluster is not running; nothing to pause.")
        return 0
    errors = check_prerequisites(parent, env, not args.no_desktop and not args.proof, bootstrap=not args.reuse_containers)
    if args.check and not args.reuse_containers:
        for name in BOOTSTRAPPED:
            if not shutil.which(name, path=env["PATH"]):
                say(f"{name} is not installed yet; dev.sh prepares the pinned version under .kind/tools before using it.")
    blocked = restore_block()
    if blocked:
        errors.append(blocked)
    if not args.no_desktop and not args.proof and sys.platform == "darwin":
        executable = str(parent / "relay-desktop/out/dev/Agent Relay Dev.app/Contents/MacOS/RelayDesktop")
        listing = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True)
        if listing.returncode:
            errors.append("Cannot inspect existing Dev processes. Run dev.sh from a normal local terminal.")
        elif any(line.strip().partition(" ")[2].lstrip() == executable for line in listing.stdout.splitlines()):
            errors.append("Agent Relay Dev is already open. Quit its UI before starting dev.sh; production Agent Relay can remain open.")
    try:
        if not args.proof:
            config = read_config(args.config, args.auth)
            errors += available_ports(config)
    except DevError as error:
        errors.append(str(error))
    if errors:
        raise DevError("Preflight failed:\n" + "\n".join(f"- {e}" for e in errors))
    if args.check:
        if not docker_running(env):
            say("Docker is not running; dev.sh starts Docker Desktop itself when that is the selected context.")
        say("Preflight passed. Google callback registration and authenticated E2E still require a live test.")
        return 0
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    STATE.chmod(0o700)
    lock = (STATE / "launcher.lock").open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise DevError("Another dev.sh owns this checkout. Stop it first.") from None
    supervisor = Supervisor(env)
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        ensure_docker(env)
        resume_cluster(env)
        python = ROOT / ".kind/venv/bin/python"
        if not python.exists():
            supervisor.run("python-venv", [sys.executable, "-m", "venv", python.parent.parent])
        supervisor.run("python-deps", [python, "-m", "pip", "install", "--disable-pip-version-check", "-r", ROOT / "ci/agent-relay/kind/requirements.txt"])
        if not args.reuse_containers:
            supervisor.run("local-tools", [python, ROOT / "ci/agent-relay/kind/local_tools.py", "--prepare"])
            missing = missing_bootstrapped(env)
            if missing:
                raise DevError("\n".join(missing))
        supervisor.run("kind-ready" if args.reuse_containers else "kind-up", [python, __file__, "--internal-ready" if args.reuse_containers else "--internal-up"], timeout=2400)
        record_node(env)  # The stack just verified this checkout's ownership receipt and cluster identity.
        # Use the same guarded Stack class for all credential-bearing local changes.
        supervisor.run("configure-control", [python, __file__, "--internal-configure", str(args.config), args.auth])
        if not args.no_service_watch:
            start_backends(parent, python, supervisor)
        kube = ["kubectl", "--kubeconfig", ROOT / ".kind/local/kubeconfig", "--context", "kind-agent-relay-local", "-n", "agent-relay"]
        supervisor.start("control-tunnel", [python, __file__, "--internal-tunnel", *kube, "port-forward", "--address", "127.0.0.1", "svc/relay-control", f"{config['controlPort']}:80"])
        wait_http(f"http://127.0.0.1:{config['controlPort']}/healthz", supervisor)
        for name in ("agentrelay.com", "relay-webapp"):
            install_node(parent / name, supervisor)
        origin = f"http://localhost:{config['port']}"
        # No CLOUD_DEV_ORIGIN: the gateway routes /cloud directly, avoiding a loop.
        web_env = dict(env, NEXT_PUBLIC_APP_URL=origin, NEXT_PUBLIC_CLOUD_URL=origin + "/cloud", CLOUD_PUBLIC_URL=origin + "/cloud")
        web_env.pop("CLOUD_DEV_ORIGIN", None)
        supervisor.start("next", ["npm", "--workspace", "web", "run", "dev", "--", "--hostname", "127.0.0.1", "--port", str(config["nextPort"])], cwd=parent / "agentrelay.com", env=web_env)
        dashboard_env = dict(env, DASHBOARD_BASE_PATH="/cloud/dashboard/", DASHBOARD_RUNTIME_CONFIG_URL="/runtime-config.js")
        dashboard_env.pop("DASHBOARD_API_ORIGIN", None)
        supervisor.start("dashboard", ["npm", "run", "dev", "--", "--port", str(config["dashboardPort"])], cwd=parent / "relay-webapp", env=dashboard_env)
        gateway_env = dict(env, RELAY_DEV_PORTS=json.dumps({k: config[k] for k in PORTS}))
        supervisor.start("gateway", ["node", ROOT / "scripts/dev/gateway.mjs"], env=gateway_env)
        wait_http(origin + "/login", supervisor, timeout=180)
        wait_http(origin + "/cloud/dashboard/", supervisor)
        say(f"Web: {origin} | Dashboard: {origin}/cloud/dashboard/ | Operator login: {origin}/operator-login")
        say("Containers: native Control, Relaycast, ingest, consumer, reader, brief worker, collector, Postgres, MinIO and ingress.")
        say("Full E2E requires Google sign-in, Desktop upload and authenticated transcript readback; startup alone is readiness evidence.")
        say("Google mode permits outbound public HTTPS from Control for OIDC. Other pods retain the kind egress policy." if args.auth == "google" else "Operator mode selected: Google sign-in is not configured.")
        if not args.no_desktop:
            repo = parent / "relay-desktop"
            # Before the build: an edit made during or right after it must still trigger a reload.
            snapshot = source_snapshot(repo)
            app, arch = build_desktop(repo, origin, supervisor)
            launch_desktop(app, origin, supervisor, restart=True)
            say("Desktop launched. Swift/Rust/resource edits rebuild and relaunch the Dev UI; Next and dashboard use HMR. Ctrl-C stops this invocation.")
        else:
            say("Web HMR active. Ctrl-C stops this invocation.")
        while True:
            time.sleep(1)
            supervisor.check()
            if args.no_desktop:
                continue
            if supervisor.desktop_process and supervisor.desktop_process.poll() is not None:
                raise DevError("Desktop UI exited. See desktop-ui.log; restart dev.sh when ready.")
            current = source_snapshot(repo)
            if current == snapshot:
                continue
            time.sleep(.5)  # Coalesce editor saves; take snapshot before building so later edits are not lost.
            snapshot = source_snapshot(repo)
            stop_desktop_ui(supervisor)
            try:
                supervisor.run("desktop-reload", ["bash", "scripts/dev-reload.sh", "--app", app, "--arch", arch], cwd=repo)
                launch_desktop(app, origin, supervisor, restart=True)
                say("Desktop reloaded.")
            except DevError as error:
                say(str(error) + " Fix the source and save to retry; the UI remains stopped.")
    finally:
        restored = supervisor.close()
        try:
            finish_cluster(env, args.keep_running, restored)
        finally:
            lock.close()


def finish_cluster(env, keep_running, restored):
    """Pause on exit unless asked not to, or while the backend watcher still needs the API server."""
    try:
        if not restored:
            say("Cluster left running: backend restoration is unfinished or failed. "
                "A new dev.sh refuses to start until it is resolved; ./dev.sh --stop pauses it afterwards.")
        elif keep_running:
            if node_state(env) == "running":
                say("Cluster left running (--keep-running). Pause it later with ./dev.sh --stop.")
        elif pause_cluster(env):
            say("Cluster paused. ./dev.sh resumes it; --reuse-containers is the fastest restart.")
    except DevError as error:
        say(f"{error} The cluster may still be running.")


if __name__ == "__main__":
    try:
        if len(sys.argv) == 2 and sys.argv[1] in {"--internal-up", "--internal-ready"}:
            sys.path.insert(0, str(ROOT / "ci/agent-relay/kind"))
            from local_stack import LocalStack
            stack = LocalStack("core")
            stack.docker(require_space=False)
            if sys.argv[1] == "--internal-ready":
                stack.require_owned_cluster()
                if not (stack.state / "selection.json").exists():
                    raise DevError("Native local stack is incomplete. Run ./dev.sh without --reuse-containers.")
                stack.k("wait", "deployment", "--all", "--for=condition=Available", "--timeout=120s", timeout=150)
            else:
                stack.up_local()
        elif len(sys.argv) == 4 and sys.argv[1] == "--internal-configure":
            sys.path.insert(0, str(ROOT / "ci/agent-relay/kind"))
            from local_stack import LocalStack
            configure_control(LocalStack("core"), read_config(Path(sys.argv[2]), sys.argv[3]), sys.argv[3])
        elif len(sys.argv) > 2 and sys.argv[1] == "--internal-tunnel":
            # Service forwarding binds a pod. Reconnect after development rollouts.
            while True:
                subprocess.call(sys.argv[2:])
                time.sleep(1)
        else:
            sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except DevError as error:
        print(f"[dev] ERROR: {error}", file=sys.stderr)
        sys.exit(1)
