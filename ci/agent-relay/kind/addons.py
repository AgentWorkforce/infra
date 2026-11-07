"""Build real native add-on runtimes; never publish or emulate an image."""
import json
import os
import secrets
import shutil
import tempfile
from pathlib import Path

import yaml

FLOWS_REVISION = "9a9086be16fd33eea15af2adf3ce0a7cf1239aa9"  # v2.0.50
FILE_REVISION = "731ea459d2e486892638b292ad218bbd04dd21a3"
RUST = "rust:1.93.0-bookworm@sha256:d0a4aa3ca2e1088ac0c81690914a0d810f2eee188197034edf366ed010a2b382"
NODE = "node:22.23.3-bookworm-slim@sha256:3ed98443660ff48413b5af19ecefce3b9d50845a901a43420d47cc63a9fddbe9"


def checkout(stack, repository, revision, path):
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        # Interrupted fetches never publish a half-initialized final checkout.
        staging = Path(tempfile.mkdtemp(prefix=path.name + "-fetch-", dir=path.parent))
        try:
            stack.cmd(["git", "init", staging])
            stack.cmd(["git", "-C", staging, "remote", "add", "origin", f"https://github.com/AgentWorkforce/{repository}.git"])
            stack.cmd(["git", "-C", staging, "fetch", "--depth", "1", "origin", revision], timeout=300)
            stack.cmd(["git", "-C", staging, "checkout", "--detach", revision])
            staging.rename(path)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
    if stack.cmd(["git", "-C", path, "rev-parse", "HEAD"]).stdout.strip() != revision:
        raise ValueError(f"add-on checkout is not pinned to {revision}: {path}")
    if stack.cmd(["git", "-C", path, "status", "--porcelain"]).stdout.strip():
        raise ValueError(f"refusing to build a modified add-on checkout: {path}")


def cargo_build(stack, source, native):
    native.mkdir(exist_ok=True)
    mounts = [(source, "/src", True)]
    for name, target in [("target", "/target"), ("cargo", "/cargo")]:
        path = native / name
        path.mkdir(exist_ok=True)
        mounts.append((path, target, False))
    stack.pull(RUST)
    name = "agent-relay-kind-cargo-" + secrets.token_hex(16)
    argv = [*stack.docker_args, "run", "--rm", "--name", name, "--cpus", "2", "--memory", "3g",
            "--user", f"{os.getuid()}:{os.getgid()}", "-e", "HOME=/tmp", "-e", "CARGO_HOME=/cargo"]
    for path, target, readonly in mounts:
        argv += ["--mount", f"type=bind,source={path},target={target}" + (",readonly" if readonly else "")]
    print(f"Build native linux/{stack.arch} relayflowd from {FLOWS_REVISION}", flush=True)
    try:
        stack.cmd([*argv, "-e", "CARGO_BUILD_JOBS=2", RUST, "cargo", "build", "--locked", "--release",
                   "--manifest-path", "/src/kernel/Cargo.toml", "--target-dir", "/target", "-p", "relayflowd"], timeout=1800)
    finally:
        # Killing the Docker client alone leaves its container alive. Remove
        # only the unique name allocated for this attempt, never a broad match.
        result = stack.cmd([*stack.docker_args, "rm", "-f", name], check=False)
        if result.returncode and "No such container" not in result.stderr:
            raise RuntimeError("owned Cargo build container cleanup failed")


def build(stack):
    # The SDK's supported RELAYFLOWD_BIN override selects the actual Rust
    # engine on both architectures, including where no npm runtime is shipped.
    # Large Cargo outputs/caches stay on the checkout volume, outside Docker.
    stack.check_space(6 * 1024**3)
    source = stack.state / "flows-source"
    checkout(stack, "flows", FLOWS_REVISION, source)
    sdk = Path(__file__).resolve().parent / "flows-sdk"
    package = json.loads((sdk / "package.json").read_text())
    lock = json.loads((sdk / "package-lock.json").read_text())
    version = package["dependencies"]["relayflows"]
    source_version = json.loads((source / "packages/relayflows/package.json").read_text())["version"]
    profile = yaml.safe_load((Path(__file__).resolve().parents[3] / "charts/agent-relay/values-kind-addons.yaml").read_text())
    if source_version != version or lock["packages"][""]["dependencies"]["relayflows"] != version or profile["relayflows"]["image"]["tag"] != version:
        raise ValueError("Flows source, SDK lock and kind image tag disagree")
    native = stack.state / ("flows-native-" + stack.arch)
    cargo_build(stack, source, native)
    context = stack.state / "flows-build"
    context.mkdir(exist_ok=True)
    shutil.copy2(native / "target/release/relayflowd", context / "relayflowd")
    (context / "relayflowd").chmod(0o755)
    for filename in ("package.json", "package-lock.json"):
        shutil.copy2(sdk / filename, context / filename)
    (context / "Dockerfile").write_text(
        f"FROM {NODE}\n"
        "WORKDIR /opt/relayflows\nCOPY package.json package-lock.json ./\n"
        "RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund\n"
        "ENV PATH=/opt/relayflows/node_modules/.bin:$PATH\n"
        "COPY relayflowd /usr/local/bin/relayflowd\n"
        "ENV RELAYFLOWD_BIN=/usr/local/bin/relayflowd\nUSER node\n")
    stack.cmd([*stack.docker_args, "build", "-t", f"agent-relay-kind/flows:{version}", context], timeout=900)
    file = stack.state / "relayfile-source"
    checkout(stack, "relayfile", FILE_REVISION, file)
    stack.cmd([*stack.docker_args, "build", "-f", file / "docker/Dockerfile.relayfile",
               "-t", "agent-relay-kind/relayfile:local", file], timeout=900)
    (stack.state / "addon-build.json").write_text(json.dumps({
        "architecture": stack.arch, "flowsRevision": FLOWS_REVISION,
        "relayfileRevision": FILE_REVISION, "rustBuilder": RUST, "node": NODE,
    }, indent=2) + "\n")
