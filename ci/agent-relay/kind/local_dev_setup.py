#!/usr/bin/env python3
"""Clone matching release sources next to infra and bind make dev to local Kind."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import sys

import yaml

from local_stack import LocalStack, PIPELINE, CONTROL, WEBAPP, reference
from stack import ROOT, private_json, StackError, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default=".kind/dev/config.json")
    args = parser.parse_args()
    if Path(args.output).exists():
        raise SystemExit("development config already exists: " + args.output)
    # Read the developer's actual context before Stack selects a private,
    # anonymous pull config. That config intentionally has no context store.
    context = run(["docker", "context", "show"], env=dict(os.environ)).stdout.strip()
    plugins = json.loads(run(["docker", "info", "--format", "{{json .ClientInfo.Plugins}}"], env=dict(os.environ)).stdout)
    buildx = next((Path(p["Path"]) for p in plugins if p.get("Name") == "buildx" and p.get("Path")), None)
    if buildx is None or not buildx.is_file() or not os.access(buildx, os.X_OK):
        raise StackError("Docker Buildx plugin is missing; Docker Desktop must include its normal Buildx plugin")
    stack = LocalStack("core")
    stack.docker(require_space=False)
    stack.owned()
    # Keep Docker Desktop's installed plugin discoverable without inheriting
    # its global credential helper (which can prompt over SSH for public pulls).
    plugin_directory = stack.state / "docker-public" / "cli-plugins"
    plugin_directory.mkdir(mode=0o700, exist_ok=True)
    link = plugin_directory / "docker-buildx"
    if link.exists() or link.is_symlink():
        if link.resolve() != buildx.resolve():
            raise StackError("local Buildx plugin binding changed; inspect the checkout-local link before reconfiguring")
    else:
        link.symlink_to(buildx.resolve())
    node = stack.cmd(["kind", "get", "nodes", "--name", stack.name]).stdout.splitlines()
    if len(node) != 1:
        raise StackError("local dev setup expects its single-node Kind cluster")
    cast = yaml.safe_load((ROOT / "charts/relaycast/values.yaml").read_text())["image"]
    targets = {"webapp": ("relay-webapp", "relay-webapp", WEBAPP),
        "control": ("relay-control", "relay-control", CONTROL),
        "pipeline": ("relayhistory-pipeline", "sessions-pipeline", PIPELINE),
        "cast": ("relaycast", "relaycast", reference(cast))}
    sources = {}
    for group, (repo, directory, image) in targets.items():
        data = json.loads(stack.cmd([*stack.docker_args, "exec", node[0], "crictl", "inspecti", image], sensitive=True).stdout)
        labels = data.get("info", {}).get("imageSpec", {}).get("config", {}).get("Labels", {})
        revision = labels.get("org.opencontainers.image.revision", "")
        if not re.fullmatch(r"[a-f0-9]{40}", revision):
            raise StackError("deployed " + group + " image has no complete source revision label")
        path = ROOT.parent / directory
        if not path.exists():
            print("Clone " + repo + " at deployed source " + revision, flush=True)
            try:
                stack.cmd(["git", "clone", "--no-checkout", "https://github.com/AgentWorkforce/" + repo + ".git", path], timeout=600)
            except StackError:
                if path.exists() or not os.environ.get("SSH_AUTH_SOCK"):
                    raise StackError("cannot clone " + repo + "; source development needs GitHub read access (HTTPS credentials or an existing SSH agent)") from None
                print("HTTPS clone unavailable; use the existing SSH agent for " + repo, flush=True)
                stack.cmd(["git", "clone", "--no-checkout", "git@github.com:AgentWorkforce/" + repo + ".git", path], timeout=600)
            stack.cmd(["git", "-C", path, "checkout", "--detach", revision], timeout=120)
        elif not (path / ".git").exists():
            raise StackError("source path exists without Git metadata: " + str(path))
        # Existing developer checkouts and their changes are never switched.
        sources[group] = str(path)
    source_file = ROOT / ".kind/dev/sources.json"
    source_file.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    private_json(source_file, sources)
    run([sys.executable, ROOT / "ci/agent-relay/dev/configure.py",
        "--kubeconfig", stack.kubeconfig, "--context", "kind-" + stack.name,
        "--namespace", "agent-relay", "--docker-context", context,
        "--workspace", ROOT.parent, "--sources", source_file, "--output", args.output,
        "--public-docker-config", stack.state / "docker-public",
        "--docker-host", stack.env["DOCKER_HOST"],
        "--kind", shutil.which("kind"), "--kubectl", shutil.which("kubectl")], timeout=300, env=dict(os.environ))
    print("Source checkouts and development config ready; run make dev.")


if __name__ == "__main__":
    try:
        main()
    except StackError as error:
        raise SystemExit(str(error)) from None
