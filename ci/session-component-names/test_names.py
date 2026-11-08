"""Real Helm renders: public names, internal entrypoints and upgrade identity pins."""
from pathlib import Path
import subprocess
import json
import re
import importlib.util
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKERS = {
    "session-summary-worker": "bob-costas",
    "session-metadata-indexer": "hoopdb-indexer",
    "session-status-worker": "referee",
}


def render(chart="sessions-pipeline", args=(), success=True, release="ci"):
    command = ["helm", "template", release, "charts/" + chart, "-n", "ci", "--no-hooks"]
    if chart == "sessions-pipeline":
        command += ["-f", "charts/sessions-pipeline/ci/default-values.yaml"]
    result = subprocess.run(command + list(args), cwd=ROOT, text=True, capture_output=True, timeout=45)
    if not success:
        if result.returncode == 0:
            raise AssertionError("deprecated values silently rendered")
        return result.stderr
    if result.returncode:
        raise AssertionError(result.stderr)
    return [document for document in yaml.safe_load_all(result.stdout) if document]


class Names(unittest.TestCase):
    def test_real_ingest_package_and_parent_dependencies(self):
        ingest = yaml.safe_load((ROOT / "charts/session-ingest-api/Chart.yaml").read_text())
        self.assertEqual(ingest["name"], "session-ingest-api")
        self.assertFalse((ROOT / "charts/alleyoop").exists())
        parent = yaml.safe_load((ROOT / "charts/sessions-pipeline/Chart.yaml").read_text())
        dependencies = {item.get("alias", item["name"]): item for item in parent["dependencies"]}
        self.assertEqual(dependencies["alleyoop"]["name"], "session-ingest-api")
        self.assertEqual(dependencies["session-object-storage"]["name"], "minio")

    def test_new_resources_keep_actual_engine_entrypoints_and_secret_boundary(self):
        documents = render()
        deployments = {item["metadata"]["name"]: item for item in documents if item["kind"] == "Deployment"}
        self.assertTrue({"ci-worker-" + name for name in WORKERS} | {"ci-session-ingest-api", "session-object-storage"} <= deployments.keys())
        for name, stage in WORKERS.items():
            pod = deployments["ci-worker-" + name]["spec"]["template"]
            selector = deployments["ci-worker-" + name]["spec"]["selector"]["matchLabels"]
            self.assertTrue(selector.items() <= pod["metadata"]["labels"].items())
            self.assertEqual(selector["app.kubernetes.io/component"], name)
            container = pod["spec"]["containers"][0]
            env = {item["name"]: item for item in container["env"]}
            self.assertEqual(env["SERVICE"]["value"], stage)
            self.assertEqual("SUMMARY_MASTER_KEYS_FILE" in env, stage == "bob-costas")
            self.assertNotIn("SUMMARY_MASTER_KEYS", env)
        ingest = deployments["ci-session-ingest-api"]["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(next(item["value"] for item in ingest["env"] if item["name"] == "SERVICE"), "alleyoop-ingest")
        for item in deployments["ci-worker-session-summary-worker"]["spec"]["template"]["spec"]["containers"][0]["env"]:
            if item["name"] == "LOCKER_ENDPOINT":
                self.assertEqual(item["value"], "http://session-object-storage:9000")

    def test_explicit_legacy_identity_pins_preserve_old_names_and_storage_claim(self):
        documents = render(args=[
            "--set", "worker.legacyResourceNames=true", "--set", "worker.fullnameOverride=sessions",
            "--set", "alleyoop.legacyResourceNames=true", "--set", "alleyoop.fullnameOverride=alleyoop",
            "--set", "session-object-storage.fullnameOverride=locker", "--set", "session-object-storage.nameOverride=locker",
            "--set", "worker.locker.endpoint=http://locker:9000", "--set", "alleyoop.locker.endpoint=http://locker:9000",
        ])
        deployments = {item["metadata"]["name"]: item for item in documents if item["kind"] == "Deployment"}
        self.assertTrue({"sessions-bob-costas", "sessions-hoopdb-indexer", "sessions-referee", "alleyoop-ingest", "locker"} <= deployments.keys())
        self.assertEqual(deployments["sessions-bob-costas"]["spec"]["selector"]["matchLabels"]["app.kubernetes.io/component"], "bob-costas")
        self.assertEqual(deployments["alleyoop-ingest"]["spec"]["selector"]["matchLabels"]["app.kubernetes.io/name"], "alleyoop")
        self.assertTrue(any(item["kind"] == "PersistentVolumeClaim" and item["metadata"]["name"] == "locker" for item in documents))
        volumes = deployments["locker"]["spec"]["template"]["spec"]["volumes"]
        self.assertTrue(any(volume.get("persistentVolumeClaim", {}).get("claimName") == "locker" for volume in volumes))

    def test_standalone_releases_and_fullname_overrides_have_disjoint_names(self):
        names = []
        for release, override in [("first", ""), ("second", ""), ("third", "owned-workers")]:
            documents = render("sessions-pipeline-worker", ["-f", "charts/sessions-pipeline-worker/ci/default-values.yaml", "--set", "fullnameOverride=" + override], release=release)
            current = {item["metadata"]["name"] for item in documents if item["kind"] == "Deployment"}
            self.assertEqual(len(current), 3)
            for previous in names:
                self.assertTrue(current.isdisjoint(previous))
            if override:
                self.assertTrue(all(name.startswith(override + "-") for name in current))
            names.append(current)

    def test_proof_discovery_uses_real_service_and_serviceaccount_in_both_modes(self):
        path = ROOT / "scripts/selfhost/session-identities.py"
        spec = importlib.util.spec_from_file_location("session_identities", path)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        for legacy in [False, True]:
            arguments = ["--set", "worker.legacyResourceNames=" + str(legacy).lower(), "--set", "alleyoop.legacyResourceNames=" + str(legacy).lower()]
            deployments = [item for item in render(args=arguments) if item["kind"] == "Deployment" and "app.kubernetes.io/name" in item["metadata"]["labels"]]
            for stage in WORKERS.values():
                discovered = helper.worker_deployment(deployments, stage)
                self.assertIn(discovered.removeprefix("deploy/"), {item["metadata"]["name"] for item in deployments})
            self.assertEqual(len(helper.service_accounts(deployments)), 2)
            pods = [{"metadata": {"name": item["metadata"]["name"] + "-pod"},
                     "spec": item["spec"]["template"]["spec"],
                     "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]}}
                    for item in deployments]
            found = helper.ingest_pod(pods)
            process = subprocess.run([sys.executable, str(path), "ingest-pod"], input=json.dumps({"items": pods}), text=True, capture_output=True)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(process.stdout.strip(), found)
            with self.assertRaises(ValueError):
                helper.ingest_pod(pods + pods)
            for pod in pods:
                pod["status"]["conditions"][0]["status"] = "False"
            with self.assertRaises(ValueError):
                helper.ingest_pod(pods)
            with self.assertRaises(ValueError):
                helper.worker_deployment(deployments + deployments, "referee")
        for name in ["e2e-gcp-proof.sh", "e2e-eks-proof.sh"]:
            self.assertIn("session-identities.py\" ingest-pod", (ROOT / "scripts/selfhost" / name).read_text())

    def test_kind_up_refuses_legacy_storage_before_readiness_or_dependencies_change(self):
        sys.path.insert(0, str(ROOT / "ci/agent-relay/kind"))
        import stack
        for metadata in [{"name": "locker"}, {"name": "custom-data", "annotations": {"meta.helm.sh/release-name": "kind-locker"}}]:
            with tempfile.TemporaryDirectory() as directory, patch.object(stack, "ROOT", Path(directory)), patch.object(stack.shutil, "which", return_value="/fake/tool"):
                local = stack.Stack("core")
                ready = local.state / "ready.json"
                ready.write_text("original readiness evidence")
                local.docker = lambda **kw: None
                local.require_owned_cluster = lambda: None
                local.cmd = lambda *args, **kw: SimpleNamespace(stdout=local.name + "\n")
                local.k = lambda *args, **kw: SimpleNamespace(stdout=json.dumps({"items": [{"metadata": metadata}]}))
                local.dependencies = lambda: self.fail("dependency preparation ran before the legacy storage refusal")
                with self.assertRaisesRegex(stack.StackError, "legacy kind-locker storage exists"):
                    local.up()
                self.assertEqual(ready.read_text(), "original readiness evidence")

    def test_kind_legacy_storage_check_allows_an_owned_empty_cluster(self):
        sys.path.insert(0, str(ROOT / "ci/agent-relay/kind"))
        import stack
        with tempfile.TemporaryDirectory() as directory, patch.object(stack, "ROOT", Path(directory)):
            local = stack.Stack("core")
            calls = []
            def lookup(*args, **kw):
                calls.append(args)
                return SimpleNamespace(stdout="")
            local.k = lookup
            local.require_no_legacy_storage()
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][:3], ("get", "namespace", stack.NS))

    def test_native_ci_selectors_include_all_four_renamed_app_deployments(self):
        documents = render()
        script = (ROOT / "ci/sessions-pipeline-search-worker-role/kind.sh").read_text()
        selectors = re.findall(r"app.kubernetes.io/name in \(([^)]+)\)", script)
        self.assertTrue(selectors)
        for selector in selectors:
            names = set(selector.split(","))
            matches = [item for item in documents if item["kind"] == "Deployment"
                       and item["metadata"]["labels"].get("app.kubernetes.io/name") in names]
            self.assertEqual(len(matches), 4, "native admission/readiness CI must select ingest and all workers")

    def test_old_dependency_key_refused_instead_of_silent_new_storage(self):
        error = render(args=["--set", "locker.enabled=false"], success=False)
        self.assertIn("locker dependency values were renamed to session-object-storage", error)

    def test_default_storage_upgrade_refused_before_it_can_replace_the_claim(self):
        error = render(args=["--is-upgrade", "--set", "worker.legacyResourceNames=true"], success=False)
        self.assertIn("could delete MinIO's PersistentVolumeClaim 'locker'", error)

    def test_storage_upgrade_allowed_once_the_claim_is_accounted_for(self):
        pin_name = ["--set", "session-object-storage.fullnameOverride=locker", "--set", "session-object-storage.nameOverride=locker"]
        cases = {
            "pinned name": pin_name,
            "operator-owned claim": ["--set", "session-object-storage.persistence.existingClaim=operator-claim"],
            "acknowledged": ["--set", "acknowledgeStorageRename=true"],
            "acknowledged locker claim": ["--set", "session-object-storage.persistence.existingClaim=locker", "--set", "acknowledgeStorageRename=true"],
        }
        for name, args in cases.items():
            with self.subTest(name):
                self.assertTrue(render(args=["--is-upgrade", "--set", "worker.legacyResourceNames=true", *args]))

    def test_existing_claim_named_locker_is_refused_because_helm_would_prune_it(self):
        args = ["--is-upgrade", "--set", "worker.legacyResourceNames=true", "--set", "session-object-storage.persistence.existingClaim=locker"]
        error = render(args=args, success=False)
        self.assertIn("persistence.existingClaim=locker does not protect", error)

    def test_pinned_upgrade_keeps_the_original_claim(self):
        documents = render(args=["--is-upgrade", "--set", "worker.legacyResourceNames=true", "--set", "session-object-storage.fullnameOverride=locker", "--set", "session-object-storage.nameOverride=locker"])
        claims = [item["metadata"]["name"] for item in documents if item["kind"] == "PersistentVolumeClaim"]
        self.assertEqual(claims, ["locker"])

    def test_fresh_install_is_not_gated(self):
        self.assertTrue(render())

    def test_terraform_binds_storage_to_the_rendered_ingest_service_account(self):
        documents = render()
        accounts = {item["metadata"]["name"] for item in documents if item["kind"] == "ServiceAccount"}
        self.assertIn("ci-session-ingest-api", accounts)
        for path in ("terraform/examples/aws/main.tf", "terraform/examples/aws-environments/main.tf", "terraform/examples/gcp/main.tf"):
            self.assertIn('["worker", "alleyoop", "session-ingest-api"]', (ROOT / path).read_text(), path)

    def test_storage_upgrade_refuses_custom_empty_or_incomplete_legacy_pins(self):
        for value in ["", "custom-storage", "locker"]:
            with self.subTest(fullname=value):
                error = render(args=["--is-upgrade", "--set", "worker.legacyResourceNames=true", "--set", "session-object-storage.fullnameOverride=" + value], success=False)
                self.assertIn("could delete MinIO's PersistentVolumeClaim 'locker'", error)

    def test_worker_upgrade_requires_legacy_names_or_explicit_cutover(self):
        args = ["-f", "charts/sessions-pipeline-worker/ci/default-values.yaml", "--is-upgrade"]
        self.assertIn("workload rename requires a drained cutover", render("sessions-pipeline-worker", args=args, success=False))
        self.assertTrue(render("sessions-pipeline-worker", args=args + ["--set", "legacyResourceNames=true"]))
        documents = render("sessions-pipeline-worker", args=args + ["--set", "acknowledgeWorkloadRename=true"])
        names = {item["metadata"]["name"] for item in documents if item["kind"] == "Deployment"}
        self.assertTrue(all(any(name.endswith(public) for public in WORKERS) for name in names))

    def test_foundation_keeps_legacy_identity_output_and_adds_new_identity(self):
        output = (ROOT / "terraform/modules/aws/foundation/outputs.tf").read_text()
        self.assertRegex(output, r'alleyoop\s*=\s*"\$\{var.release_name\}-alleyoop"')
        self.assertRegex(output, r'session_ingest_api\s*=\s*"\$\{var.release_name\}-session-ingest-api"')


if __name__ == "__main__":
    unittest.main()
