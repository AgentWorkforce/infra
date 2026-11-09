"""Real OCI bytes, modeled Docker inspect only; no daemon, load or cluster."""
from copy import deepcopy
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

from native_inspect import attest_cached_image, native_archive_transport
from native_recipe import NativeRecipeError


class ArchiveTransport(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "native.tar"
        self.source = "a" * 40
        self.index = "sha256:" + "9" * 64
        config = {"architecture": "arm64", "os": "linux", "rootfs": {"type": "layers", "diff_ids": []},
                  "config": {"User": "1000", "Env": ["MODE=qualified"], "Cmd": ["owned-command"],
                             "Entrypoint": None, "WorkingDir": "/app",
                             "Labels": {"org.opencontainers.image.revision": self.source}}}
        raw = json.dumps(config).encode(); self.config = "sha256:" + hashlib.sha256(raw).hexdigest()
        manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                               "config": {"digest": self.config}, "layers": []}).encode()
        self.manifest = "sha256:" + hashlib.sha256(manifest).hexdigest()
        self.files = {"index.json": json.dumps({"manifests": [{"digest": self.manifest,
            "mediaType": "application/vnd.oci.image.manifest.v1+json"}]}).encode(),
            "blobs/sha256/" + self.manifest[7:]: manifest, "blobs/sha256/" + self.config[7:]: raw}
        with tarfile.open(self.path, "w") as archive:
            for name, data in self.files.items():
                info = tarfile.TarInfo(name); info.size = len(data); archive.addfile(info, io.BytesIO(data))
        self.sha = hashlib.sha256(self.path.read_bytes()).hexdigest()
        self.transport = native_archive_transport(self.path, self.sha, self.source, self.manifest, self.config, "arm64")
        self.image = {"Id": self.manifest, "Descriptor": {"digest": self.manifest,
            "mediaType": "application/vnd.oci.image.manifest.v1+json"}, "Architecture": "arm64", "Os": "linux",
            "Config": deepcopy(config["config"]), "RootFS": {"Layers": []}, "RepoTags": ["owned:qualified"]}

    def admit(self, image=None, transport=True):
        return attest_cached_image(self.image if image is None else image, self.source, "arm64", self.index, self.config,
                                   archive_native=self.transport if transport else None)

    def test_native_only_archive_passes_without_fabricating_the_original_build_index(self):
        self.assertNotIn("blobs/sha256/" + self.index[7:], self.files)
        self.assertNotEqual(self.manifest, self.index); self.assertNotEqual(self.config, self.index)
        with self.assertRaisesRegex(NativeRecipeError, "immutable_transport"): self.admit(transport=False)
        self.assertEqual(self.admit(), "archive-native")
        original = deepcopy(self.image); original["Id"] = self.index
        original["Descriptor"] = {"digest": self.index, "mediaType": "application/vnd.oci.image.index.v1+json"}
        self.assertEqual(self.admit(original), "build-index")
        for image in (original, self.image):
            image = deepcopy(image); image["Id"] = self.config
            self.assertIn(self.admit(image), {"build-index", "archive-native"})

    def test_mutable_tag_name_and_mixed_or_unknown_digests_and_descriptor_types_never_suffice(self):
        for change in [lambda x: x.update(Id="sha256:" + "8" * 64),
                       lambda x: x.update(Id=self.index),
                       lambda x: x["Descriptor"].update(digest=self.config),
                       lambda x: x["Descriptor"].update(digest="sha256:" + "7" * 64),
                       lambda x: x["Descriptor"].update(mediaType="application/vnd.oci.image.index.v1+json"),
                       lambda x: x["Descriptor"].update(mediaType="unknown"),
                       lambda x: x.pop("Descriptor")]:
            image = deepcopy(self.image); change(image)
            with self.subTest(image=image), self.assertRaises(NativeRecipeError): self.admit(image)
        image = deepcopy(self.image); image["Descriptor"] = {"digest": self.index, "mediaType": "application/vnd.oci.image.index.v1+json"}
        with self.assertRaises(NativeRecipeError): self.admit(image)

    def test_native_config_source_architecture_and_rootfs_remain_hard_bindings(self):
        for change in [lambda x: x.update(Architecture="amd64"), lambda x: x.update(Os="windows"),
                       lambda x: x["RootFS"].update(Layers=["sha256:" + "6" * 64]),
                       lambda x: x["Config"].update(User="0"), lambda x: x["Config"].update(Cmd=["unqualified"]),
                       lambda x: x["Config"].update(Env=["MODE=unqualified"]),
                       lambda x: x["Config"]["Labels"].update({"org.opencontainers.image.revision": "b" * 40})]:
            image = deepcopy(self.image); change(image)
            with self.subTest(image=image), self.assertRaises(NativeRecipeError): self.admit(image)

    def test_transport_record_requires_its_exact_source_architecture_config_and_digest_shape(self):
        for field, value in [("kind", "unverified-tag"), ("sourceRevision", "b" * 40),
                             ("architecture", "amd64"), ("configDigest", "sha256:" + "8" * 64),
                             ("manifestDigest", "not-a-digest"), ("manifestDigest", "sha256:" + "8" * 64), ("archiveSha256", "not-a-digest")]:
            transport = deepcopy(self.transport); transport[field] = value
            with self.subTest(field=field), self.assertRaises(NativeRecipeError):
                attest_cached_image(self.image, self.source, "arm64", self.index, self.config, archive_native=transport)

    def test_changed_archive_or_wrong_native_config_source_and_arch_refuses_before_transport_record(self):
        original = self.path.read_bytes(); self.path.write_bytes(original + b"mutation")
        with self.assertRaisesRegex(NativeRecipeError, "archive_bytes"):
            native_archive_transport(self.path, self.sha, self.source, self.manifest, self.config, "arm64")
        self.path.write_bytes(original)
        # Even a caller rebinding the outer tar hash cannot hide a changed
        # config blob beneath the original expected native/config identities.
        tampered = dict(self.files)
        key = "blobs/sha256/" + self.config[7:]
        tampered[key] = tampered[key].replace(b"1000", b"root")
        with tarfile.open(self.path, "w") as archive:
            for name, data in tampered.items():
                item = tarfile.TarInfo(name); item.size = len(data); archive.addfile(item, io.BytesIO(data))
        changed_outer = hashlib.sha256(self.path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(NativeRecipeError, "oci_blob_bytes_changed"):
            native_archive_transport(self.path, changed_outer, self.source, self.manifest, self.config, "arm64")
        self.path.write_bytes(original)
        for source, manifest, config, arch in [("b" * 40, self.manifest, self.config, "arm64"),
                (self.source, "sha256:" + "8" * 64, self.config, "arm64"),
                (self.source, self.manifest, "sha256:" + "8" * 64, "arm64"),
                (self.source, self.manifest, self.config, "amd64")]:
            with self.subTest(source=source, manifest=manifest, config=config, arch=arch), self.assertRaises(NativeRecipeError):
                native_archive_transport(self.path, self.sha, source, manifest, config, arch)


if __name__ == "__main__": unittest.main()
