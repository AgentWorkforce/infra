"""Read qualified Control receipts unchanged, deriving coordinates in memory."""
import hashlib
from pathlib import Path
import re
import tarfile

from native_recipe import require

RAW_RESULT = "PASS_CONTROL_OFFICIAL_ARM64_LOCKED_RUNTIME_PG17_FRESH_AND_UPGRADE_QUALIFICATION"
RAW_FIELDS = set("result sourceRevision sourceTree sourceMergedAs publicPr reference manifestDigest configDigest dockerIndexDigest localTag archive archiveSha256 architecture officialDockerfileUnmodifiedFromSelectedSource sourceProductionLockActualRuntimeDependencies compiledOutputFiles sqlFiles previous23SqlBytesUnchanged freshSqlApplied upgradeSqlApplied repeatApplied actualOfficialMigrateAndServerModulesExercised runtimeIdentityAndNoDdlNoLedgerPrivileges genuineSyntheticDeviceTokenAndDataPreservedOnUpgrade readContractModes capabilitiesEndpoint capabilities receipts limits priorFailuresPreserved createdUtc".split())
RAW_RECEIPTS = set("source-manifest.json build-receipt.json build-metadata.json build-stage-metadata.json migration-source-comparison.json native-base-chain.json source-runtime-equality.json compiled-config-probe.json artifact-receipt.json actual-runtime-module-resolution.json owned-pg17/result.json owned-pg17/prove.py owned-pg17/scripts/migrate.mjs owned-pg17/scripts/server-smoke.mjs".split())


def file_map(value, *, sql=False):
    require(isinstance(value, dict) and 0 < len(value) <= 10000, "bounded_control_file_manifest_required")
    for name, digest in value.items():
        require(isinstance(name, str) and name and len(name) <= 1024 and not name.startswith("/") and str(Path(name)) == name and
                "\\" not in name and ".." not in Path(name).parts and
                all(ord(c) >= 32 and ord(c) != 127 for c in name) and
                (not sql or re.fullmatch(r"[A-Za-z0-9_-]+\.sql", name)) and
                isinstance(digest, str) and re.fullmatch(r"[a-f0-9]{64}", digest),
                "bounded_control_file_manifest_required")
    return value


def source_archive(path, expected_sha, files, modes):
    from native_inspect import sha
    require(sha(path) == expected_sha, "control_source_archive_changed")
    with tarfile.open(path) as archive:
        members = [m for m in archive if not m.isdir()]
        require(len(members) == len(files) and {m.name for m in members} == set(files) and
                all(m.isfile() and 0 <= m.size <= 8 * 1024 * 1024 for m in members),
                "control_source_archive_members_changed")
        migrations_source = None
        normalized = 0
        for member in members:
            expected_mode = modes[member.name]
            # This frozen RawV2 builder writes verified bytes into a new
            # build context and explicitly chmods to the manifest mode.
            # Its git archive has 0664 while the tracked checkout has 0644.
            # Accept exactly that pair or equality, never a general mask,
            # executable inference, special bit or arbitrary mismatch.
            require(member.mode in (0o644, 0o664, 0o755) and expected_mode in (0o644, 0o755) and
                    (member.mode == expected_mode or (member.mode, expected_mode) == (0o664, 0o644)),
                    "control_source_archive_mode_changed")
            normalized += member.mode != expected_mode
            raw = archive.extractfile(member).read()
            require(hashlib.sha256(raw).hexdigest() == files[member.name], "control_source_file_changed")
            if member.name == "src/migrations.ts":
                migrations_source = raw.decode()
    # Only these two official, bounded identifiers are supported. This is a
    # read-only verifier target, never an alternate migration implementation.
    match = re.search(r'^const MIGRATION_LEDGER = "(control_schema_migrations|selfhost_schema_migrations)";$',
                      migrations_source or "", re.MULTILINE)
    require(match is not None, "qualified_control_migration_ledger_contract_required")
    return match.group(1), {"contract": "verified-bytes-then-explicit-manifest-chmod-v1",
                            "normalized0664To0644Files": normalized, "exactModeFiles": len(files) - normalized}


def coordinates(paths, selected, architecture):
    from native_inspect import document, native_archive, same_local_reference, sha
    packet = document(paths["controlReceipt"], selected["artifactReceiptSha256"])
    require(isinstance(packet, dict) and all(packet.get(k) == selected[k] for k in ("sourceRevision", "manifestDigest", "configDigest")) and
            same_local_reference(packet.get("reference"), selected["reference"]), "control_receipt_chain_mismatch")
    if packet.get("result") != RAW_RESULT:
        # Preserve the existing flat receipt contract, including its original
        # hashes and file names. No RawV2 field or proof is silently inferred.
        require({"nativeArchiveSha256", "imageDistManifestSha256", "sourceFileManifestSha256", "tag", "dockerIndexDigest"} <= set(packet),
                "qualified_flat_control_receipt_required")
        config = native_archive(paths["controlArchive"], packet["nativeArchiveSha256"], selected["sourceRevision"],
                                selected["manifestDigest"], selected["configDigest"], architecture)
        dist = document(paths["controlDistManifest"], packet["imageDistManifestSha256"])
        migration = document(paths["controlMigrationManifest"], paths["controlMigrationManifestSha256"])
        require(migration["source"] == selected["sourceRevision"] and
                migration["migrationCount"] == len(migration["sql"]), "control_schema_manifest_mismatch")
        source = document(paths["controlSourceManifest"], packet["sourceFileManifestSha256"])
        require(all(source.get("migrations/" + n) == h for n, h in migration["sql"].items()),
                "control_source_schema_binding_mismatch")
        return {**packet, "dist": dist, "migration": {**migration, "ledger": "selfhost_schema_migrations"},
                "source": source, "nativeConfig": config, "rawV2": False}

    require(set(packet) == RAW_FIELDS and architecture == "arm64" and packet["architecture"] == "linux/arm64" and
            isinstance(packet["sourceTree"], str) and re.fullmatch(r"[a-f0-9]{40}", packet["sourceTree"]) and
            isinstance(packet["sourceMergedAs"], str) and re.fullmatch(r"[a-f0-9]{40}", packet["sourceMergedAs"]) and
            isinstance(packet["publicPr"], str) and re.fullmatch(r"https://github\.com/AgentWorkforce/relay-control/pull/[1-9][0-9]*", packet["publicPr"]) and
            isinstance(packet["archive"], str) and 0 < len(packet["archive"]) <= 4096 and
            all(ord(c) >= 32 and ord(c) != 127 for c in packet["archive"]) and
            isinstance(packet["createdUtc"], str) and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|\+00:00)", packet["createdUtc"]) and
            all(isinstance(packet[k], list) and all(isinstance(v, str) and len(v) <= 4096 for v in packet[k])
                for k in ("limits", "priorFailuresPreserved")) and
            packet["officialDockerfileUnmodifiedFromSelectedSource"] is True and
            packet["previous23SqlBytesUnchanged"] is True and type(packet["repeatApplied"]) is int and packet["repeatApplied"] == 0 and
            all(packet[k] is True for k in ("actualOfficialMigrateAndServerModulesExercised",
                "runtimeIdentityAndNoDdlNoLedgerPrivileges", "genuineSyntheticDeviceTokenAndDataPreservedOnUpgrade")) and
            packet["capabilitiesEndpoint"] == "/cloud/api/v1/capabilities" and
            isinstance(packet["capabilities"], dict) and set(packet["capabilities"]) == {"flows", "relayfile", "chief"} and
            all(v is False for v in packet["capabilities"].values()) and
            packet["readContractModes"] == ["legacy-direct-opt-in with original sh_at_", "native-issuer with independent rth read handoff"],
            "qualified_raw_control_packet_required")
    require("controlSourceArchive" in paths, "raw_control_source_archive_required")
    root = Path(paths["controlReceipt"]).parent
    receipts = packet["receipts"]
    require(isinstance(receipts, dict) and set(receipts) == RAW_RECEIPTS and
            all(isinstance(v, str) and re.fullmatch(r"[a-f0-9]{64}", v) for v in receipts.values()),
            "raw_control_child_receipt_set_required")
    for name, expected in receipts.items():
        require(sha(root / name) == expected, "raw_control_child_receipt_changed")
    def receipt(name):
        return document(root / name, receipts[name])
    for key, name in (("controlSourceManifest", "source-manifest.json"),
                      ("controlDistManifest", "source-runtime-equality.json"),
                      ("controlMigrationManifest", "migration-source-comparison.json")):
        require(sha(paths[key]) == receipts[name], "raw_control_selected_manifest_changed")
    require(paths["controlMigrationManifestSha256"] == receipts["migration-source-comparison.json"],
            "raw_control_migration_hash_binding_changed")
    source, equality, migrations = receipt("source-manifest.json"), receipt("source-runtime-equality.json"), receipt("migration-source-comparison.json")
    build, artifact = receipt("build-receipt.json"), receipt("artifact-receipt.json")
    runtime, base = build["images"]["runtime"], receipt("native-base-chain.json")["runtime"]
    metadata, probe = receipt("build-metadata.json"), receipt("compiled-config-probe.json")
    require(all(v.get("sourceRevision") == packet["sourceRevision"] and v.get("sourceTree") == packet["sourceTree"]
                for v in (source, migrations, build, artifact)), "raw_control_source_binding_changed")
    require(isinstance(artifact.get("receipts"), dict) and artifact["receipts"] and
            all(name in receipts and value == receipts[name] for name, value in artifact["receipts"].items()),
            "raw_control_artifact_child_binding_changed")
    require(all(artifact.get(k) == packet[k] for k in ("manifestDigest", "configDigest", "localTag", "archiveSha256")) and
            same_local_reference(artifact.get("reference"), packet["reference"]) and artifact["architecture"] == architecture and
            runtime.get("tag") == packet["localTag"] and runtime.get("nativeManifestDigest") == packet["manifestDigest"] and
            runtime.get("configDigest") == packet["configDigest"] and runtime.get("archiveSha256") == packet["archiveSha256"] and
            base.get("candidateNativeManifest") == packet["manifestDigest"] and base.get("candidateConfigDigest") == packet["configDigest"] and
            base.get("allLayerBlobAndDiffIdsVerified") is True and base.get("exactBasePrefix") is True and
            base.get("metadataSha256") == receipts["build-metadata.json"], "raw_control_native_chain_changed")
    index = packet["dockerIndexDigest"]
    require(isinstance(index, str) and re.fullmatch(r"sha256:[a-f0-9]{64}", index) and
            index not in (packet["manifestDigest"], packet["configDigest"]) and
            metadata.get("containerimage.digest") == index and metadata.get("containerimage.descriptor", {}).get("digest") == index and
            metadata.get("containerimage.descriptor", {}).get("mediaType") == "application/vnd.oci.image.index.v1+json" and
            re.fullmatch(r"agent-relay-kind/[a-z0-9._/-]+:[A-Za-z0-9_.-]+", packet["localTag"]) and
            same_local_reference(packet["reference"], packet["localTag"].split(":")[0] + "@" + packet["manifestDigest"]),
            "raw_control_index_descriptor_changed")
    files, dist, sql = file_map(source["files"]), file_map(equality["dist"]), file_map(migrations["sql"], sql=True)
    require(isinstance(source.get("modes"), dict) and set(source["modes"]) == set(files) and
            all(type(v) is int and v in (0o644, 0o755) for v in source["modes"].values()) and
            equality.get("result") == "PASS_FRESH_OFFICIAL_COMPILATION_PACKAGE_SQL_AND_LOCK_BOUND_DEPENDENCIES" and
            equality.get("unexpectedRuntimeDependencyVersionsOrIntegrity") == [] and
            all(equality.get(k) is True for k in ("runtimePackageFilesMatchFreshBuild", "runtimeSourceLockByteIdentical", "actualInstalledLockUsed")) and
            type(packet["sourceProductionLockActualRuntimeDependencies"]) is int and packet["sourceProductionLockActualRuntimeDependencies"] > 0 and
            equality.get("runtimeDependenciesMatchingBuildLock") == packet["sourceProductionLockActualRuntimeDependencies"] and
            all(type(v) is int and v == len(dist) for v in (equality.get("compiledDistFiles"), packet["compiledOutputFiles"])) and
            all(type(v) is int and v == len(sql) for v in (equality.get("sqlFiles"), packet["sqlFiles"], source.get("sqlCount"), artifact.get("sqlCount"), packet["freshSqlApplied"])) and
            len(sql) > 23 and type(packet["upgradeSqlApplied"]) is int and packet["upgradeSqlApplied"] == len(sql) - 23 and
            equality.get("migrations") == sql and {n.removeprefix("migrations/"): h for n, h in files.items() if n.startswith("migrations/")} == sql and
            build.get("sourceArchiveSha256") == source.get("sourceArchiveSha256") and
            build.get("officialDockerfileUnmodified") is True and artifact.get("officialDockerfileUnmodified") is True and
            isinstance(build.get("officialDockerfileSha256"), str) and re.fullmatch(r"[a-f0-9]{64}", build["officialDockerfileSha256"]) and
            build.get("officialDockerfileSha256") == source.get("officialDockerfileSha256") == files.get("Dockerfile"),
            "raw_control_source_runtime_manifests_changed")
    require(probe.get("result") == "PASS_COMPILED_CORE_CAPABILITIES_AND_NATIVE_DIRECT_CONFIG" and
            probe.get("coreCapabilities") == packet["capabilities"] and all(v is False for v in probe["coreCapabilities"].values()) and
            type(probe.get("networkCalls")) is int and probe["networkCalls"] == 0 and
            all(probe.get(k) is True for k in ("capabilitiesEndpoint", "licenseModuleAbsent", "directOptIn", "nativeSingleOrigin", "nativeRefusesLegacyDirectOverride")),
            "raw_control_compiled_contract_proof_required")
    ledger, mode_binding = source_archive(paths["controlSourceArchive"], source["sourceArchiveSha256"], files, source["modes"])
    config = native_archive(paths["controlArchive"], packet["archiveSha256"], packet["sourceRevision"], packet["manifestDigest"], packet["configDigest"], architecture)
    require(isinstance(config.get("config"), dict) and config["config"] == runtime.get("runtimeConfig") and config.get("rootfs", {}).get("type") == "layers" and
            isinstance(config["rootfs"].get("diff_ids"), list) and config["rootfs"]["diff_ids"] and
            all(isinstance(v, str) and re.fullmatch(r"sha256:[a-f0-9]{64}", v) for v in config["rootfs"]["diff_ids"]),
            "raw_control_native_config_changed")
    return {**packet, "tag": packet["localTag"], "nativeArchiveSha256": packet["archiveSha256"],
            "dist": {"dist/" + n: h for n, h in dist.items()}, "source": files,
            "migration": {"source": packet["sourceRevision"], "migrationCount": len(sql), "sql": sql, "ledger": ledger},
            "nativeConfig": config, "sourceModeBinding": mode_binding, "rawV2": True}
