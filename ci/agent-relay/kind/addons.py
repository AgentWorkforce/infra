"""Build real native add-on runtimes; never publish or emulate an image."""
import json
import shutil

FLOWS_REVISION = "9a9086be16fd33eea15af2adf3ce0a7cf1239aa9"  # v2.0.50
FILE_REVISION = "731ea459d2e486892638b292ad218bbd04dd21a3"
RUST = "rust:1.93.0-bookworm@sha256:d0a4aa3ca2e1088ac0c81690914a0d810f2eee188197034edf366ed010a2b382"
NODE = "node:22.23.3-bookworm-slim@sha256:3ed98443660ff48413b5af19ecefce3b9d50845a901a43420d47cc63a9fddbe9"


def checkout(stack, repository, revision, path):
    if not path.exists():
        path.mkdir(parents=True)
        stack.cmd(["git", "init", path])
        stack.cmd(["git", "-C", path, "remote", "add", "origin", f"https://github.com/AgentWorkforce/{repository}.git"])
        stack.cmd(["git", "-C", path, "fetch", "--depth", "1", "origin", revision], timeout=300)
        stack.cmd(["git", "-C", path, "checkout", "--detach", revision])
    if stack.cmd(["git", "-C", path, "rev-parse", "HEAD"]).stdout.strip() != revision:
        raise ValueError(f"add-on checkout is not pinned to {revision}: {path}")
    if stack.cmd(["git", "-C", path, "status", "--porcelain"]).stdout.strip():
        raise ValueError(f"refusing to build a modified add-on checkout: {path}")


def build(stack):
    # The SDK's supported RELAYFLOWD_BIN override selects the actual Rust
    # engine on both architectures, including where no npm runtime is shipped.
    # Large Cargo outputs/caches stay on the checkout volume, outside Docker.
    stack.check_space(6 * 1024**3)
    source = stack.state / "flows-source"
    checkout(stack, "flows", FLOWS_REVISION, source)
    native = stack.state / ("flows-native-" + stack.arch)
    native.mkdir(exist_ok=True)
    mounts = [(source, "/src", True)]
    for name, target in [("target", "/target"), ("registry", "/usr/local/cargo/registry"), ("git", "/usr/local/cargo/git")]:
        path = native / name
        path.mkdir(exist_ok=True)
        mounts.append((path, target, False))
    stack.pull(RUST)
    argv = [*stack.docker_args, "run", "--rm", "--cpus", "2", "--memory", "3g"]
    for path, target, readonly in mounts:
        argv += ["--mount", f"type=bind,source={path},target={target}" + (",readonly" if readonly else "")]
    print(f"Build native linux/{stack.arch} relayflowd from {FLOWS_REVISION}", flush=True)
    stack.cmd([*argv, "-e", "CARGO_BUILD_JOBS=2", RUST, "cargo", "build", "--locked", "--release",
               "--manifest-path", "/src/kernel/Cargo.toml", "--target-dir", "/target", "-p", "relayflowd"], timeout=1800)
    context = stack.state / "flows-build"
    context.mkdir(exist_ok=True)
    shutil.copy2(native / "target/release/relayflowd", context / "relayflowd")
    (context / "relayflowd").chmod(0o755)
    (context / "Dockerfile").write_text(
        f"FROM {NODE}\n"
        "RUN npm install -g --ignore-scripts --no-audit --no-fund relayflows@2.0.50\n"
        "COPY relayflowd /usr/local/bin/relayflowd\n"
        "ENV RELAYFLOWD_BIN=/usr/local/bin/relayflowd\nUSER node\n")
    stack.cmd([*stack.docker_args, "build", "-t", "agent-relay-kind/flows:2.0.50", context], timeout=900)
    file = stack.state / "relayfile-source"
    checkout(stack, "relayfile", FILE_REVISION, file)
    stack.cmd([*stack.docker_args, "build", "-f", file / "docker/Dockerfile.relayfile",
               "-t", "agent-relay-kind/relayfile:local", file], timeout=900)
    (stack.state / "addon-build.json").write_text(json.dumps({
        "architecture": stack.arch, "flowsRevision": FLOWS_REVISION,
        "relayfileRevision": FILE_REVISION, "rustBuilder": RUST, "node": NODE,
    }, indent=2) + "\n")
