"""Pinned native relaycontrol build and local OCI transport; no publication."""
import hashlib
import json
import re
from pathlib import Path
import tarfile

from addons import NODE, checkout
from stack import private_json

REVISION = "1f08cb624be66016eb0c135363553dd44e58f691"
REPOSITORY = "agent-relay-kind/selfhost-api"
TAG = REPOSITORY + ":" + REVISION[:7]


def inspect_archive(path, arch):
    # Read only named metadata; never extract archive paths onto the host.
    with tarfile.open(path) as archive:
        index = json.load(archive.extractfile("index.json"))
        manifests = index.get("manifests", [])
        if len(manifests) != 1 or manifests[0].get("platform") != {"architecture": arch, "os": "linux"}:
            raise ValueError("local control archive must contain exactly the native Linux manifest")
        descriptor = manifests[0]
        digest = descriptor.get("digest", "")
        if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
            raise ValueError("local control manifest has no valid digest")
        raw = archive.extractfile("blobs/sha256/" + digest.removeprefix("sha256:")).read()
        if digest != "sha256:" + hashlib.sha256(raw).hexdigest():
            raise ValueError("local control manifest digest does not match its bytes")
        manifest = json.loads(raw)
        config_digest = manifest["config"].get("digest", "")
        if not re.fullmatch(r"sha256:[a-f0-9]{64}", config_digest):
            raise ValueError("local control config has no valid digest")
        raw = archive.extractfile("blobs/sha256/" + config_digest.removeprefix("sha256:")).read()
        if config_digest != "sha256:" + hashlib.sha256(raw).hexdigest():
            raise ValueError("local control config digest does not match its bytes")
        config = json.loads(raw)
        if (config.get("architecture") != arch or config.get("os") != "linux"
                or config.get("config", {}).get("Labels", {}).get("org.opencontainers.image.revision") != REVISION):
            raise ValueError("local control architecture/source does not match the pinned build")
        return {"sourceRevision": REVISION, "tag": TAG, "architecture": arch,
                "reference": REPOSITORY + "@" + digest, "manifestDigest": digest,
                "configDigest": config_digest, "node": NODE}


def resolve(stack, image):
    if not image.startswith(REPOSITORY + "@"):
        return image
    receipt = json.loads((stack.state / "control-build.json").read_text())
    if (receipt.get("reference") != image or receipt.get("sourceRevision") != REVISION
            or receipt.get("architecture") != stack.arch or receipt.get("tag") != TAG):
        raise ValueError("local control reference needs a matching kind-build-control receipt")
    return TAG


def build(stack):
    stack.check_space(6 * 1024**3)
    source = stack.state / "control-source"
    checkout(stack, "relay-control", REVISION, source)
    builder = [*stack.docker_args, "buildx"]
    if stack.cmd([*builder, "version"], check=False).returncode:
        bundled = Path("/Applications/Docker.app/Contents/Resources/cli-plugins/docker-buildx")
        if not bundled.is_file():
            raise ValueError("the official control Dockerfile requires Docker BuildKit/buildx")
        builder = [bundled]
    print(f"Build native linux/{stack.arch} control from {REVISION}", flush=True)
    stack.cmd([*builder, "build", "--load", "--platform", f"linux/{stack.arch}",
               "--build-arg", "NODE_IMAGE=" + NODE, "--build-arg", "IMAGE_REVISION=" + REVISION,
               "--build-arg", "IMAGE_VERSION=0.3.0-kind." + REVISION[:7], "-t", TAG, source], timeout=900)
    archive = stack.state / "control-image.tar"
    try:
        stack.cmd([*stack.docker_args, "image", "save", "--platform", f"linux/{stack.arch}", "-o", archive, TAG], timeout=300)
        receipt = inspect_archive(archive, stack.arch)
    finally:
        archive.unlink(missing_ok=True)  # This attempt's transport only.
    private_json(stack.state / "control-build.json", receipt)
    values = json.loads(stack.overrides.read_text()) if stack.overrides.exists() else {}
    values.setdefault("relay-cloud-api", {})["image"] = {
        "repository": REPOSITORY, "digest": receipt["manifestDigest"], "pullPolicy": "Never"}
    private_json(stack.overrides, values)
    print("Built and selected " + receipt["reference"] + "; run kind-up to install. No image published.")


def alias(stack, image, metadata):
    tag = "docker.io/" + TAG
    reference = "docker.io/" + image
    for node in stack.cmd(["kind", "get", "nodes", "--name", stack.name]).stdout.splitlines():
        listing = stack.cmd([*stack.docker_args, "exec", node, "ctr", "--namespace", "k8s.io", "images", "ls", "name==" + tag]).stdout
        rows = [line.split() for line in listing.splitlines()[1:] if line.strip()]
        if len(rows) != 1 or rows[0][2] != metadata["manifestDigest"]:
            raise ValueError("node imported a different local control manifest")
        stack.cmd([*stack.docker_args, "exec", node, "ctr", "--namespace", "k8s.io", "images", "tag", "--force", tag, reference])
        info = json.loads(stack.cmd([*stack.docker_args, "exec", node, "crictl", "inspecti", reference]).stdout)
        if (info["status"]["id"] != metadata["configDigest"] or reference not in info["status"].get("repoDigests", [])
                or info["info"]["imageSpec"]["architecture"] != stack.arch):
            raise ValueError("CRI did not resolve the pinned native control image")
