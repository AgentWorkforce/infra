"""Native control image admission tests; no Docker or cluster contacted."""
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import control
from stack import tenant_values


class ControlArchive(unittest.TestCase):
    def archive(self, path, *, arch="arm64", revision=control.REVISION, corrupt=False,
                include_platform=True, descriptor_arch=None, image_os="linux"):
        config = json.dumps({"architecture": arch, "os": image_os, "config": {"Labels": {
            "org.opencontainers.image.revision": revision}}}).encode()
        config_hash = hashlib.sha256(config).hexdigest()
        manifest = json.dumps({"config": {"digest": "sha256:" + config_hash}}).encode()
        digest = hashlib.sha256(manifest).hexdigest()
        descriptor = {"digest": "sha256:" + digest}
        if include_platform:
            descriptor["platform"] = {"architecture": descriptor_arch or arch, "os": "linux"}
        index = json.dumps({"manifests": [descriptor]}).encode()
        with tarfile.open(path, "w") as archive:
            for name, data in [("index.json", index), ("blobs/sha256/" + digest, manifest),
                               ("blobs/sha256/" + config_hash, config + (b" " if corrupt else b""))]:
                item = tarfile.TarInfo(name); item.size = len(data)
                archive.addfile(item, io.BytesIO(data))
        return "sha256:" + digest

    def test_bootstrap_preserves_selected_image_and_other_profile_settings(self):
        image = {"repository": control.REPOSITORY, "digest": "sha256:" + "a" * 64, "pullPolicy": "Never"}
        values = {"relay-control": {"image": image}, "global": {"otel": {"endpoint": ""}},
                  "sessions-pipeline": {"worker": {"tenant": {"orgId": "keep"}, "podAnnotations": {"keep": "yes"}}},
                  "relayflows": {"nodeSelector": {"keep": "yes"}}}
        result = tenant_values(values, {"orgId": "real-org", "workspaceId": "real-workspace"}, "addons", "arm64", "recipe")
        self.assertEqual(result["relay-control"]["image"], image)
        self.assertEqual(result["global"]["otel"], {"endpoint": ""})
        self.assertEqual(result["global"]["tenant"]["orgId"], "real-org")
        self.assertEqual(result["sessions-pipeline"]["worker"]["tenant"], {"orgId": "real-org", "workspaceId": "real-workspace"})
        self.assertEqual(result["sessions-pipeline"]["worker"]["podAnnotations"]["keep"], "yes")
        self.assertEqual(result["sessions-pipeline"]["alleyoop"]["tenant"]["orgId"], "real-org")
        self.assertEqual(result["relayflows"]["nodeSelector"], {"keep": "yes", "kubernetes.io/arch": "arm64"})

    def test_valid_native_manifest_is_pinned_by_content_not_config_or_tag(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.tar"
            digest = self.archive(path)
            receipt = control.inspect_archive(path, "arm64")
            self.assertEqual(receipt["reference"], control.REPOSITORY + "@" + digest)
            self.assertNotEqual(receipt["manifestDigest"], receipt["configDigest"])

    def test_corrupt_metadata_wrong_architecture_or_source_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.tar"
            for options in ({"corrupt": True}, {"arch": "amd64"}, {"revision": "other"}):
                with self.subTest(options=options):
                    self.archive(path, **options)
                    with self.assertRaises(ValueError):
                        control.inspect_archive(path, "arm64")

    def test_native_config_is_required_when_optional_descriptor_platform_is_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.tar"
            digest = self.archive(path, include_platform=False)
            receipt = control.inspect_archive(path, "arm64")
            self.assertEqual(receipt["manifestDigest"], digest)
            self.assertEqual(receipt["architecture"], "arm64")
            self.assertEqual(receipt["sourceRevision"], control.REVISION)
            for options in ({"arch": "amd64"}, {"image_os": "windows"},
                            {"revision": "other"}, {"corrupt": True}):
                with self.subTest(options=options):
                    self.archive(path, include_platform=False, **options)
                    with self.assertRaises(ValueError):
                        control.inspect_archive(path, "arm64")

    def test_conflicting_present_platform_is_refused_despite_native_config(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.tar"
            self.archive(path, arch="arm64", descriptor_arch="amd64")
            with self.assertRaises(ValueError):
                control.inspect_archive(path, "arm64")


if __name__ == "__main__":
    unittest.main()
