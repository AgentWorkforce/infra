"""Synthetic receipt/OCI/source controls; no Docker, SQL, credential or API IO."""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from native_control_artifact import RAW_FIELDS, RAW_RECEIPTS, RAW_RESULT, coordinates
from native_control import NativeControlTransport
from native_recipe import NativeRecipeError


def digest(raw): return hashlib.sha256(raw).hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True) + "\n")
    return digest(path.read_bytes())


def write_tar(path, files, modes=None):
    with tarfile.open(path, "w") as archive:
        for name, raw in files.items():
            item = tarfile.TarInfo(name); item.size = len(raw); item.mode = (modes or {}).get(name, 0o644)
            archive.addfile(item, io.BytesIO(raw))


class RawControl(unittest.TestCase):
    def fixture(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup); root = Path(tmp.name)
        source, tree = "a" * 40, "b" * 40
        sql = {f"{n:04d}_test.sql": (f"-- synthetic source fixture {n}\nSELECT 1;\n").encode() for n in range(1, 25)}
        files = {"Dockerfile": b"FROM scratch\n", "src/migrations.ts": b'const MIGRATION_LEDGER = "control_schema_migrations";\n',
                 **{"migrations/" + n: raw for n, raw in sql.items()}}
        src = root / "source.tar"; write_tar(src, files)
        dist = {"features.js": digest(b"export const NO_FEATURES = {};\n")}
        layer = b"synthetic-layer-bytes-not-an-executed-image"
        config = {"architecture": "arm64", "os": "linux", "rootfs": {"type": "layers", "diff_ids": ["sha256:" + digest(layer)]},
                  "config": {"Labels": {"org.opencontainers.image.revision": source}, "User": "node"}}
        config_raw = json.dumps(config).encode(); cd = "sha256:" + digest(config_raw)
        manifest_raw = json.dumps({"schemaVersion": 2, "config": {"digest": cd},
                                   "layers": [{"digest": "sha256:" + digest(layer)}]}).encode(); md = "sha256:" + digest(manifest_raw)
        native = root / "native.tar"
        write_tar(native, {"index.json": json.dumps({"manifests": [{"digest": md}]}).encode(),
                           "blobs/sha256/" + md[7:]: manifest_raw, "blobs/sha256/" + cd[7:]: config_raw,
                           "blobs/sha256/" + digest(layer): layer})
        tag, index = "agent-relay-kind/selfhost-api:synthetic", "sha256:" + "9" * 64
        reference = "agent-relay-kind/selfhost-api@" + md
        sha_files = {n: digest(raw) for n, raw in files.items()}; sql_hashes = {n: digest(raw) for n, raw in sql.items()}
        common = {"sourceRevision": source, "sourceTree": tree}
        source_doc = {**common, "sourceArchiveSha256": digest(src.read_bytes()), "files": sha_files,
                      "modes": {name: 0o644 for name in sha_files},
                      "sqlCount": len(sql), "officialDockerfileSha256": sha_files["Dockerfile"]}
        equality = {"result": "PASS_FRESH_OFFICIAL_COMPILATION_PACKAGE_SQL_AND_LOCK_BOUND_DEPENDENCIES",
                    "dist": dist, "migrations": sql_hashes, "compiledDistFiles": len(dist), "sqlFiles": len(sql),
                    "unexpectedRuntimeDependencyVersionsOrIntegrity": [], "runtimeDependenciesMatchingBuildLock": 1,
                    "runtimePackageFilesMatchFreshBuild": True, "runtimeSourceLockByteIdentical": True, "actualInstalledLockUsed": True}
        runtime = {"tag": tag, "nativeManifestDigest": md, "configDigest": cd, "archiveSha256": digest(native.read_bytes()),
                   "runtimeConfig": config["config"]}
        build = {**common, "sourceArchiveSha256": source_doc["sourceArchiveSha256"], "officialDockerfileUnmodified": True,
                 "officialDockerfileSha256": sha_files["Dockerfile"], "images": {"runtime": runtime}}
        docs = {"source-manifest.json": source_doc, "source-runtime-equality.json": equality,
                "migration-source-comparison.json": {**common, "sql": sql_hashes}, "build-receipt.json": build,
                "build-metadata.json": {"containerimage.digest": index, "containerimage.descriptor": {
                    "digest": index, "mediaType": "application/vnd.oci.image.index.v1+json"}},
                "compiled-config-probe.json": {"result": "PASS_COMPILED_CORE_CAPABILITIES_AND_NATIVE_DIRECT_CONFIG",
                    "coreCapabilities": {"flows": False, "relayfile": False, "chief": False}, "networkCalls": 0,
                    **{k: True for k in ("capabilitiesEndpoint", "licenseModuleAbsent", "directOptIn", "nativeSingleOrigin", "nativeRefusesLegacyDirectOverride")}}}
        for name, value in docs.items(): write_json(root / name, value)
        base = {"candidateNativeManifest": md, "candidateConfigDigest": cd, "allLayerBlobAndDiffIdsVerified": True,
                "exactBasePrefix": True, "metadataSha256": digest((root / "build-metadata.json").read_bytes())}
        write_json(root / "native-base-chain.json", {"runtime": base})
        artifact = {**common, "manifestDigest": md, "configDigest": cd, "localTag": tag, "reference": reference,
                    "architecture": "arm64", "archiveSha256": runtime["archiveSha256"], "sqlCount": len(sql),
                    "officialDockerfileUnmodified": True,
                    "receipts": {"source-manifest.json": digest((root / "source-manifest.json").read_bytes())}}
        write_json(root / "artifact-receipt.json", artifact)
        for name in RAW_RECEIPTS:
            if not (root / name).exists(): write_json(root / name, {"syntheticNonexecutedFixture": True})
        packet = dict.fromkeys(RAW_FIELDS)
        packet.update(result=RAW_RESULT, **common, reference=reference, manifestDigest=md, configDigest=cd, dockerIndexDigest=index,
            sourceMergedAs="c" * 40, publicPr="https://github.com/AgentWorkforce/relay-control/pull/1",
            createdUtc="2026-01-01T00:00:00Z", limits=["synthetic source test only"], priorFailuresPreserved=[],
            localTag=tag, architecture="linux/arm64", archive="native.tar", archiveSha256=runtime["archiveSha256"],
            officialDockerfileUnmodifiedFromSelectedSource=True, sourceProductionLockActualRuntimeDependencies=1,
            compiledOutputFiles=len(dist), sqlFiles=len(sql), previous23SqlBytesUnchanged=True,
            freshSqlApplied=len(sql), upgradeSqlApplied=len(sql)-23, repeatApplied=0,
            actualOfficialMigrateAndServerModulesExercised=True, runtimeIdentityAndNoDdlNoLedgerPrivileges=True,
            genuineSyntheticDeviceTokenAndDataPreservedOnUpgrade=True, capabilitiesEndpoint="/cloud/api/v1/capabilities",
            capabilities={"flows": False, "relayfile": False, "chief": False},
            readContractModes=["legacy-direct-opt-in with original sh_at_", "native-issuer with independent rth read handoff"],
            receipts={name: digest((root / name).read_bytes()) for name in RAW_RECEIPTS})
        receipt = root / "qualification-packet.json"
        selected = {k: packet[k] for k in ("sourceRevision", "manifestDigest", "configDigest", "reference")}
        selected["artifactReceiptSha256"] = write_json(receipt, packet)
        paths = {"controlReceipt": receipt, "controlArchive": native, "controlSourceArchive": src,
                 "controlSourceManifest": root / "source-manifest.json", "controlDistManifest": root / "source-runtime-equality.json",
                 "controlMigrationManifest": root / "migration-source-comparison.json",
                 "controlMigrationManifestSha256": packet["receipts"]["migration-source-comparison.json"]}
        return root, paths, selected, packet

    def save(self, paths, selected, packet):
        selected["artifactReceiptSha256"] = write_json(paths["controlReceipt"], packet)

    def rewrite_source_modes(self, root, paths, selected, packet, modes):
        with tarfile.open(paths["controlSourceArchive"]) as archive:
            files = {m.name: archive.extractfile(m).read() for m in archive}
        write_tar(paths["controlSourceArchive"], files, modes)
        source = json.loads(paths["controlSourceManifest"].read_text())
        source["sourceArchiveSha256"] = digest(paths["controlSourceArchive"].read_bytes())
        build_path = root / "build-receipt.json"; build = json.loads(build_path.read_text())
        build["sourceArchiveSha256"] = source["sourceArchiveSha256"]
        packet["receipts"]["build-receipt.json"] = write_json(build_path, build)
        packet["receipts"]["source-manifest.json"] = write_json(paths["controlSourceManifest"], source)
        artifact_path = root / "artifact-receipt.json"; artifact = json.loads(artifact_path.read_text())
        artifact["receipts"]["source-manifest.json"] = packet["receipts"]["source-manifest.json"]
        packet["receipts"]["artifact-receipt.json"] = write_json(artifact_path, artifact)
        self.save(paths, selected, packet)
        return files

    def test_raw_packet_archive_and_all_maps_are_read_without_rewriting_proof(self):
        root, paths, selected, packet = self.fixture()
        before = {p: p.read_bytes() for p in root.rglob("*") if p.is_file()}
        result = coordinates(paths, selected, "arm64")
        self.assertTrue(result["rawV2"])
        self.assertEqual(result["tag"], packet["localTag"])
        self.assertNotEqual(result["dockerIndexDigest"], result["manifestDigest"])
        self.assertEqual(result["migration"]["ledger"], "control_schema_migrations")
        self.assertEqual(result["migration"]["migrationCount"], 24)
        self.assertEqual(set(result["dist"]), {"dist/features.js"})
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_only_frozen_0664_to_0644_chmod_normalization_can_change_an_archive_mode(self):
        root, paths, selected, packet = self.fixture()
        source = json.loads(paths["controlSourceManifest"].read_text())
        files = self.rewrite_source_modes(root, paths, selected, packet, {n: 0o664 for n in source["files"]})
        result = coordinates(paths, selected, "arm64")
        self.assertEqual(result["sourceModeBinding"], {"contract": "verified-bytes-then-explicit-manifest-chmod-v1",
            "normalized0664To0644Files": len(files), "exactModeFiles": 0})
        for mode in (0o600, 0o666, 0o755, 0o777, 0o4644):
            root, paths, selected, packet = self.fixture()
            self.rewrite_source_modes(root, paths, selected, packet, {"src/migrations.ts": mode})
            with self.subTest(mode=mode), self.assertRaisesRegex(NativeRecipeError, "archive_mode_changed"):
                coordinates(paths, selected, "arm64")

    def test_every_child_hash_and_missing_packet_field_refuses(self):
        for case in ("child", "missing-child", "missing-field", "wrong-type", "missing-source"):
            root, paths, selected, packet = self.fixture()
            if case == "child": (root / "owned-pg17/prove.py").write_text("changed")
            elif case == "missing-child": packet["receipts"].pop("build-stage-metadata.json")
            elif case == "missing-field": packet.pop("dockerIndexDigest")
            elif case == "wrong-type": packet["capabilities"]["flows"] = 0
            else: paths.pop("controlSourceArchive")
            self.save(paths, selected, packet)
            with self.subTest(case=case), self.assertRaises(NativeRecipeError): coordinates(paths, selected, "arm64")

    def test_native_index_architecture_and_selected_sql_hash_cannot_be_interchanged(self):
        for case in ("index", "native", "config", "architecture", "sql-hash"):
            root, paths, selected, packet = self.fixture()
            if case == "index": packet["dockerIndexDigest"] = packet["manifestDigest"]
            elif case == "native": packet["manifestDigest"] = packet["dockerIndexDigest"]
            elif case == "config": packet["configDigest"] = packet["manifestDigest"]
            elif case == "architecture": packet["architecture"] = "linux/amd64"
            else: paths["controlMigrationManifestSha256"] = "0" * 64
            self.save(paths, selected, packet)
            with self.subTest(case=case), self.assertRaises(NativeRecipeError): coordinates(paths, selected, "arm64")

    def test_changed_source_sql_and_native_archive_are_refused(self):
        for path in ("controlSourceArchive", "controlArchive", "controlSourceManifest", "controlDistManifest", "controlMigrationManifest"):
            root, paths, selected, packet = self.fixture()
            with Path(paths[path]).open("ab") as stream: stream.write(b"changed")
            with self.subTest(path=path), self.assertRaises(NativeRecipeError): coordinates(paths, selected, "arm64")

    def test_coherently_bound_source_map_cannot_select_another_ledger_or_escape_path(self):
        for case in ("unknown-ledger", "source-bytes", "path", "sql-map"):
            root, paths, selected, packet = self.fixture()
            if case in ("unknown-ledger", "source-bytes"):
                with tarfile.open(paths["controlSourceArchive"]) as archive:
                    files = {m.name: archive.extractfile(m).read() for m in archive}
                files["src/migrations.ts"] = b'const MIGRATION_LEDGER = "foreign_ledger";\n'
                write_tar(paths["controlSourceArchive"], files)
                source = json.loads(paths["controlSourceManifest"].read_text())
                source["sourceArchiveSha256"] = digest(paths["controlSourceArchive"].read_bytes())
                if case == "unknown-ledger": source["files"]["src/migrations.ts"] = digest(files["src/migrations.ts"])
                build_path = root / "build-receipt.json"; build = json.loads(build_path.read_text())
                build["sourceArchiveSha256"] = source["sourceArchiveSha256"]
                packet["receipts"]["build-receipt.json"] = write_json(build_path, build)
                packet["receipts"]["source-manifest.json"] = write_json(paths["controlSourceManifest"], source)
                artifact_path = root / "artifact-receipt.json"; artifact = json.loads(artifact_path.read_text())
                artifact["receipts"]["source-manifest.json"] = packet["receipts"]["source-manifest.json"]
                packet["receipts"]["artifact-receipt.json"] = write_json(artifact_path, artifact)
            else:
                equality = json.loads(paths["controlDistManifest"].read_text())
                if case == "path": equality["dist"] = {"../outside.js": "0" * 64}
                else: equality["migrations"].pop(next(iter(equality["migrations"])))
                packet["receipts"]["source-runtime-equality.json"] = write_json(paths["controlDistManifest"], equality)
            self.save(paths, selected, packet)
            with self.subTest(case=case), self.assertRaises(NativeRecipeError): coordinates(paths, selected, "arm64")

    def test_legacy_flat_receipt_keeps_its_exact_files_and_ledger(self):
        from test_native_inspect import NativeInspectTests
        fixture = NativeInspectTests(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        result = coordinates(fixture.inputs, fixture.s["control"], "arm64")
        self.assertIs(result["rawV2"], False)
        self.assertEqual(result["migration"]["ledger"], "selfhost_schema_migrations")
        self.assertEqual(result["dist"], {"dist/config.js": "a" * 64})
        self.assertEqual(fixture.stack.calls, [])

    def test_ledger_read_uses_only_source_bound_identifier_and_readonly_transport(self):
        value = {"migration": {"source": "a" * 40, "ledger": "control_schema_migrations", "sql": {"one.sql": "b" * 64}}}
        adapter = NativeControlTransport(); adapter.inputs = {}; calls = []
        adapter._psql = lambda *a, **kw: calls.append((a, kw)) or json.dumps(value["migration"]["sql"])
        selected = {"control": {"sourceRevision": "a" * 40}, "architecture": "arm64"}
        with patch("native_control.control_coordinates", return_value=value):
            adapter._verify_control_ledger(selected)
            self.assertIn("public.control_schema_migrations", calls[0][0][2])
            self.assertEqual(calls[0][1], {"read_only": True})
            value["migration"]["ledger"] = "foreign; DROP TABLE anything"
            with self.assertRaisesRegex(NativeRecipeError, "qualified_control_ledger"): adapter._verify_control_ledger(selected)
        self.assertEqual(len(calls), 1)


if __name__ == "__main__": unittest.main()
