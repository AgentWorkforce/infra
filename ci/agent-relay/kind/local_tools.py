#!/usr/bin/env python3
"""Checkout-local tools for a clean Mac; never installs Homebrew or uses sudo."""
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / ".kind" / "tools"
# Upstream release checksums, pinned independently of downloaded bytes.
RELEASES = {
    "darwin-arm64": {
        "kind": ("https://kind.sigs.k8s.io/dl/v0.30.0/kind-darwin-arm64", "ceaf40df1d1551c481fb50e3deb5c3deecad5fd599df5469626b70ddf52a1518", None),
        "helm": ("https://get.helm.sh/helm-v4.3.1-darwin-arm64.tar.gz", "6b4e61c8cd27d99e5a801e63ff25dd5c70b36875c2cd659d3e9ce6b76fc23198", "darwin-arm64/helm"),
    },
    "linux-amd64": {
        "kind": ("https://kind.sigs.k8s.io/dl/v0.30.0/kind-linux-amd64", "517ab7fc89ddeed5fa65abf71530d90648d9638ef0c4cde22c2c11f8097b8889", None),
        "helm": ("https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz", "0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b", "linux-amd64/helm"),
    },
}


def ensure_tools():
    target = platform.system().lower() + "-" + {"aarch64": "arm64", "x86_64": "amd64"}.get(platform.machine(), platform.machine())
    if target not in RELEASES:
        raise SystemExit("local-up currently supports Apple Silicon macOS and amd64 Linux")
    TOOLS.mkdir(parents=True, mode=0o700, exist_ok=True)
    for name, (url, checksum, member) in RELEASES[target].items():
        path = TOOLS / name
        stamp = TOOLS / (name + ".sha256")
        if path.exists() and stamp.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == stamp.read_text():
            continue
        print("Download pinned " + name, flush=True)
        with urllib.request.urlopen(url, timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != checksum:
            raise SystemExit(name + " release checksum mismatch")
        if member:
            with tempfile.TemporaryFile() as archive:
                archive.write(data)
                archive.seek(0)
                with tarfile.open(fileobj=archive, mode="r:gz") as tar:
                    data = tar.extractfile(member).read()
        path.write_bytes(data)
        path.chmod(0o700)
        stamp.write_text(hashlib.sha256(data).hexdigest())
    os.environ["PATH"] = str(TOOLS) + os.pathsep + os.environ["PATH"]


def main():
    if sys.argv[1:] not in ([], ["--prepare"]):
        raise SystemExit("usage: local_tools.py [--prepare]")
    ensure_tools()
    python = TOOLS / "venv" / "bin" / "python3"
    if not python.exists():
        subprocess.run([sys.executable, "-m", "venv", str(python.parents[1])], check=True)
    requirement = ROOT / "ci/agent-relay/kind/requirements.txt"
    stamp = TOOLS / "python-requirements.sha256"
    digest = hashlib.sha256(requirement.read_bytes()).hexdigest()
    if not stamp.exists() or stamp.read_text() != digest:
        subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check", "-r", str(requirement)], check=True)
        stamp.write_text(digest)
    subprocess.run([str(TOOLS / "kind"), "version"], check=True)
    subprocess.run([str(TOOLS / "helm"), "version", "--short"], check=True)
    print("Checkout-local tools ready: " + str(TOOLS), flush=True)


if __name__ == "__main__":
    main()
