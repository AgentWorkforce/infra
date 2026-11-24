#!/usr/bin/env python3
"""A first-party image pinned by digest in a chart must reach the release
manifest and the customer mirror list, even when the profile used to render
the release leaves its component off (the manifest images come from that
render plus an explicit id list in release-agent-relay.yml)."""

import pathlib
import re
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/release-agent-relay.yml"
INVENTORY = ROOT / "self-hosted/customer-images.yaml"
MIRROR_DOC = ROOT / "docs/gcp-install/images.md"

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


if __name__ == "__main__":
    unittest.main()
