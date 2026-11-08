"""Real Helm renders: public names, internal entrypoints and upgrade identity pins."""
from pathlib import Path
import subprocess
import re
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKERS = {
    "session-summary-worker": "bob-costas",
    "session-metadata-indexer": "hoopdb-indexer",
    "session-status-worker": "referee",
}


def render(chart="sessions-pipeline", args=(), success=True):
    command = ["helm", "template", "ci", "charts/" + chart, "-n", "ci", "--no-hooks"]
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
        self.assertTrue(set(WORKERS) | {"ci-session-ingest-api", "session-object-storage"} <= deployments.keys())
        for name, stage in WORKERS.items():
            pod = deployments[name]["spec"]["template"]
            selector = deployments[name]["spec"]["selector"]["matchLabels"]
            self.assertTrue(selector.items() <= pod["metadata"]["labels"].items())
            self.assertEqual(selector["app.kubernetes.io/component"], name)
            container = pod["spec"]["containers"][0]
            env = {item["name"]: item for item in container["env"]}
            self.assertEqual(env["SERVICE"]["value"], stage)
            self.assertEqual("SUMMARY_MASTER_KEYS_FILE" in env, stage == "bob-costas")
            self.assertNotIn("SUMMARY_MASTER_KEYS", env)
        ingest = deployments["ci-session-ingest-api"]["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(next(item["value"] for item in ingest["env"] if item["name"] == "SERVICE"), "alleyoop-ingest")
        for item in deployments["session-summary-worker"]["spec"]["template"]["spec"]["containers"][0]["env"]:
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
        error = render(args=["--is-upgrade"], success=False)
        self.assertIn("could replace MinIO's PersistentVolumeClaim 'locker'", error)

    def test_storage_upgrade_allowed_once_the_claim_is_accounted_for(self):
        pin_name = ["--set", "session-object-storage.fullnameOverride=locker", "--set", "session-object-storage.nameOverride=locker"]
        cases = {
            "pinned name": pin_name,
            "existing claim": ["--set", "session-object-storage.persistence.existingClaim=locker"],
            "acknowledged": ["--set", "acknowledgeStorageRename=true"],
        }
        for name, args in cases.items():
            with self.subTest(name):
                self.assertTrue(render(args=["--is-upgrade", *args]))

    def test_pinned_upgrade_keeps_the_original_claim(self):
        documents = render(args=["--is-upgrade", "--set", "session-object-storage.fullnameOverride=locker", "--set", "session-object-storage.nameOverride=locker"])
        claims = [item["metadata"]["name"] for item in documents if item["kind"] == "PersistentVolumeClaim"]
        self.assertEqual(claims, ["locker"])

    def test_fresh_install_is_not_gated(self):
        self.assertTrue(render())

    def test_terraform_binds_storage_to_the_rendered_ingest_service_account(self):
        documents = render()
        accounts = {item["metadata"]["name"] for item in documents if item["kind"] == "ServiceAccount"}
        self.assertIn("ci-session-ingest-api", accounts)
        for path in ("terraform/examples/aws/main.tf", "terraform/examples/aws-environments/main.tf", "terraform/examples/gcp/main.tf"):
            self.assertIn('["worker", "session-ingest-api"]', (ROOT / path).read_text(), path)


if __name__ == "__main__":
    unittest.main()
