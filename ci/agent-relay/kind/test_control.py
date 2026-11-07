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


class ControlArchive(unittest.TestCase):
    def archive(self, path, *, arch="arm64", revision=control.REVISION, corrupt=False):
        config = json.dumps({"architecture": arch, "os": "linux", "config": {"Labels": {
            "org.opencontainers.image.revision": revision}}}).encode()
        config_hash = hashlib.sha256(config).hexdigest()
        manifest = json.dumps({"config": {"digest": "sha256:" + config_hash}}).encode()
        digest = hashlib.sha256(manifest).hexdigest()
        index = json.dumps({"manifests": [{"digest": "sha256:" + digest,
                            "platform": {"architecture": arch, "os": "linux"}}]}).encode()
        with tarfile.open(path, "w") as archive:
            for name, data in [("index.json", index), ("blobs/sha256/" + digest, manifest),
                               ("blobs/sha256/" + config_hash, config + (b" " if corrupt else b""))]:
                item = tarfile.TarInfo(name); item.size = len(data)
                archive.addfile(item, io.BytesIO(data))
        return "sha256:" + digest

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


if __name__ == "__main__":
    unittest.main()
