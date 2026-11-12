import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from api import Failure
from context import ROLES, collect

ROOT = Path(__file__).resolve().parents[4]
UUID = "11111111-1111-4111-8111-111111111111"


class ActorContextTests(unittest.TestCase):
    def test_source_built_actor_is_explicit_and_both_containers_are_checked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("local_actor_recipe.py", "relaycast-actors-source.json", "relaycast-actors-dev.Dockerfile"):
                destination = root / "ci/agent-relay/kind" / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / "ci/agent-relay/kind" / name, destination)
            spec = importlib.util.spec_from_file_location("fixture_recipe", root / "ci/agent-relay/kind/local_actor_recipe.py")
            module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
            recipe = module.recipe(root)
            selected = {key: "ghcr.io/agentworkforce/" + key + "@sha256:" + "a" * 64 for _, _, key in ROLES}
            selected.update(relaycastBackend="durable-actors", relaycast=recipe["source"]["gateway"]["reference"], relaycastActors=recipe["actorTag"])
            (root / "selection.json").write_text(json.dumps(selected))
            (root / "tenant.json").write_text(json.dumps({"organizationId": UUID, "workspaceId": UUID}))
            built = {"recipeSha256": recipe["recipeSha256"], "actorTag": recipe["actorTag"],
                "runtimeImageId": "sha256:" + "1" * 64, "actorImageId": "sha256:" + "2" * 64, "actorConfigId": "sha256:" + "3" * 64,
                "upstreamRevision": recipe["source"]["upstream"]["revision"], "relaycastRevision": recipe["source"]["relaycast"]["revision"]}
            built["kindImages"] = {"owned-node": {"imageId": built["actorConfigId"], "repoDigests": []}}
            (root / "actor-build").mkdir()
            receipt = root / "actor-build/images.json"; receipt.write_text(json.dumps(built))
            roles = [(name, "gateway" if name == "relaycast" else container, key) for name, container, key in ROLES]
            roles.append(("relaycast", "durable-actors-dev", "relaycastActors"))
            deployments = {}
            for name, container, key in roles:
                d = deployments.setdefault(name, {"metadata": {"name": name, "generation": 1},
                    "spec": {"replicas": 1, "selector": {"matchLabels": {"app": name}}, "template": {"metadata": {"annotations": {"local.agentrelay.dev/actor-image-id": built["actorImageId"]}},
                        "spec": {"containers": [], "initContainers": []}}},
                    "status": {"replicas": 1, "readyReplicas": 1, "availableReplicas": 1, "updatedReplicas": 1, "observedGeneration": 1}})
                d["spec"]["template"]["spec"]["initContainers" if container == "copy-dashboard" else "containers"].append({"name": container, "image": selected[key]})
            pod = {"metadata": {"labels": {"app": "relaycast"}}, "spec": {"nodeName": "owned-node"},
                   "status": {"containerStatuses": [{"name": "durable-actors-dev", "ready": True, "imageID": built["actorConfigId"]}]}}
            def output(args):
                if "jsonpath={.metadata.uid}" in args: return UUID
                if "deployments" in args: return json.dumps({"items": list(deployments.values())})
                if "pods" in args: return json.dumps({"items": [pod]})
                return "b" * 40 if "rev-parse" in args else ""
            config = {"selectionFile": str(root / "selection.json"), "organizationId": UUID, "workspaceId": UUID, "kubeconfig": "fixture"}
            with patch("context.output", side_effect=output):
                observed = collect(config, root)
                self.assertEqual(len(observed["deployments"]), 10)
                self.assertEqual(observed["localBuilds"]["relaycastActors"]["actorImageId"], built["actorImageId"])
                sidecar = deployments["relaycast"]["spec"]["template"]["spec"]["containers"][-1]
                sidecar["image"] = "local/unknown:tag"
                with self.assertRaises(Failure): collect(config, root)
                sidecar["image"] = recipe["actorTag"]
                pod["status"]["containerStatuses"][0]["imageID"] = "sha256:" + "f" * 64
                with self.assertRaises(Failure): collect(config, root)
                pod["status"]["containerStatuses"][0]["imageID"] = built["actorConfigId"]
                built["upstreamRevision"] = "f" * 40; receipt.write_text(json.dumps(built))
                with self.assertRaises(Failure): collect(config, root)


if __name__ == "__main__":
    unittest.main()
