"""Qualified frontend transport bindings; no Docker, node import or HTTP."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from native_inspect import sha
from native_recipe import NativeRecipeError
from native_webapp import coordinates


class Webapp(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup); self.root = Path(self.temp.name)
        self.reference = "agent-relay-kind/relay-webapp@sha256:" + "c" * 64
        self.config = {"architecture": "arm64", "os": "linux", "config": {"User": "101"},
                       "rootfs": {"type": "layers", "diff_ids": ["sha256:" + "f" * 64]}}
        self.runtime = {"tag": "agent-relay-kind/relay-webapp:fixture", "nativeManifestDigest": "sha256:" + "c" * 64,
                        "configDigest": "sha256:" + "d" * 64, "archiveSha256": "e" * 64, "runtimeConfig": {"User": "101"}}
        self.metadata = {"containerimage.digest": "sha256:" + "9" * 64,
                         "containerimage.descriptor": {"digest": "sha256:" + "9" * 64}}
        self.docs = {
            "build-metadata.json": self.metadata,
            "build-receipt.json": {"sourceRevision": "a" * 40, "sourceTree": "b" * 40, "images": {"runtime": self.runtime}},
            "base-chain-receipt.json": {"runtime": {"candidateNativeManifest": self.runtime["nativeManifestDigest"],
                "candidateConfigDigest": self.runtime["configDigest"], "allLayerBlobAndDiffIdsVerified": True,
                "exactBasePrefix": True}},
            "compiled-bundle-manifest.json": {"sourceStageExact": True, "runtimeExactExceptBase50x": True,
                "capabilitiesEndpoint": "/cloud/api/v1/capabilities", "oldLicenseEndpointAbsent": True,
                "files": {"assets/app.js": "1" * 64, "index.html": "2" * 64}},
            "runtime-smoke-receipt.json": {"result": "PASS_UID101_NETWORK_NONE_STATIC_AND_RUNTIME_CONFIG",
                "uid": 101, "network": "none", "healthz": 200}}
        self.packet = {"result": "PASS_PUBLIC_WEBAPP_OFFICIAL_NATIVE_SOURCE_AND_STATIC_RUNTIME",
            "sourceRevision": "a" * 40, "sourceTree": "b" * 40, "sourceRepository": "https://github.com/AgentWorkforce/relay-webapp",
            "architecture": "arm64", "officialDockerfileUnmodified": True, "capabilitiesApi": "/cloud/api/v1/capabilities",
            "requiresCapabilitiesControlAbi": True, "reference": self.reference,
            "manifestDigest": self.runtime["nativeManifestDigest"], "configDigest": self.runtime["configDigest"], "archiveSha256": "e" * 64}

    def save(self):
        def write(name, value):
            p = self.root / name; p.write_text(json.dumps(value)); return sha(p)
        metadata_sha = write("build-metadata.json", self.metadata)
        self.docs["base-chain-receipt.json"]["runtime"]["metadataSha256"] = metadata_sha
        self.packet["receipts"] = {n: write(n, d) for n, d in self.docs.items() if n != "build-metadata.json"}
        digest = write("qualification-packet.json", self.packet)
        return {"webappPacket": self.root / "qualification-packet.json", "webappPacketSha256": digest,
                "webappArchive": self.root / "native.tar", "webappBuildMetadata": self.root / "build-metadata.json"}

    def test_reads_original_receipts_and_uses_actual_build_index_separate_from_native_and_config(self):
        inputs = self.save(); original = {p.name: p.read_bytes() for p in self.root.iterdir()}
        with patch("native_inspect.native_archive", return_value=self.config) as archive:
            value = coordinates(inputs, "arm64")
        self.assertEqual(value["indexDigest"], self.metadata["containerimage.digest"])
        self.assertNotEqual(value["indexDigest"], value["manifestDigest"])
        self.assertNotEqual(value["indexDigest"], value["configDigest"])
        self.assertEqual(archive.call_args.args[1], "e" * 64)
        self.assertEqual(original, {p.name: p.read_bytes() for p in self.root.iterdir()})

    def test_changed_unbound_metadata_or_packet_refuses_before_archive_read(self):
        inputs = self.save(); (self.root / "build-metadata.json").write_text("{}")
        with patch("native_inspect.native_archive") as archive:
            with self.assertRaisesRegex(NativeRecipeError, "evidence_bytes_changed"): coordinates(inputs, "arm64")
            archive.assert_not_called()
        inputs = self.save(); inputs["webappPacketSha256"] = "0" * 64
        with self.assertRaises(NativeRecipeError): coordinates(inputs, "arm64")

    def test_wrong_abi_architecture_source_base_or_unprivileged_identity_refuses(self):
        for case in ("old-abi", "wrong-arch", "other-source", "different-base", "root-user"):
            original_packet, original_docs = deepcopy(self.packet), deepcopy(self.docs)
            if case == "old-abi": self.packet["capabilitiesApi"] = "/cloud/api/v1/license"
            if case == "wrong-arch": self.packet["architecture"] = "amd64"
            if case == "other-source": self.docs["build-receipt.json"]["sourceRevision"] = "0" * 40
            if case == "different-base": self.docs["base-chain-receipt.json"]["runtime"]["exactBasePrefix"] = False
            config = deepcopy(self.config)
            if case == "root-user": config["config"]["User"] = "0"
            with patch("native_inspect.native_archive", return_value=config):
                with self.subTest(case=case), self.assertRaises(NativeRecipeError): coordinates(self.save(), "arm64")
            self.packet, self.docs = original_packet, original_docs

    def test_static_file_hash_input_cannot_inject_shell_or_escape_served_directory(self):
        for name in ("../secret", "/root/file", "index.html\nnext", "$(unsafe).js"):
            self.docs["compiled-bundle-manifest.json"]["files"] = {name: "a" * 64}
            with patch("native_inspect.native_archive", return_value=self.config):
                with self.subTest(name=name), self.assertRaisesRegex(NativeRecipeError, "static_manifest"):
                    coordinates(self.save(), "arm64")


if __name__ == "__main__": unittest.main()
