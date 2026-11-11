#!/usr/bin/env python3
"""Install the verified Kind-profile macOS arm64 candidate in ~/Applications."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile

REPO = "AgentWorkforce/relay-desktop"
PROFILE = "q7m2k9"
SITE = "https://relay.kind.agentrelay.com"
TEAM = "QUJ7SA6X8X"
ROOT = Path(__file__).resolve().parents[3]


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, **kwargs).stdout


def error_message(error):
    message = str(error)
    if isinstance(error, subprocess.CalledProcessError):
        for output in (error.stderr, error.stdout):
            if isinstance(output, bytes):
                output = output.decode("utf-8", errors="replace")
            if output and output.strip():
                message += "\n" + output.strip()
    return message


def kind_run(ident):
    metadata = json.loads(run(["gh", "api", f"repos/{REPO}/actions/runs/{ident}"]))
    if metadata.get("conclusion") != "success" or metadata.get("event") != "workflow_dispatch" or metadata.get("path") != ".github/workflows/desktop-release.yml":
        return False
    jobs = json.loads(run(["gh", "api", f"repos/{REPO}/actions/runs/{ident}/jobs"]))["jobs"]
    job = next((j for j in jobs if j["name"] == "Resolve version"), None)
    if job is None:
        return False
    log = run(["gh", "run", "view", ident, "--repo", REPO, "--job", str(job["id"]), "--log"]).decode()
    return bool(re.search(r"\sPROFILE_ID: q7m2k9\s", log) and re.search(r"\sPREPARE_ONLY: true\s", log))


def latest_kind_run():
    """Require successful workflow_dispatch plus actual q7m2k9 prepare inputs."""
    runs = json.loads(run(["gh", "run", "list", "--repo", REPO, "--workflow", "desktop-release.yml",
        "--event", "workflow_dispatch", "--status", "success", "--limit", "100", "--json", "databaseId"]))
    for candidate in runs:
        ident = str(candidate["databaseId"])
        if kind_run(ident):
            return ident
    raise ValueError("no successful q7m2k9 prepare-only run in the latest 100 successful dispatches; supply --run")


def verify_download(directory):
    images = list(directory.glob("Desktop-q7m2k9-*-macOS-arm64.dmg"))
    if len(images) != 1:
        raise ValueError("expected exactly one q7m2k9 arm64 DMG")
    dmg = images[0]
    checksum = dmg.with_suffix(".dmg.sha256")
    fields = checksum.read_text().split()
    if len(fields) != 2 or fields[1].lstrip("*") != dmg.name or not re.fullmatch(r"[a-f0-9]{64}", fields[0]):
        raise ValueError("missing or malformed DMG SHA-256 sidecar")
    if hashlib.sha256(dmg.read_bytes()).hexdigest() != fields[0]:
        raise ValueError("DMG SHA-256 mismatch")
    return dmg, fields[0]


def inspect_app(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    resources = app / "Contents/Resources"
    if info.get("CFBundleIdentifier") != "com.agentrelay.desktop.q7m2k9" or (resources / "site-url.txt").read_text().strip() != SITE:
        raise ValueError("candidate bundle id or compiled site differs from the Kind profile")
    if (resources / "url-scheme.txt").read_text().strip() != "agentrelay-kind":
        raise ValueError("candidate URL scheme differs from the Kind profile")
    run(["codesign", "--verify", "--deep", "--strict", app])
    details = subprocess.run(["codesign", "-dv", "--verbose=2", str(app)], check=True, capture_output=True).stderr.decode()
    if not re.search(r"^TeamIdentifier=" + TEAM + r"$", details, re.MULTILINE):
        raise ValueError("candidate is not signed by the expected Agent Workforce team")


def publish_app(staged, destination):
    """Darwin exclusive rename publishes atomically without replacing any path."""
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(staged), os.fsencode(destination), 0x4) != 0:  # RENAME_EXCL
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def install(directory, *, launch=True):
    dmg, checksum = verify_download(directory)
    attached = plistlib.loads(run(["hdiutil", "attach", "-readonly", "-nobrowse", "-plist", dmg]))
    mounts = [Path(x["mount-point"]) for x in attached.get("system-entities", []) if "mount-point" in x]
    try:
        apps = [p for mount in mounts for p in mount.glob("*.app")]
        if len(apps) != 1:
            raise ValueError("expected exactly one app in the DMG")
        app = apps[0]
        inspect_app(app)
        destination = Path.home() / "Applications" / app.name
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if destination.exists() or destination.is_symlink():
            raise ValueError("Kind Desktop already exists at " + str(destination) + "; quit and remove that exact test app before reinstalling")
        with tempfile.TemporaryDirectory(prefix=".agent-relay-kind-", dir=destination.parent) as staging:
            staged = Path(staging) / app.name
            run(["ditto", app, staged])
            inspect_app(staged)
            publish_app(staged, destination)
    finally:
        for mount in mounts:
            run(["hdiutil", "detach", mount])
    receipt = {"profile": PROFILE, "site": SITE, "dmgSha256": checksum, "app": str(destination)}
    state = ROOT / ".kind" / "desktop"
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = state / "install.json"
    path.write_text(json.dumps(receipt, indent=2) + "\n")
    path.chmod(0o600)
    if launch:
        run(["open", destination])
    print("Installed " + str(destination))
    print("Sign in through the browser device flow at " + SITE + " using the local administrator.")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", help="explicit successful q7m2k9 prepare-only run; default discovers the latest")
    parser.add_argument("--artifact-dir", type=Path, help="existing dmg-arm64 download, for a Mac without GitHub CLI/auth")
    parser.add_argument("--no-launch", action="store_true")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("desktop-install requires Apple Silicon macOS")
    if args.artifact_dir:
        install(args.artifact_dir, launch=not args.no_launch)
        return
    if not shutil.which("gh"):
        parser.error("GitHub CLI with Actions read access is required; alternatively supply --artifact-dir from gh run download -n dmg-arm64")
    ident = args.run or latest_kind_run()
    if not re.fullmatch(r"[1-9][0-9]*", ident):
        parser.error("--run must be a numeric GitHub Actions run ID")
    if args.run and not kind_run(ident):
        parser.error("--run is not a successful q7m2k9 prepare-only Desktop dispatch")
    with tempfile.TemporaryDirectory(prefix="agent-relay-kind-desktop-") as tmp:
        run(["gh", "run", "download", ident, "--repo", REPO, "-n", "dmg-arm64", "-D", tmp])
        print("Kind candidate Actions run: " + ident)
        install(Path(tmp), launch=not args.no_launch)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError, OSError) as error:
        raise SystemExit(error_message(error)) from None
