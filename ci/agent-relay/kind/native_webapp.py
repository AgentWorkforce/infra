"""Read unchanged qualified frontend receipts; never infer backend acceptance."""
from pathlib import Path
import re

from native_inspect import document, native_archive, same_local_reference
from native_recipe import require

WEBAPP_INPUTS = {"webappPacket", "webappPacketSha256", "webappArchive", "webappBuildMetadata"}


def coordinates(inputs, architecture):
    require(WEBAPP_INPUTS <= set(inputs), "qualified_webapp_packet_and_native_archive_required")
    packet = document(inputs["webappPacket"], inputs["webappPacketSha256"])
    require(packet.get("result") == "PASS_PUBLIC_WEBAPP_OFFICIAL_NATIVE_SOURCE_AND_STATIC_RUNTIME" and
            packet.get("architecture") == architecture and packet.get("officialDockerfileUnmodified") is True and
            packet.get("capabilitiesApi") == "/cloud/api/v1/capabilities" and
            packet.get("requiresCapabilitiesControlAbi") is True and
            packet.get("sourceRepository") == "https://github.com/AgentWorkforce/relay-webapp" and
            re.fullmatch(r"[a-f0-9]{40}", packet.get("sourceTree", "")) and
            re.fullmatch(r"[a-f0-9]{40}", packet.get("sourceRevision", "")), "qualified_capabilities_webapp_packet_required")
    root = Path(inputs["webappPacket"]).parent
    def receipt(name):
        return document(root / name, packet["receipts"][name])
    build = receipt("build-receipt.json")
    runtime = build["images"]["runtime"]
    base = receipt("base-chain-receipt.json")["runtime"]
    bundle = receipt("compiled-bundle-manifest.json")
    smoke = receipt("runtime-smoke-receipt.json")
    require(build.get("sourceRevision") == packet["sourceRevision"] and build.get("sourceTree") == packet.get("sourceTree") and
            runtime.get("nativeManifestDigest") == packet.get("manifestDigest") and runtime.get("configDigest") == packet.get("configDigest") and
            runtime.get("archiveSha256") == packet.get("archiveSha256") and
            base.get("candidateNativeManifest") == packet["manifestDigest"] and base.get("candidateConfigDigest") == packet["configDigest"] and
            base.get("allLayerBlobAndDiffIdsVerified") is True and base.get("exactBasePrefix") is True,
            "webapp_source_native_and_base_chain_mismatch")
    require(smoke.get("result") == "PASS_UID101_NETWORK_NONE_STATIC_AND_RUNTIME_CONFIG" and
            smoke.get("uid") == 101 and smoke.get("network") == "none" and smoke.get("healthz") == 200 and
            bundle.get("sourceStageExact") is True and bundle.get("runtimeExactExceptBase50x") is True and
            bundle.get("capabilitiesEndpoint") == packet["capabilitiesApi"] and bundle.get("oldLicenseEndpointAbsent") is True,
            "webapp_static_capabilities_runtime_proof_required")
    metadata = document(inputs["webappBuildMetadata"], base["metadataSha256"])
    index = metadata.get("containerimage.digest")
    require(isinstance(index, str) and re.fullmatch(r"sha256:[a-f0-9]{64}", index) and
            metadata.get("containerimage.descriptor", {}).get("digest") == index,
            "webapp_build_index_descriptor_required")
    config = native_archive(inputs["webappArchive"], packet["archiveSha256"], packet["sourceRevision"],
                            packet["manifestDigest"], packet["configDigest"], architecture)
    require(config.get("config") == runtime["runtimeConfig"] and config["config"].get("User") == "101" and
            config.get("rootfs", {}).get("type") == "layers" and config["rootfs"].get("diff_ids"),
            "webapp_native_runtime_config_mismatch")
    require(isinstance(runtime.get("tag"), str) and re.fullmatch(r"agent-relay-kind/[a-z0-9._/-]+:[A-Za-z0-9_.-]+", runtime["tag"]) and
            same_local_reference(packet.get("reference"), runtime["tag"].split(":")[0] + "@" + packet["manifestDigest"]),
            "qualified_local_webapp_reference_required")
    files = bundle.get("files")
    require(isinstance(files, dict) and files and all(isinstance(n, str) and
            re.fullmatch(r"[A-Za-z0-9_./-]+", n) and not n.startswith("/") and ".." not in Path(n).parts and
            isinstance(h, str) and re.fullmatch(r"[a-f0-9]{64}", h) for n, h in files.items()), "bounded_webapp_static_manifest_required")
    return {"sourceRevision": packet["sourceRevision"], "reference": packet["reference"],
            "manifestDigest": packet["manifestDigest"], "configDigest": packet["configDigest"],
            "packetSha256": inputs["webappPacketSha256"], "archiveSha256": packet["archiveSha256"],
            "indexDigest": index, "tag": runtime["tag"], "config": config, "files": files}
