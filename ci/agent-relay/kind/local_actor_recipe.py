"""Pure pinned actor recipe shared by provisioning and acceptance."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[3]
SHA = re.compile(r"[0-9a-f]{40}")
GATEWAY = re.compile(r"ghcr\.io/agentworkforce/relaycast-actors-gateway@sha256:[0-9a-f]{64}")


def recipe(root=None):
    root = ROOT if root is None else root
    source = json.loads((root / "ci/agent-relay/kind/relaycast-actors-source.json").read_text())
    if type(source.get("schema")) is not int or source["schema"] != 1 or set(source) != {"schema", "upstream", "relaycast", "gateway"}:
        raise ValueError("invalid local actor source recipe")
    for key, repository in (("upstream", "https://github.com/TerseAI/durable-actors.git"),
            ("relaycast", "https://github.com/AgentWorkforce/relaycast.git")):
        if source[key].get("repository") != repository or not SHA.fullmatch(source[key].get("revision", "")):
            raise ValueError("local actors require pinned source revisions")
    if not GATEWAY.fullmatch(source["gateway"].get("reference", "")) or source["gateway"].get("sourceRevision") != source["relaycast"]["revision"]:
        raise ValueError("local actor gateway and actor source must match")
    if type(source["upstream"].get("cargoJobs")) is not int or not 1 <= source["upstream"]["cargoJobs"] <= 4:
        raise ValueError("local actor Rust build requires bounded parallelism")
    dockerfile = root / "ci/agent-relay/kind/relaycast-actors-dev.Dockerfile"
    fingerprint = hashlib.sha256(json.dumps(source, sort_keys=True, separators=(",", ":")).encode() + dockerfile.read_bytes()).hexdigest()
    return {"source": source, "recipeSha256": fingerprint, "dockerfile": dockerfile,
            "runtimeTag": "local/durable-actors:" + fingerprint,
            "actorTag": "local/relaycast-actors-dev:" + fingerprint}
