import argparse
import importlib.util
import pathlib
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "release_manifest",
    ROOT / "scripts/release/build-agent-relay-release-manifest.py",
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
build = MODULE.build
build_values_overlay = MODULE.build_values_overlay


COMMIT = "a" * 40
DIGEST_A = "sha256:" + "1" * 64
DIGEST_B = "sha256:" + "2" * 64


class ReleaseManifestTest(unittest.TestCase):
    def build_fixture(self, image_lines, inventory_lines, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            images = root / "images.txt"
            inventory = root / "inventory.tsv"
            images.write_text("\n".join(image_lines) + "\n", encoding="utf-8")
            inventory.write_text(
                "\n".join(inventory_lines) + "\n", encoding="utf-8"
            )
            values = {
                "version": "2026.11.0",
                "infra_commit": COMMIT,
                "chart_path": "charts/agent-relay",
                "chart_version": "2026.11.0",
                "values_overlay_profile": "eks",
                "images": images,
                "inventory": inventory,
            }
            values.update(overrides)
            return build(argparse.Namespace(**values))

    def test_builds_exact_schema_and_normalizes_tagged_digest_ref(self):
        manifest = self.build_fixture(
            [
                f"ghcr.io/example/service:v1@{DIGEST_B}",
                f"ghcr.io/example/control@{DIGEST_A}",
                f"ghcr.io/example/service:v1@{DIGEST_B}",
            ],
            [
                f"service\tghcr.io/example/service\t{DIGEST_B}\tapproved",
                f"relay-control\tghcr.io/example/control\t{DIGEST_A}\tapproved",
            ],
        )
        self.assertEqual(
            manifest,
            {
                "schema": 1,
                "version": "2026.11.0",
                "infraCommit": COMMIT,
                "chart": {
                    "path": "charts/agent-relay",
                    "version": "2026.11.0",
                },
                "valuesOverlay": "release-images.values.yaml",
                "valuesOverlayProfile": "eks",
                "images": [
                    {
                        "name": "relay-control",
                        "ref": f"ghcr.io/example/control@{DIGEST_A}",
                    },
                    {
                        "name": "service",
                        "ref": f"ghcr.io/example/service@{DIGEST_B}",
                    },
                ],
            },
        )

    def test_overlay_sets_all_services_surfaces_and_postgres_scalar(self):
        names = [
            "relaycast",
            "relaycast-eks-collector",
            "relayauth",
            "sessions-pipeline",
            "relayhistory",
            "relay-control",
            "relay-webapp",
            "sessions-migration-postgresql",
        ]
        image_lines = []
        inventory_lines = []
        for index, name in enumerate(names, start=1):
            digest = "sha256:" + str(index) * 64
            repository = f"ghcr.io/example/{name}"
            image_lines.append(f"{repository}@{digest}")
            inventory_lines.append(f"{name}\t{repository}\t{digest}\tapproved")
        overlay = build_values_overlay(
            self.build_fixture(image_lines, inventory_lines)
        )
        self.assertEqual(
            overlay.count("__IMAGE_MIRROR_ROOT__/ghcr.io/example/sessions-pipeline"),
            10,
        )
        self.assertEqual(
            overlay.count(
                "__IMAGE_MIRROR_ROOT__/ghcr.io/example/relaycast-eks-collector"
            ),
            2,
        )
        self.assertNotIn(
            "repository: __IMAGE_MIRROR_ROOT__/ghcr.io/example/relaycast\n",
            overlay,
        )
        self.assertIn("# customer registry mirror root. Profile: eks.", overlay)
        self.assertIn("runtime:\n    postgres:\n      image:", overlay)
        self.assertIn("sessionReadApi:\n    image:", overlay)
        self.assertIn("nativeConsumer:\n    image:", overlay)
        self.assertIn(
            "image: __IMAGE_MIRROR_ROOT__/ghcr.io/example/"
            "sessions-migration-postgresql@sha256:",
            overlay,
        )

    def test_rejects_unpinned_customer_image(self):
        with self.assertRaisesRegex(ValueError, "not pinned"):
            self.build_fixture(
                ["ghcr.io/example/service:latest"],
                [f"service\tghcr.io/example/service\t{DIGEST_A}\tapproved"],
            )

    def test_rejects_image_missing_from_inventory(self):
        with self.assertRaisesRegex(ValueError, "absent from the inventory"):
            self.build_fixture(
                [f"ghcr.io/example/other@{DIGEST_B}"],
                [f"service\tghcr.io/example/service\t{DIGEST_A}\tapproved"],
            )

    def test_rejects_blocked_customer_image(self):
        with self.assertRaisesRegex(ValueError, r"not release-approved \(blocked\)"):
            self.build_fixture(
                [f"ghcr.io/example/service@{DIGEST_A}"],
                [f"service\tghcr.io/example/service\t{DIGEST_A}\tblocked"],
            )

    def test_accepts_customer_ready_image_status(self):
        manifest = self.build_fixture(
            [f"ghcr.io/example/service@{DIGEST_A}"],
            [
                f"service\tghcr.io/example/service\t{DIGEST_A}"
                "\tcustomer-ready"
            ],
        )
        self.assertEqual(
            manifest["images"],
            [{"name": "service", "ref": f"ghcr.io/example/service@{DIGEST_A}"}],
        )

    def test_release_version_is_independent_of_chart_version(self):
        manifest = self.build_fixture(
            [f"ghcr.io/example/service@{DIGEST_A}"],
            [f"service\tghcr.io/example/service\t{DIGEST_A}\tapproved"],
            chart_version="0.6.36",
        )
        self.assertEqual(manifest["version"], "2026.11.0")
        self.assertEqual(manifest["chart"]["version"], "0.6.36")

    def test_gcp_overlay_keeps_the_gcp_relaycast_image(self):
        names = [
            "relaycast",
            "relayauth",
            "sessions-pipeline",
            "relayhistory",
            "relay-control",
            "relay-webapp",
            "sessions-migration-postgresql",
        ]
        image_lines = []
        inventory_lines = []
        for index, name in enumerate(names, start=1):
            digest = "sha256:" + str(index) * 64
            repository = f"ghcr.io/example/{name}"
            image_lines.append(f"{repository}@{digest}")
            inventory_lines.append(f"{name}\t{repository}\t{digest}\tapproved")
        overlay = build_values_overlay(
            self.build_fixture(
                image_lines,
                inventory_lines,
                values_overlay_profile="gcp",
            )
        )
        self.assertEqual(
            overlay.count("__IMAGE_MIRROR_ROOT__/ghcr.io/example/relaycast"), 2
        )
        self.assertIn("# customer registry mirror root. Profile: gcp.", overlay)

    def test_rejects_unknown_values_overlay_profile(self):
        with self.assertRaisesRegex(ValueError, "must be gcp or eks"):
            self.build_fixture(
                [f"ghcr.io/example/service@{DIGEST_A}"],
                [f"service\tghcr.io/example/service\t{DIGEST_A}\tapproved"],
                values_overlay_profile="other",
            )

    def test_main_does_not_write_partial_manifest_when_overlay_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            images = root / "images.txt"
            inventory = root / "inventory.tsv"
            output = root / "release-manifest.json"
            overlay = root / "release-images.values.yaml"
            images.write_text(
                f"ghcr.io/example/service@{DIGEST_A}\n", encoding="utf-8"
            )
            inventory.write_text(
                f"service\tghcr.io/example/service\t{DIGEST_A}\tapproved\n",
                encoding="utf-8",
            )
            argv = [
                "build-agent-relay-release-manifest.py",
                "--version",
                "2026.11.0",
                "--infra-commit",
                COMMIT,
                "--chart-path",
                "charts/agent-relay",
                "--chart-version",
                "0.6.36",
                "--values-overlay-profile",
                "eks",
                "--images",
                str(images),
                "--inventory",
                str(inventory),
                "--output",
                str(output),
                "--values-overlay-output",
                str(overlay),
            ]
            with mock.patch.object(sys, "argv", argv):
                self.assertEqual(MODULE.main(), 1)
            self.assertFalse(output.exists())
            self.assertFalse(overlay.exists())


if __name__ == "__main__":
    unittest.main()
