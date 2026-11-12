import base64
import hashlib
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "release_candidate", ROOT / "scripts/release/update-release-candidate.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

VERIFY_SPEC = importlib.util.spec_from_file_location(
    "sessions_sigstore",
    ROOT / "scripts/release/verify-sessions-pipeline-sigstore.py",
)
assert VERIFY_SPEC and VERIFY_SPEC.loader
VERIFY = importlib.util.module_from_spec(VERIFY_SPEC)
VERIFY_SPEC.loader.exec_module(VERIFY)


DIGEST_A = "sha256:" + "1" * 64
DIGEST_B = "sha256:" + "2" * 64
SHA_A = "a" * 40
SHA_B = "b" * 40
RUN_ID = 11111111111
BLOCKED = ROOT / "scripts/release/blocked-image-digests.json"


class ReleaseCandidateTest(unittest.TestCase):
    def test_update_creates_provenance_ledger_and_every_sessions_surface(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            output = MODULE.update(
                root, "2026.11.1", "sessions-pipeline", DIGEST_A, SHA_A, RUN_ID
            )
            data = json.loads((output / "pins.json").read_text())
            self.assertEqual(data["version"], "2026.11.1")
            self.assertEqual(
                data["pins"]["sessions-pipeline"]["sourceRepository"],
                "AgentWorkforce/relayhistory-pipeline",
            )
            self.assertEqual(
                data["pins"]["sessions-pipeline"]["publishRunId"], RUN_ID
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

    def test_sessions_publish_run_id_is_required_and_component_scoped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for run_id in (None, 0, -1, True):
                with self.subTest(run_id=run_id):
                    with self.assertRaisesRegex(ValueError, "positive publish_run_id"):
                        MODULE.update(
                            root,
                            "2026.11.1",
                            "sessions-pipeline",
                            DIGEST_A,
                            SHA_A,
                            run_id,
                        )
            with self.assertRaisesRegex(ValueError, "only to sessions-pipeline"):
                MODULE.update(
                    root,
                    "2026.11.1",
                    "relay-control",
                    DIGEST_A,
                    SHA_A,
                    RUN_ID,
                )

    def test_sessions_update_migrates_an_open_legacy_candidate_but_validation_rejects_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            candidate = root / "releases/agent-relay-2026.11.1"
            candidate.mkdir(parents=True)
            legacy = {
                "schema": 1,
                "version": "2026.11.1",
                "pins": {
                    "sessions-pipeline": {
                        "repository": "ghcr.io/agentworkforce/sessions-pipeline",
                        "digest": DIGEST_A,
                        "sourceRepository": "AgentWorkforce/relayhistory-pipeline",
                        "sourceRevision": SHA_A,
                    }
                },
            }
            path = candidate / "pins.json"
            path.write_text(json.dumps(legacy))
            with self.assertRaisesRegex(ValueError, "malformed pin"):
                MODULE.load_pins(path, "2026.11.1")
            output = MODULE.update(
                root,
                "2026.11.1",
                "sessions-pipeline",
                DIGEST_A,
                SHA_A,
                RUN_ID,
            )
            data = MODULE.load_pins(output / "pins.json", "2026.11.1")
            self.assertEqual(
                data["pins"]["sessions-pipeline"]["publishRunId"], RUN_ID
            )

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

    def test_values_overlay_must_be_the_exact_ledger_render(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            output = MODULE.update(
                root, "2026.11.1", "relay-control", DIGEST_A, SHA_A
            )
            MODULE.validate_candidate(
                output / "pins.json", output / "values.yaml", "2026.11.1"
            )
            (output / "values.yaml").write_text(
                (output / "values.yaml").read_text() + "relay-control: {}\n"
            )
            with self.assertRaisesRegex(ValueError, "does not match"):
                MODULE.validate_candidate(
                    output / "pins.json", output / "values.yaml", "2026.11.1"
                )
            (output / "values.yaml").write_bytes(
                MODULE.render_values(
                    MODULE.load_pins(output / "pins.json", "2026.11.1")
                ).replace("\n", "\r\n").encode("utf-8")
            )
            with self.assertRaisesRegex(ValueError, "does not match"):
                MODULE.validate_candidate(
                    output / "pins.json", output / "values.yaml", "2026.11.1"
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
        self.assertIn('--values "$candidate_values"', workflow)
        self.assertIn("update-release-candidate.py check-policy", workflow)
        self.assertIn('gh attestation verify "oci://${repository}@${digest}"', workflow)
        self.assertIn('--source-digest "$source_sha"', workflow)
        self.assertIn("--source-ref refs/heads/main", workflow)
        self.assertIn("--signer-workflow", workflow)
        self.assertIn("verify-sessions-pipeline-sigstore.py", workflow)
        self.assertIn('publish_run_id="$(jq -er \'.publishRunId\'', workflow)
        self.assertIn("gh run download", workflow)
        for receipt_file in VERIFY.FILES:
            self.assertIn(f".release/{receipt_file}", workflow)

    def test_candidate_workflow_routes_only_sessions_through_sigstore_receipt(self):
        workflow = (ROOT / ".github/workflows/release-candidate.yml").read_text()
        self.assertIn("publish_run_id:", workflow)
        self.assertIn('if [[ "$COMPONENT" == "sessions-pipeline" ]]', workflow)
        self.assertIn("verify-sessions-pipeline-sigstore.py", workflow)
        self.assertIn("gh run download \"$PUBLISH_RUN_ID\"", workflow)
        self.assertIn('gh attestation verify "oci://${IMAGE_REPOSITORY}@${DIGEST}"', workflow)


class SessionsSigstoreReceiptTest(unittest.TestCase):
    def mutate_bundle(self, root: pathlib.Path, name: str, mutate) -> None:
        path = root / name
        bundle = json.loads(path.read_text())
        statement = json.loads(base64.b64decode(bundle["dsseEnvelope"]["payload"]))
        mutate(statement)
        bundle["dsseEnvelope"]["payload"] = base64.b64encode(
            json.dumps(statement).encode()
        ).decode()
        path.write_text(json.dumps(bundle))

    def write_receipt(self, root: pathlib.Path) -> tuple[str, str]:
        source_sha = "c" * 40
        workflow_sha = "d" * 40
        index = b'{"schemaVersion":2}\n'
        digest_hex = hashlib.sha256(index).hexdigest()
        digest = "sha256:" + digest_hex
        images = [f"{repository}@{digest}" for repository in VERIFY.IMAGE_REPOSITORIES]
        (root / "services-index.json").write_bytes(index)
        (root / "release-receipt.json").write_text(
            json.dumps(
                {
                    "repository": VERIFY.REPOSITORY,
                    "image": images[0],
                    "images": images,
                    "source_sha": source_sha,
                    "workflow_sha": workflow_sha,
                    "source_ref": VERIFY.SOURCE_REF,
                    "attestation_backend": "sigstore",
                    "ci_run_id": "22222222222",
                    "publish_run_id": str(RUN_ID),
                    "publish_run_attempt": "1",
                }
            )
        )
        subject = [
            {"name": "services-index.json", "digest": {"sha256": digest_hex}}
        ]
        build = {
            "_type": "https://in-toto.io/Statement/v0.1",
            "subject": subject,
            "predicateType": VERIFY.BUILD_TYPE,
            "predicate": {
                "buildDefinition": {
                    "buildType": "https://agentrelay.com/builders/services-image/v1",
                    "externalParameters": {
                        "image": VERIFY.IMAGE_REPOSITORIES[0],
                        "images": list(VERIFY.IMAGE_REPOSITORIES),
                        "repository": VERIFY.REPOSITORY,
                        "source_ref": VERIFY.SOURCE_REF,
                        "source_sha": source_sha,
                    },
                    "resolvedDependencies": [
                        {
                            "digest": {"gitCommit": source_sha},
                            "uri": "git+" + VERIFY.REPOSITORY,
                        }
                    ],
                },
                "runDetails": {
                    "builder": {
                        "id": (
                            f"{VERIFY.REPOSITORY}/{VERIFY.WORKFLOW}@{workflow_sha}"
                        )
                    },
                    "metadata": {
                        "invocationId": (
                            f"{VERIFY.REPOSITORY}/actions/runs/{RUN_ID}/attempts/1"
                        )
                    },
                },
            },
        }
        reviewed = {
            "_type": "https://in-toto.io/Statement/v0.1",
            "subject": subject,
            "predicateType": VERIFY.SOURCE_TYPE,
            "predicate": {
                "ci_run_id": "22222222222",
                "image": images[0],
                "images": images,
                "repository": VERIFY.REPOSITORY,
                "source_ref": VERIFY.SOURCE_REF,
                "source_sha": source_sha,
                "workflow_sha": workflow_sha,
            },
        }
        for name, value in (
            ("build-provenance.sigstore.json", build),
            ("reviewed-source.sigstore.json", reviewed),
        ):
            payload = base64.b64encode(json.dumps(value).encode()).decode()
            (root / name).write_text(json.dumps({"dsseEnvelope": {"payload": payload}}))
        return digest, source_sha

    def test_exact_receipt_claims_and_both_cosign_bundles_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            digest, source_sha = self.write_receipt(root)
            with mock.patch.object(VERIFY.subprocess, "run") as run:
                VERIFY.verify(root, digest, source_sha, str(RUN_ID))
            self.assertEqual(run.call_count, 2)
            commands = [call.args[0] for call in run.call_args_list]
            self.assertTrue(all("--new-bundle-format" in command for command in commands))
            self.assertEqual(
                [command[command.index("--type") + 1] for command in commands],
                ["slsaprovenance1", VERIFY.SOURCE_TYPE],
            )

    def test_receipt_mismatch_fails_before_cosign(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            digest, source_sha = self.write_receipt(root)
            receipt_path = root / "release-receipt.json"
            receipt = json.loads(receipt_path.read_text())
            receipt["publish_run_id"] = "999"
            receipt_path.write_text(json.dumps(receipt))
            with mock.patch.object(VERIFY.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "publish_run_id"):
                    VERIFY.verify(root, digest, source_sha, str(RUN_ID))
            run.assert_not_called()

    def test_signed_claim_mismatches_fail_closed(self):
        cases = (
            (
                "build-provenance.sigstore.json",
                lambda value: value["predicate"]["buildDefinition"][
                    "externalParameters"
                ].__setitem__("source_sha", "e" * 40),
                "external parameters",
            ),
            (
                "reviewed-source.sigstore.json",
                lambda value: value["predicate"].__setitem__(
                    "image", "ghcr.io/agentworkforce/sessions-pipeline@sha256:" + "f" * 64
                ),
                "reviewed source",
            ),
            (
                "build-provenance.sigstore.json",
                lambda value: value["subject"][0]["digest"].__setitem__(
                    "sha256", "f" * 64
                ),
                "subject",
            ),
            (
                "build-provenance.sigstore.json",
                lambda value: value["predicate"]["runDetails"]["builder"].__setitem__(
                    "id", "https://github.com/example/other/workflow.yml@deadbeef"
                ),
                "builder identity",
            ),
            (
                "build-provenance.sigstore.json",
                lambda value: value["predicate"]["runDetails"]["metadata"].__setitem__(
                    "invocationId", "https://github.com/example/actions/runs/1/attempts/1"
                ),
                "invocation",
            ),
        )
        for bundle, mutate, message in cases:
            with self.subTest(bundle=bundle, message=message):
                with tempfile.TemporaryDirectory() as directory:
                    root = pathlib.Path(directory)
                    digest, source_sha = self.write_receipt(root)
                    self.mutate_bundle(root, bundle, mutate)
                    with mock.patch.object(VERIFY.subprocess, "run"):
                        with self.assertRaisesRegex(ValueError, message):
                            VERIFY.verify(root, digest, source_sha, str(RUN_ID))

    def test_cosign_verification_failure_is_fatal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            digest, source_sha = self.write_receipt(root)
            error = VERIFY.subprocess.CalledProcessError(1, ["cosign"])
            with mock.patch.object(VERIFY.subprocess, "run", side_effect=error):
                with self.assertRaises(VERIFY.subprocess.CalledProcessError):
                    VERIFY.verify(root, digest, source_sha, str(RUN_ID))


if __name__ == "__main__":
    unittest.main()
