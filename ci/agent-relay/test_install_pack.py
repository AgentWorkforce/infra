import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import pathlib
import sys
import tarfile
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "install_pack", ROOT / "scripts/release/build-agent-relay-install-pack.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class InstallPackTest(unittest.TestCase):
    def fixture(self, root):
        pins = root / "pins.json"
        pins.write_text('{"schema":1,"version":"2026.11.1","pins":{}}\n')
        pin_sha = hashlib.sha256(pins.read_bytes()).hexdigest()
        manifest = root / "manifest.json"
        manifest.write_text(
            json.dumps(
                {
                    "schema": 1,
                    "version": "2026.11.1",
                    "candidatePins": {
                        "path": "candidate-pins.json",
                        "sha256": pin_sha,
                    },
                }
            )
            + "\n"
        )
        paths = {}
        for name in ("base", "platform", "images"):
            path = root / f"{name}.yaml"
            path.write_text(f"{name}: true\n")
            paths[name] = path
        return argparse.Namespace(
            version="2026.11.1",
            base_values=paths["base"],
            platform_overlay=paths["platform"],
            image_overlay=paths["images"],
            manifest=manifest,
            candidate_pins=pins,
            output=root / "pack.tar.gz",
        )

    def members(self, output):
        with gzip.open(output, "rb") as stream:
            data = stream.read()
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
            return {member.name: archive.extractfile(member).read() for member in archive}

    def test_pack_is_deterministic_and_checksums_exact_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self.fixture(pathlib.Path(directory))
            MODULE.build(args)
            first = args.output.read_bytes()
            MODULE.build(args)
            self.assertEqual(args.output.read_bytes(), first)
            members = self.members(args.output)
            self.assertEqual(
                sorted(members),
                [
                    "SHA256SUMS",
                    "candidate-pins.json",
                    "overlay.yaml",
                    "release-images.values.yaml",
                    "release-manifest.json",
                    "values.yaml",
                ],
            )
            lines = members["SHA256SUMS"].decode().splitlines()
            self.assertEqual(len(lines), 5)
            for line in lines:
                digest, name = line.split("  ", 1)
                self.assertEqual(hashlib.sha256(members[name]).hexdigest(), digest)

    def test_version_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self.fixture(pathlib.Path(directory))
            args.version = "2026.11.2"
            with self.assertRaisesRegex(ValueError, "version does not match"):
                MODULE.build(args)

    def test_symlink_input_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            args = self.fixture(root)
            link = root / "linked-values.yaml"
            link.symlink_to(args.base_values)
            args.base_values = link
            with self.assertRaisesRegex(ValueError, "regular file"):
                MODULE.build(args)


if __name__ == "__main__":
    unittest.main()
