#!/usr/bin/env python3
"""A first-party image pinned by digest in a chart must reach the release
manifest and the customer mirror list, even when the profile used to render
the release leaves its component off (the manifest images come from that
render plus an explicit id list in release-agent-relay.yml)."""

import importlib.util
import pathlib
import re
import sys
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/release-agent-relay.yml"
INVENTORY = ROOT / "self-hosted/customer-images.yaml"
MIRROR_DOC = ROOT / "docs/gcp-install/images.md"

sys.dont_write_bytecode = True
_SPEC = importlib.util.spec_from_file_location(
    "release_manifest",
    ROOT / "scripts/release/build-agent-relay-release-manifest.py",
)
assert _SPEC and _SPEC.loader
_BUILDER = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_BUILDER)
APPROVED_IMAGE_STATUSES = _BUILDER.APPROVED_IMAGE_STATUSES

# image id -> chart values file whose image.repository/digest is the pin
OPTIONAL_PINNED = {"relaygate": ROOT / "charts/relaygate/values.yaml"}


def explicit_release_ids() -> set[str]:
    text = WORKFLOW.read_text(encoding="utf-8")
    match = re.search(
        r"select\(\.id == \"relaycast-eks-collector\"[^']*\)\s*\| \.current", text
    )
    if not match:
        raise AssertionError("explicit image id select not found in release workflow")
    return set(re.findall(r'\.id == "([a-z0-9-]+)"', match.group(0)))


class ReleaseImagesCoverPins(unittest.TestCase):
    def test_optional_pinned_images_are_in_manifest_and_mirror_list(self):
        inventory = {
            image["id"]: image
            for image in yaml.safe_load(INVENTORY.read_text(encoding="utf-8"))["images"]
        }
        ids = explicit_release_ids()
        doc = MIRROR_DOC.read_text(encoding="utf-8")
        for name, values_file in OPTIONAL_PINNED.items():
            pin = yaml.safe_load(values_file.read_text(encoding="utf-8"))["image"]
            ref = f"{pin['repository']}@{pin['digest']}"
            with self.subTest(image=name):
                self.assertIn(name, ids, f"{name} is pinned in the chart but the release manifest never lists it")
                current = inventory[name]["current"]
                self.assertEqual(
                    f"{current['repository']}@{current['digest']}",
                    ref,
                    "self-hosted/customer-images.yaml differs from the chart pin",
                )
                self.assertIn(ref, doc, f"{name} pin missing from docs/gcp-install/images.md")

    def test_every_explicitly_listed_image_is_approved(self):
        """The manifest builder refuses unapproved images after the release
        tag is pushed, so the id list and the approval must move together."""
        inventory = {
            image["id"]: image
            for image in yaml.safe_load(INVENTORY.read_text(encoding="utf-8"))["images"]
        }
        for name in sorted(explicit_release_ids()):
            with self.subTest(image=name):
                self.assertIn(name, inventory, f"{name} is not in customer-images.yaml")
                approval = inventory[name]["approval"]
                self.assertIn(
                    approval["status"],
                    APPROVED_IMAGE_STATUSES,
                    f"{name} is listed for the release manifest but its approval "
                    f"status is {approval['status']!r}; the manifest build would fail",
                )
                self.assertEqual(
                    approval.get("blockingReasons"), [], f"{name} has blocking reasons"
                )


if __name__ == "__main__":
    unittest.main()
