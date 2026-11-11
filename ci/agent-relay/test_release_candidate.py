import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "release_candidate", ROOT / "scripts/release/update-release-candidate.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


DIGEST_A = "sha256:" + "1" * 64
DIGEST_B = "sha256:" + "2" * 64
SHA_A = "a" * 40
SHA_B = "b" * 40
BLOCKED = ROOT / "scripts/release/blocked-image-digests.json"


class ReleaseCandidateTest(unittest.TestCase):
    def test_update_creates_provenance_ledger_and_every_sessions_surface(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            output = MODULE.update(
                root, "2026.11.1", "sessions-pipeline", DIGEST_A, SHA_A
            )
            data = json.loads((output / "pins.json").read_text())
            self.assertEqual(data["version"], "2026.11.1")
            self.assertEqual(
                data["pins"]["sessions-pipeline"]["sourceRepository"],
                "AgentWorkforce/relayhistory-pipeline",
            )
            values = (output / "values.yaml").read_text()
            self.assertEqual(values.count("ghcr.io/agentworkforce/sessions-pipeline"), 10)
            self.assertEqual(values.count(DIGEST_A), 10)
            for key in (
                "worker:",
                "alleyoop:",
                "sessionReadApi:",
                "searchIndexer:",
                "ingestEdge:",
                "nativeConsumer:",
            ):
                self.assertIn(key, values)

    def test_second_component_is_preserved_and_output_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            MODULE.update(root, "2026.11.1", "relay-control", DIGEST_A, SHA_A)
            output = MODULE.update(
                root, "2026.11.1", "relay-webapp", DIGEST_B, SHA_B
            )
            before = (output / "values.yaml").read_bytes()
            MODULE.update(root, "2026.11.1", "relay-webapp", DIGEST_B, SHA_B)
            self.assertEqual((output / "values.yaml").read_bytes(), before)
            data = json.loads((output / "pins.json").read_text())
            self.assertEqual(list(data["pins"]), ["relay-control", "relay-webapp"])

    def test_dispatch_fields_fail_closed(self):
        cases = (
            ("unknown", DIGEST_A, SHA_A, "unsupported component"),
            ("relay-control", "sha256:bad", SHA_A, "digest"),
            ("relay-control", DIGEST_A, "A" * 40, "source_sha"),
        )
        for component, digest, source, message in cases:
            with self.subTest(component=component, digest=digest, source=source):
                with self.assertRaisesRegex(ValueError, message):
                    MODULE.validate_pin(component, digest, source)
        for version in ("v1.2.3", "01.2.3", "1.2.3-rc.1", "2026.11"):
            with self.subTest(version=version):
                with self.assertRaisesRegex(ValueError, "stable SemVer"):
                    MODULE.validate_version(version)

    def test_existing_ledger_cannot_redirect_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            output = MODULE.update(
                root, "2026.11.1", "relay-control", DIGEST_A, SHA_A
            )
            path = output / "pins.json"
            data = json.loads(path.read_text())
            data["pins"]["relay-control"]["repository"] = "evil.example/image"
            path.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, "repository drift"):
                MODULE.update(
                    root, "2026.11.1", "relay-control", DIGEST_B, SHA_B
                )

    def write_scrub_pin(self, root, version, crate_version=None):
        path = root / "scrub-bindgen-pin.json"
        path.write_text(
            json.dumps(
                {
                    "package_version": version,
                    "manifest": {"crateVersion": crate_version or version},
                }
            )
        )
        return path

    def test_withdrawn_sessions_digests_are_blocked(self):
        policy = json.loads(BLOCKED.read_text())
        self.assertEqual(len(policy["blocked"]["sessions-pipeline"]), 2)
        with tempfile.TemporaryDirectory() as directory:
            scrub_pin = self.write_scrub_pin(
                pathlib.Path(directory), "0.5.0-alpha.8"
            )
            for digest in policy["blocked"]["sessions-pipeline"]:
                with self.subTest(digest=digest):
                    with self.assertRaisesRegex(ValueError, "blocked image digest"):
                        MODULE.check_policy(
                            BLOCKED,
                            "sessions-pipeline",
                            digest,
                            SHA_A,
                            scrub_pin,
                        )

    def test_sessions_scrubber_allows_alpha5_and_alpha8_plus_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for version in ("0.5.0-alpha.5", "0.5.0-alpha.8", "0.5.0-alpha.19"):
                with self.subTest(version=version):
                    MODULE.check_policy(
                        BLOCKED,
                        "sessions-pipeline",
                        DIGEST_A,
                        SHA_A,
                        self.write_scrub_pin(root, version),
                    )
            for version in (
                "0.5.0-alpha.4",
                "0.5.0-alpha.6",
                "0.5.0-alpha.7",
                "0.5.0-beta.1",
            ):
                with self.subTest(version=version):
                    with self.assertRaisesRegex(ValueError, "disallowed relayscrubber"):
                        MODULE.check_policy(
                            BLOCKED,
                            "sessions-pipeline",
                            DIGEST_A,
                            SHA_A,
                            self.write_scrub_pin(root, version),
                        )

    def test_sessions_scrubber_manifest_version_must_match(self):
        with tempfile.TemporaryDirectory() as directory:
            pin = self.write_scrub_pin(
                pathlib.Path(directory), "0.5.0-alpha.8", "0.5.0-alpha.7"
            )
            with self.assertRaisesRegex(ValueError, "crateVersion differ"):
                MODULE.check_policy(
                    BLOCKED, "sessions-pipeline", DIGEST_A, SHA_A, pin
                )

    def test_pr_body_table_updates_in_place(self):
        with tempfile.TemporaryDirectory() as directory:
            output = MODULE.update(
                pathlib.Path(directory),
                "2026.11.1",
                "relay-control",
                DIGEST_A,
                SHA_A,
            )
            data = MODULE.load_pins(output / "pins.json", "2026.11.1")
            first = MODULE.render_body("Release tracking.\n", data)
            self.assertEqual(first.count(MODULE.MARKER_START), 1)
            self.assertIn("AgentWorkforce/relay-control@" + SHA_A, first)
            data["pins"]["relay-control"]["digest"] = DIGEST_B
            second = MODULE.render_body(first, data)
            self.assertEqual(second.count(MODULE.MARKER_START), 1)
            self.assertIn(DIGEST_B, second)
            self.assertNotIn(DIGEST_A, second)

    def test_tag_publish_reverifies_candidate_provenance(self):
        workflow = (ROOT / ".github/workflows/release-agent-relay.yml").read_text()
        self.assertIn("Reverify candidate policy and build provenance", workflow)
        self.assertIn("update-release-candidate.py validate", workflow)
        self.assertIn("update-release-candidate.py check-policy", workflow)
        self.assertIn('gh attestation verify "oci://${repository}@${digest}"', workflow)
        self.assertIn('--source-digest "$source_sha"', workflow)
        self.assertIn("--source-ref refs/heads/main", workflow)
        self.assertIn("--signer-workflow", workflow)


if __name__ == "__main__":
    unittest.main()
