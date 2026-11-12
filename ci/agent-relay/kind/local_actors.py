"""Pinned local actor build; no command runs when the module is imported."""
import json
import re

from stack import StackError, private_json
from local_actor_recipe import recipe

IMAGE_ID = re.compile(r"sha256:[0-9a-f]{64}")


def checkout(stack, path, selected):
    """Reuse only an exact, clean checkout from the pinned public repository."""
    if path.is_symlink():
        raise StackError("local actor source cache must not be a symlink")
    if not path.exists():
        stack.cmd(["git", "clone", "--no-checkout", "--filter=blob:none", "--", selected["repository"], path], timeout=600)
        stack.cmd(["git", "-C", path, "checkout", "--detach", selected["revision"]], timeout=300)
    if (stack.cmd(["git", "-C", path, "rev-parse", "HEAD"]).stdout.strip() != selected["revision"]
            or stack.cmd(["git", "-C", path, "remote", "get-url", "origin"]).stdout.strip() != selected["repository"]
            or stack.cmd(["git", "-C", path, "status", "--porcelain", "--untracked-files=all"]).stdout.strip()):
        raise StackError("local actor source cache differs from its pinned revision; no checkout is overwritten")


def inspect(stack, tag):
    result = stack.cmd([*stack.docker_args, "image", "inspect", tag, "--format", "{{.Id}}"], check=False)
    value = result.stdout.strip()
    return value if result.returncode == 0 and IMAGE_ID.fullmatch(value) else None


def build(stack, selected=None):
    """Build upstream and its matching actor bundle; return explicit local image IDs."""
    selected = recipe() if selected is None else selected
    directory = stack.state / "actor-build"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    receipt_path = directory / "images.json"
    if receipt_path.is_symlink():
        raise StackError("local actor build receipt must not be a symlink")
    if receipt_path.exists():
        try:
            previous = json.loads(receipt_path.read_text())
            if (previous.get("recipeSha256") == selected["recipeSha256"]
                    and previous.get("runtimeImageId") == inspect(stack, selected["runtimeTag"])
                    and previous.get("actorImageId") == inspect(stack, selected["actorTag"])
                    and previous.get("runtimeImageId") is not None and previous.get("actorImageId") is not None):
                return previous
        except (OSError, ValueError):
            pass
    source_directory = directory / "sources"
    source_directory.mkdir(mode=0o700, exist_ok=True)
    for name in ("upstream", "relaycast"):
        checkout(stack, source_directory / name, selected["source"][name])
    upstream, relaycast = source_directory / "upstream", source_directory / "relaycast"
    package = json.loads((relaycast / "packages/actors-workspace/package.json").read_text())
    if package.get("dependencies", {}).get("durable-actors") != selected["source"]["upstream"]["sdkVersion"]:
        raise StackError("local actor SDK does not match the pinned upstream runtime")
    runtime_id, actor_id = directory / "upstream.iid", directory / "actor.iid"
    for path in (runtime_id, actor_id):
        if path.is_symlink():
            raise StackError("local actor image ID file must not be a symlink")
    stack.cmd([*stack.docker_args, "build", "--builder", "default", "--target", "typescript", "--iidfile", runtime_id,
        "--label", "org.opencontainers.image.revision=" + selected["source"]["upstream"]["revision"],
        "-t", selected["runtimeTag"], "-f", upstream / "Dockerfile", upstream], timeout=3600)
    stack.cmd([*stack.docker_args, "build", "--builder", "default", "--iidfile", actor_id,
        "--build-arg", "DURABLE_ACTORS_TYPESCRIPT_IMAGE=" + selected["runtimeTag"],
        "--label", "org.opencontainers.image.revision=" + selected["source"]["relaycast"]["revision"],
        "--label", "dev.agentrelay.actor-recipe=" + selected["recipeSha256"],
        "-t", selected["actorTag"], "-f", selected["dockerfile"], relaycast], timeout=1800)
    built = {"kind": "local-source-build", "recipeSha256": selected["recipeSha256"],
        "upstreamRevision": selected["source"]["upstream"]["revision"],
        "relaycastRevision": selected["source"]["relaycast"]["revision"],
        "gateway": selected["source"]["gateway"]["reference"],
        "runtimeTag": selected["runtimeTag"], "runtimeImageId": inspect(stack, selected["runtimeTag"]),
        "actorTag": selected["actorTag"], "actorImageId": inspect(stack, selected["actorTag"])}
    if (not built["runtimeImageId"] or not built["actorImageId"]
            or runtime_id.read_text().strip() != built["runtimeImageId"]
            or actor_id.read_text().strip() != built["actorImageId"]):
        raise StackError("built local actor image IDs did not match Docker inspection")
    private_json(receipt_path, built)
    print("Local actor build (image IDs, not published registry digests): " + json.dumps(built), flush=True)
    return built


def load(stack, built):
    stack.cmd(["kind", "load", "docker-image", "--name", stack.name, built["actorTag"]], timeout=300)
    # Bind the local Docker config ID to containerd's names on every owned node.
    # Pod imageID can be the config ID or a repository digest, depending on CRI.
    nodes = stack.cmd(["kind", "get", "nodes", "--name", stack.name]).stdout.splitlines()
    if not nodes:
        raise StackError("local actor image has no owned Kind nodes")
    imported = {}
    for node in nodes:
        status = json.loads(stack.cmd([*stack.docker_args, "exec", node, "crictl", "inspecti", built["actorTag"]]).stdout)["status"]
        if status.get("id") != built["actorImageId"]:
            raise StackError("Kind imported actor image differs from the local build")
        digests = status.get("repoDigests", [])
        if not isinstance(digests, list) or any(not isinstance(d, str) or not re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}", d) for d in digests):
            raise StackError("Kind actor repository digests are invalid")
        imported[node] = {"imageId": status["id"], "repoDigests": digests}
    built["kindImages"] = imported
    private_json(stack.state / "actor-build/images.json", built)
