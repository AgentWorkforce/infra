#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'error: this script must run from a Git worktree\n' >&2
  exit 2
}

exec python3 - "$repo_root" "$@" <<'PY'
from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import pwd
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile


ARTIFACT_NAME = "agent-relay-customer-handoff"
MANIFEST_NAME = "RELEASE-MANIFEST.json"
CHECKSUMS_NAME = "SHA256SUMS"

# These are the only source trees eligible for the handoff. The final,
# revision-specific list is sorted, recorded in RELEASE-MANIFEST.json, and
# passed to the archive writers one entry at a time.
#
# Charts are not listed here: the umbrella (UMBRELLA_CHART) is followed
# through its file:// dependencies, recursively, at the packaged revision, so
# a new umbrella dependency (e.g. charts/relayflows) can never be left out.
UMBRELLA_CHART = "charts/agent-relay"
INCLUDE_TREES = (
    ".agents/skills/setting-up-self-hosted-agent-relay-gcp",
    "deps",
    "docs/conformance",
    "docs/diagrams",
    "docs/handoff",
    "docs/licenses",
    "docs/operations",
    "docs/support",
    "scripts/conformance",
    "scripts/release",
    "scripts/selfhost",
    "scripts/support",
    "self-hosted",
)
INCLUDE_FILES = (
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "docs/control-webapp-chart-rename.md",
    "docs/enterprise-aws-install.md",
    "docs/self-hosted-native-ingest.md",
    "docs/self-hosted-image-supply-chain.md",
    "docs/self-hosted-reference-architecture.md",
    "docs/self-hosted-relayflows.md",
    "docs/self-hosted-requirements.md",
    "docs/selfhost-backup-restore.md",
    "scripts/package-customer-handoff.sh",
)

# CI fixtures and vendored build output are intentionally not customer source.
EXCLUDED_COMPONENTS = frozenset(("ci",))
EXCLUDED_PREFIXES = (
    "charts/agent-relay/charts/",
)
EXCLUDED_NAME_FRAGMENTS = (
    "proof",
)
# The end-to-end harness is customer-runnable against any install's public
# origins (it holds no proof-environment values), so it ships despite its name.
# Proof values files stay excluded.
INCLUDED_DESPITE_NAME = frozenset((
    "scripts/selfhost/e2e-gcp-proof.sh",
    "scripts/selfhost/e2e-gcp-proof-driver.mjs",
    "scripts/selfhost/e2e-gcp-proof-sessions-pipeline.ts",
))

# A complete handoff must contain these exact tracked inputs. The development
# override can exercise packaging against an older revision, but the resulting
# archive is marked incomplete and verification rejects it by default.
REQUIRED_FILES = (
    ".agents/skills/setting-up-self-hosted-agent-relay-gcp/SKILL.md",
    ".agents/skills/setting-up-self-hosted-agent-relay-gcp/assets/restore-overlay.yaml",
    ".agents/skills/setting-up-self-hosted-agent-relay-gcp/references/pre-upgrade-evidence.md",
    ".agents/skills/setting-up-self-hosted-agent-relay-gcp/references/public-verification.md",
    ".agents/skills/setting-up-self-hosted-agent-relay-gcp/references/restore-into-target.md",
    ".agents/skills/setting-up-self-hosted-agent-relay-gcp/scripts/pre-upgrade-check.sh",
    ".agents/skills/setting-up-self-hosted-agent-relay-gcp/scripts/preflight.sh",
    ".agents/skills/setting-up-self-hosted-agent-relay-gcp/scripts/resolve-layout.sh",
    ".agents/skills/setting-up-self-hosted-agent-relay-gcp/scripts/test-layout.sh",
    ".agents/skills/setting-up-self-hosted-agent-relay-gcp/scripts/verify-public.sh",
    "docs/diagrams/agent-relay-architecture.mmd",
    "docs/diagrams/agent-relay-architecture.png",
    "docs/diagrams/agent-relay-architecture.svg",
    "docs/diagrams/agent-relay-request-flow.mmd",
    "docs/diagrams/agent-relay-request-flow.png",
    "docs/diagrams/agent-relay-request-flow.svg",
    "charts/sessions-pipeline-worker/Chart.yaml",
    "charts/sessions-pipeline-worker/values.yaml",
    "charts/sessions-pipeline/Chart.lock",
    "charts/sessions-pipeline/Chart.yaml",
    "charts/sessions-pipeline/values.yaml",
    "charts/session-ingest-api/Chart.yaml",
    "charts/session-ingest-api/values.yaml",
    "charts/agent-relay/Chart.lock",
    "charts/agent-relay/Chart.yaml",
    "charts/agent-relay/README.md",
    "charts/agent-relay/templates/gke-ingress.yaml",
    "charts/agent-relay/values-gcp-native.yaml",
    "charts/agent-relay/values-gcp.yaml",
    "charts/agent-relay/values-scrub-wasm-bindgen.yaml",
    "charts/agent-relay/values.yaml",
    "charts/relay-control/Chart.yaml",
    "charts/relay-control/values.yaml",
    "charts/relay-webapp/Chart.yaml",
    "charts/relay-webapp/values.yaml",
    "charts/relayauth/Chart.yaml",
    "charts/relayauth/values.yaml",
    "charts/relaycast/Chart.yaml",
    "charts/relaycast/values.yaml",
    "deps/PINS.md",
    "docs/conformance/README.md",
    "docs/conformance/adapter-contract.md",
    "docs/licenses/AGPL-3.0-only.txt",
    "docs/licenses/Apache-2.0.txt",
    "docs/control-webapp-chart-rename.md",
    "docs/enterprise-aws-install.md",
    "docs/self-hosted-native-ingest.md",
    "docs/self-hosted-image-supply-chain.md",
    "docs/self-hosted-reference-architecture.md",
    "docs/self-hosted-requirements.md",
    "docs/selfhost-backup-restore.md",
    "self-hosted/customer-images.yaml",
    "self-hosted/customer-release-evidence.json",
    "self-hosted/customer-release-evidence.schema.json",
    "scripts/package-customer-handoff.sh",
    "scripts/conformance/http-adapter.sh",
    "scripts/conformance/lib.sh",
    "scripts/conformance/run.sh",
    "scripts/conformance/tests/run-tests.sh",
    "scripts/release/validate-customer-release.py",
    "scripts/selfhost/README.md",
    "scripts/selfhost/rds-setup.sh",
    "scripts/selfhost/verify-agent-relay.sh",
    "scripts/selfhost/session-identities.py",
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
)

# Split literals prevent the safety checker from finding its own denylisted
# values when this script is included in an archive.
FORBIDDEN_VALUES = tuple(
    value.encode("utf-8")
    for value in (
        "agentrelay-96bulls-" + "soc2-2610",
        "955297" + "012355",
        "gcp-" + "proof.agentrelay.com",
        "agent-relay-gcp-" + "proof",
        "awf-conformance-" + "gke",
        "34.111." + "70.61",
    )
)


class HandoffError(RuntimeError):
    pass


def git(repo: Path, *args: str, input_bytes: bytes | None = None) -> bytes:
    try:
        return subprocess.run(
            ("git", "-C", str(repo), *args),
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout
    except FileNotFoundError as exc:
        raise HandoffError("git is required") from exc
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.decode("utf-8", "replace").strip()
        raise HandoffError(f"git {' '.join(args)} failed: {detail}") from exc


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json(value: object) -> bytes:
    return (
        json.dumps(value, sort_keys=True, indent=2, ensure_ascii=True) + "\n"
    ).encode("utf-8")


FILE_DEPENDENCY = re.compile(
    rb"""^\s*repository:\s*["']?file://\.\./([A-Za-z0-9._-]+)/?["']?\s*(?:#.*)?$""",
    re.MULTILINE,
)


def chart_trees(read_chart_yaml) -> tuple[str, ...]:
    """The umbrella chart plus every chart it reaches through file://
    dependencies. read_chart_yaml(chart_dir) returns Chart.yaml bytes or None."""
    seen: set[str] = set()
    queue = [UMBRELLA_CHART]
    while queue:
        chart = queue.pop()
        if chart in seen:
            continue
        seen.add(chart)
        data = read_chart_yaml(chart)
        if data is None:
            continue
        for match in FILE_DEPENDENCY.finditer(data):
            queue.append(f"charts/{match.group(1).decode('ascii')}")
    return tuple(sorted(seen))


def required_files(charts: tuple[str, ...]) -> set[str]:
    required = set(REQUIRED_FILES)
    for chart in charts:
        required.update((f"{chart}/Chart.yaml", f"{chart}/values.yaml"))
    return required


def selected_path(path: str, charts: tuple[str, ...]) -> bool:
    pure = PurePosixPath(path)
    if any(part in EXCLUDED_COMPONENTS for part in pure.parts):
        return False
    if any(path.startswith(prefix) for prefix in EXCLUDED_PREFIXES):
        return False
    lowered_parts = tuple(part.lower() for part in pure.parts)
    if path in INCLUDED_DESPITE_NAME:
        return True
    if any(
        fragment in part
        for part in lowered_parts
        for fragment in EXCLUDED_NAME_FRAGMENTS
    ):
        return False
    if path in INCLUDE_FILES:
        return True
    return any(path.startswith(tree + "/") for tree in (*INCLUDE_TREES, *charts))


def parse_tree(
    repo: Path, revision: str
) -> tuple[dict[str, tuple[int, bytes]], tuple[str, ...]]:
    raw = git(repo, "ls-tree", "-r", "-z", revision)
    records = []
    blobs: dict[str, bytes] = {}
    for record in raw.split(b"\0"):
        if not record:
            continue
        metadata, path_bytes = record.split(b"\t", 1)
        mode_text, kind, object_id = metadata.split(b" ", 2)
        path = path_bytes.decode("utf-8")
        records.append((mode_text, kind, object_id, path))
        if path.startswith("charts/") and path.endswith("/Chart.yaml") and kind == b"blob":
            blobs[path] = object_id

    def read_chart_yaml(chart: str) -> bytes | None:
        object_id = blobs.get(f"{chart}/Chart.yaml")
        return git(repo, "cat-file", "blob", object_id.decode("ascii")) if object_id else None

    charts = chart_trees(read_chart_yaml)
    result: dict[str, tuple[int, bytes]] = {}
    for mode_text, kind, object_id, path in records:
        if not selected_path(path, charts):
            continue
        if kind != b"blob" or mode_text not in (b"100644", b"100755"):
            raise HandoffError(
                f"unsupported Git entry for customer handoff: {mode_text.decode()} "
                f"{kind.decode()} {path}"
            )
        mode = 0o755 if mode_text == b"100755" else 0o644
        data = git(repo, "cat-file", "blob", object_id.decode("ascii"))
        result[path] = (mode, data)
    return result, charts


def local_identifiers(repo: Path) -> tuple[bytes, ...]:
    candidates: set[str] = set()
    try:
        candidates.add(pwd.getpwuid(os.getuid()).pw_name)
    except (KeyError, OSError):
        pass
    candidates.add(Path.home().name)
    for key in ("user.name", "user.email"):
        try:
            value = git(repo, "config", "--get", key).decode().strip()
        except HandoffError:
            continue
        candidates.add(value)
        if "@" in value:
            candidates.add(value.split("@", 1)[0])
    return tuple(
        value.encode("utf-8")
        for value in sorted(candidates)
        if len(value) >= 4 and value.lower() not in {"root", "user", "runner"}
    )


def scan_content(
    files: dict[str, tuple[int, bytes]], identifiers: tuple[bytes, ...]
) -> None:
    problems: list[str] = []
    for path, (_, data) in sorted(files.items()):
        lowered = data.lower()
        for forbidden in FORBIDDEN_VALUES:
            if forbidden.lower() in lowered:
                problems.append(f"{path}: contains a proof-environment value")
                break
        for identifier in identifiers:
            if identifier.lower() in lowered:
                problems.append(f"{path}: contains a local user identifier")
                break
    if problems:
        shown = "\n  ".join(problems[:20])
        extra = "" if len(problems) <= 20 else f"\n  ... {len(problems) - 20} more"
        raise HandoffError(f"unsafe customer content:\n  {shown}{extra}")


def directory_names(file_names: list[str], root: str) -> list[str]:
    directories = {root}
    for name in file_names:
        current = PurePosixPath(root, name).parent
        while str(current) != ".":
            directories.add(str(current))
            if str(current) == root:
                break
            current = current.parent
    return sorted(directories, key=lambda item: (item.count("/"), item))


def archive_entries(
    root: str, files: dict[str, tuple[int, bytes]]
) -> tuple[list[str], list[tuple[str, int, bytes]]]:
    file_entries = [
        (f"{root}/{path}", mode, data)
        for path, (mode, data) in sorted(files.items())
    ]
    directories = directory_names([path for path in files], root)
    return directories, file_entries


def write_tar_gz(
    output: Path, root: str, files: dict[str, tuple[int, bytes]], epoch: int
) -> None:
    directories, file_entries = archive_entries(root, files)
    with output.open("wb") as raw:
        with gzip.GzipFile(
            filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=epoch
        ) as compressed:
            with tarfile.open(
                fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT
            ) as archive:
                for path in directories:
                    info = tarfile.TarInfo(path + "/")
                    info.type = tarfile.DIRTYPE
                    info.mode = 0o755
                    info.uid = 0
                    info.gid = 0
                    info.uname = ""
                    info.gname = ""
                    info.mtime = epoch
                    info.size = 0
                    archive.addfile(info)
                for path, mode, data in file_entries:
                    info = tarfile.TarInfo(path)
                    info.type = tarfile.REGTYPE
                    info.mode = mode
                    info.uid = 0
                    info.gid = 0
                    info.uname = ""
                    info.gname = ""
                    info.mtime = epoch
                    info.size = len(data)
                    archive.addfile(info, io.BytesIO(data))


def zip_timestamp(epoch: int) -> tuple[int, int, int, int, int, int]:
    moment = dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc)
    if moment.year < 1980:
        moment = dt.datetime(1980, 1, 1, tzinfo=dt.timezone.utc)
    if moment.year > 2107:
        raise HandoffError("source timestamp exceeds the ZIP timestamp range")
    return (
        moment.year,
        moment.month,
        moment.day,
        moment.hour,
        moment.minute,
        moment.second - (moment.second % 2),
    )


def write_zip(
    output: Path, root: str, files: dict[str, tuple[int, bytes]], epoch: int
) -> None:
    directories, file_entries = archive_entries(root, files)
    timestamp = zip_timestamp(epoch)
    with zipfile.ZipFile(
        output,
        mode="w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
        strict_timestamps=True,
    ) as archive:
        archive.comment = b""
        for path in directories:
            info = zipfile.ZipInfo(path + "/", timestamp)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = (stat.S_IFDIR | 0o755) << 16
            info.extra = b""
            info.comment = b""
            archive.writestr(info, b"")
        for path, mode, data in file_entries:
            info = zipfile.ZipInfo(path, timestamp)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (stat.S_IFREG | mode) << 16
            info.extra = b""
            info.comment = b""
            archive.writestr(info, data, compresslevel=9)


def safe_member_name(name: str) -> None:
    pure = PurePosixPath(name)
    if (
        not name
        or "\\" in name
        or pure.is_absolute()
        or ".." in pure.parts
        or "." in pure.parts
    ):
        raise HandoffError(f"unsafe archive member path: {name!r}")


def load_tar(path: Path) -> tuple[dict[str, dict[str, object]], str]:
    raw_header = path.read_bytes()[:10]
    if len(raw_header) < 10 or raw_header[:2] != b"\x1f\x8b":
        raise HandoffError(f"not a gzip archive: {path}")
    gzip_mtime = int.from_bytes(raw_header[4:8], "little")
    entries: dict[str, dict[str, object]] = {}
    with tarfile.open(path, mode="r:gz") as archive:
        for member in archive:
            name = member.name.rstrip("/") if member.isdir() else member.name
            safe_member_name(name)
            if name in entries:
                raise HandoffError(f"duplicate archive member: {name}")
            if not (member.isdir() or member.isfile()):
                raise HandoffError(f"links and special files are forbidden: {name}")
            data = b""
            if member.isfile():
                stream = archive.extractfile(member)
                if stream is None:
                    raise HandoffError(f"cannot read archive member: {name}")
                data = stream.read()
            entries[name] = {
                "data": data,
                "directory": member.isdir(),
                "mode": member.mode & 0o777,
                "mtime": int(member.mtime),
                "uid": member.uid,
                "gid": member.gid,
                "uname": member.uname or "",
                "gname": member.gname or "",
            }
    return entries, f"tar:{gzip_mtime}"


def load_zip(path: Path) -> tuple[dict[str, dict[str, object]], str]:
    entries: dict[str, dict[str, object]] = {}
    with zipfile.ZipFile(path, mode="r") as archive:
        if archive.comment:
            raise HandoffError("ZIP archive comment must be empty")
        for member in archive.infolist():
            name = member.filename.rstrip("/") if member.is_dir() else member.filename
            safe_member_name(name)
            if name in entries:
                raise HandoffError(f"duplicate archive member: {name}")
            mode_with_type = member.external_attr >> 16
            file_type = stat.S_IFMT(mode_with_type)
            expected_type = stat.S_IFDIR if member.is_dir() else stat.S_IFREG
            if member.create_system != 3 or file_type != expected_type:
                raise HandoffError(f"non-portable ZIP metadata: {name}")
            if member.extra or member.comment:
                raise HandoffError(f"non-deterministic ZIP metadata: {name}")
            entries[name] = {
                "data": b"" if member.is_dir() else archive.read(member),
                "directory": member.is_dir(),
                "mode": stat.S_IMODE(mode_with_type),
                "date_time": member.date_time,
            }
    return entries, "zip"


def parse_checksums(data: bytes) -> dict[str, str]:
    result: dict[str, str] = {}
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise HandoffError("SHA256SUMS is not UTF-8") from exc
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\r\n]+)", line)
        if not match:
            raise HandoffError(f"invalid SHA256SUMS line: {line!r}")
        digest, name = match.groups()
        safe_member_name(name)
        if name in result:
            raise HandoffError(f"duplicate SHA256SUMS entry: {name}")
        result[name] = digest
    if not result:
        raise HandoffError("SHA256SUMS is empty")
    return result


def verify_archive(
    path: Path,
    expected_revision: str | None = None,
    allow_incomplete: bool = False,
    allow_preview: bool = False,
) -> dict[str, object]:
    if not path.is_file():
        raise HandoffError(f"archive does not exist: {path}")
    magic = path.read_bytes()[:4]
    if magic[:2] == b"\x1f\x8b":
        entries, archive_kind = load_tar(path)
    elif magic == b"PK\x03\x04":
        entries, archive_kind = load_zip(path)
    else:
        raise HandoffError(f"unsupported archive type: {path}")

    manifest_candidates = [
        name
        for name in entries
        if name.endswith("/" + MANIFEST_NAME)
        and not bool(entries[name]["directory"])
    ]
    if len(manifest_candidates) != 1:
        raise HandoffError("archive must contain exactly one release manifest")
    manifest_path = manifest_candidates[0]
    root = manifest_path[: -(len(MANIFEST_NAME) + 1)]
    if "/" in root or not root:
        raise HandoffError("archive must have exactly one top-level directory")
    try:
        manifest_data = bytes(entries[manifest_path]["data"])
        manifest = json.loads(manifest_data)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise HandoffError("release manifest is invalid JSON") from exc
    if manifest_data != canonical_json(manifest):
        raise HandoffError("release manifest JSON is not canonical")
    if manifest.get("schemaVersion") != 1:
        raise HandoffError("unsupported release manifest schema")
    if (
        manifest.get("artifact") != ARTIFACT_NAME
        or manifest.get("root") != root
        or root != ARTIFACT_NAME
    ):
        raise HandoffError("release manifest artifact identity does not match")
    if manifest.get("normalization") != {
        "directoryMode": "0755",
        "gid": 0,
        "group": "",
        "owner": "",
        "regularFileMode": "0644",
        "uid": 0,
    }:
        raise HandoffError("release manifest normalization policy is invalid")
    source = manifest.get("source")
    if not isinstance(source, dict):
        raise HandoffError("release manifest source is missing")
    revision = source.get("revision")
    tree = source.get("tree")
    epoch = source.get("sourceDateEpoch")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40,64}", revision):
        raise HandoffError("release manifest source revision is invalid")
    if not isinstance(tree, str) or not re.fullmatch(r"[0-9a-f]{40,64}", tree):
        raise HandoffError("release manifest source tree is invalid")
    if not isinstance(epoch, int) or epoch < 0:
        raise HandoffError("release manifest source timestamp is invalid")
    expected_timestamp = (
        dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc)
        .isoformat()
        .replace("+00:00", "Z")
    )
    if source.get("commitTimestamp") != expected_timestamp:
        raise HandoffError("release manifest commit timestamp is inconsistent")
    if expected_revision and revision != expected_revision:
        raise HandoffError(
            f"source revision mismatch: expected {expected_revision}, got {revision}"
        )
    incomplete = manifest.get("incomplete")
    if not isinstance(incomplete, bool):
        raise HandoffError("release manifest incomplete flag is invalid")
    missing_required = manifest.get("missingRequired")
    if not isinstance(missing_required, list) or not all(
        isinstance(item, str) for item in missing_required
    ):
        raise HandoffError("release manifest missingRequired is invalid")
    if incomplete != bool(missing_required):
        raise HandoffError("release manifest incomplete state is inconsistent")
    if incomplete and not allow_incomplete:
        raise HandoffError(
            "development archive is incomplete; pass --dev-allow-incomplete "
            "only for packaging tests"
        )
    release_mode = manifest.get("releaseMode")
    gate_result = manifest.get("productionGate")
    if release_mode not in ("release", "preview") or not isinstance(
        gate_result, dict
    ):
        raise HandoffError("release manifest mode or production gate is invalid")
    if release_mode == "release":
        if gate_result.get("status") != "passed":
            raise HandoffError("release archive does not record a passing production gate")
    elif not allow_preview:
        raise HandoffError(
            "development preview archive rejected; pass --dev-allow-preview "
            "only for non-production verification"
        )

    listed_files = manifest.get("files")
    if not isinstance(listed_files, list):
        raise HandoffError("release manifest files list is missing")

    def archived_chart_yaml(chart: str) -> bytes | None:
        entry = entries.get(f"{root}/{chart}/Chart.yaml")
        return None if entry is None or entry["directory"] else bytes(entry["data"])

    charts = chart_trees(archived_chart_yaml)
    expected_payload: dict[str, dict[str, object]] = {}
    previous = ""
    for item in listed_files:
        if not isinstance(item, dict):
            raise HandoffError("release manifest file entry is invalid")
        relpath = item.get("path")
        digest = item.get("sha256")
        size = item.get("size")
        mode_text = item.get("mode")
        if (
            not isinstance(relpath, str)
            or not isinstance(digest, str)
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
            or not isinstance(size, int)
            or size < 0
            or mode_text not in ("0644", "0755")
        ):
            raise HandoffError("release manifest file metadata is invalid")
        safe_member_name(relpath)
        if not selected_path(relpath, charts):
            raise HandoffError(f"release manifest contains an ineligible path: {relpath}")
        if relpath <= previous:
            raise HandoffError("release manifest files are not strictly sorted")
        previous = relpath
        expected_payload[relpath] = item
    actual_missing = sorted(required_files(charts) - set(expected_payload))
    if missing_required != actual_missing:
        raise HandoffError("release manifest required-input state is inconsistent")
    evidence_path = "self-hosted/customer-release-evidence.json"
    if release_mode == "release":
        evidence = expected_payload.get(evidence_path)
        if (
            not evidence
            or gate_result.get("evidence") != evidence_path
            or gate_result.get("evidenceSha256") != evidence.get("sha256")
        ):
            raise HandoffError(
                "production gate evidence is not bound to the archived payload"
            )
    elif gate_result != {
        "status": "not-run",
        "warning": "NOT FOR PRODUCTION OR CUSTOMER RELEASE",
    }:
        raise HandoffError("development preview warning is invalid")

    checksums_path = f"{root}/{CHECKSUMS_NAME}"
    if checksums_path not in entries or bool(entries[checksums_path]["directory"]):
        raise HandoffError("archive SHA256SUMS is missing")
    checksums = parse_checksums(bytes(entries[checksums_path]["data"]))
    expected_checksum_names = set(expected_payload) | {MANIFEST_NAME}
    if set(checksums) != expected_checksum_names:
        raise HandoffError("SHA256SUMS does not exactly cover payload plus manifest")

    actual_file_names: set[str] = set()
    for name, metadata in entries.items():
        if bool(metadata["directory"]):
            continue
        prefix = root + "/"
        if not name.startswith(prefix):
            raise HandoffError(f"archive member is outside the root: {name}")
        actual_file_names.add(name[len(prefix) :])
    expected_file_names = expected_checksum_names | {CHECKSUMS_NAME}
    if actual_file_names != expected_file_names:
        raise HandoffError("archive files do not exactly match the explicit manifest")

    for relpath, item in expected_payload.items():
        metadata = entries[f"{root}/{relpath}"]
        data = bytes(metadata["data"])
        if (
            len(data) != item["size"]
            or sha256(data) != item["sha256"]
            or metadata["mode"] != int(str(item["mode"]), 8)
        ):
            raise HandoffError(f"payload metadata mismatch: {relpath}")
        if checksums[relpath] != sha256(data):
            raise HandoffError(f"payload checksum mismatch: {relpath}")
    if checksums[MANIFEST_NAME] != sha256(manifest_data):
        raise HandoffError("release manifest checksum mismatch")
    canonical_checksums = "".join(
        f"{checksums[name]}  {name}\n" for name in sorted(checksums)
    ).encode("utf-8")
    if bytes(entries[checksums_path]["data"]) != canonical_checksums:
        raise HandoffError("SHA256SUMS is not canonically sorted")

    scan_files = {
        name: (int(metadata["mode"]), bytes(metadata["data"]))
        for name, metadata in entries.items()
        if not bool(metadata["directory"])
    }
    scan_content(scan_files, ())

    expected_directories = set(
        directory_names(sorted(expected_file_names), root)
    )
    actual_directories = {
        name for name, metadata in entries.items() if bool(metadata["directory"])
    }
    if actual_directories != expected_directories:
        raise HandoffError("archive directory list is not canonical")
    expected_order = list(directory_names(sorted(expected_file_names), root))
    expected_order.extend(f"{root}/{name}" for name in sorted(expected_file_names))
    if list(entries) != expected_order:
        raise HandoffError("archive member order is not canonical")

    if archive_kind.startswith("tar:"):
        gzip_mtime = int(archive_kind.split(":", 1)[1])
        if gzip_mtime != epoch:
            raise HandoffError("gzip timestamp is not normalized")
        for name, metadata in entries.items():
            relative = name[len(root) + 1 :] if name != root else ""
            expected_mode = (
                0o755
                if bool(metadata["directory"])
                else int(str(expected_payload[relative]["mode"]), 8)
                if relative in expected_payload
                else 0o644
            )
            if (
                metadata["uid"] != 0
                or metadata["gid"] != 0
                or metadata["uname"] != ""
                or metadata["gname"] != ""
                or metadata["mtime"] != epoch
                or metadata["mode"] != expected_mode
            ):
                raise HandoffError(f"tar metadata is not normalized: {name}")
    else:
        timestamp = zip_timestamp(epoch)
        for name, metadata in entries.items():
            relative = name[len(root) + 1 :] if name != root else ""
            expected_mode = (
                0o755
                if bool(metadata["directory"])
                else int(str(expected_payload[relative]["mode"]), 8)
                if relative in expected_payload
                else 0o644
            )
            if metadata["date_time"] != timestamp or metadata["mode"] != expected_mode:
                raise HandoffError(f"ZIP metadata is not normalized: {name}")

    return {
        "revision": revision,
        "tree": tree,
        "fileCount": len(expected_payload),
        "incomplete": incomplete,
        "releaseMode": release_mode,
        "sha256": sha256(path.read_bytes()),
    }


def resolve_revision(repo: Path, value: str) -> tuple[str, str, int, str]:
    revision = git(repo, "rev-parse", "--verify", f"{value}^{{commit}}").decode().strip()
    tree = git(repo, "rev-parse", "--verify", f"{revision}^{{tree}}").decode().strip()
    epoch_text = git(repo, "show", "-s", "--format=%ct", revision).decode().strip()
    try:
        epoch = int(epoch_text)
    except ValueError as exc:
        raise HandoffError("source commit timestamp is invalid") from exc
    timestamp = dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )
    return revision, tree, epoch, timestamp


def build(repo: Path, args: argparse.Namespace) -> None:
    status = git(
        repo,
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
        "--",
        ".",
        ":(exclude)dist",
    )
    preview = args.mode == "preview"
    if not preview and (args.dev_allow_dirty or args.dev_allow_incomplete):
        raise HandoffError("development overrides require --mode preview")
    if status and (not preview or not args.dev_allow_dirty):
        raise HandoffError(
            "worktree is dirty; production releases require committed source; "
            "development previews additionally require --dev-allow-dirty"
        )
    if status:
        print(
            "warning: dirty worktree ignored; packaging committed Git objects only",
            file=sys.stderr,
        )

    revision, tree, epoch, timestamp = resolve_revision(repo, args.revision)
    if not preview:
        head = git(repo, "rev-parse", "--verify", "HEAD^{commit}").decode().strip()
        if revision != head:
            raise HandoffError("release mode only packages the clean HEAD revision")
        gate_script = repo / "scripts/release/validate-customer-release.py"
        try:
            gated = subprocess.run(
                (
                    sys.executable,
                    str(gate_script),
                    "--root",
                    str(repo),
                    "--require-clean",
                ),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=True,
            )
        except subprocess.CalledProcessError as exc:
            detail = exc.stderr.strip() or exc.stdout.strip()
            raise HandoffError(f"production release gate failed:\n{detail}") from exc
        print(gated.stdout.strip())
    source_files, charts = parse_tree(repo, revision)
    missing = sorted(required_files(charts) - set(source_files))
    if missing and not args.dev_allow_incomplete:
        detail = "\n  ".join(missing)
        raise HandoffError(f"required tracked inputs are missing:\n  {detail}")
    if missing:
        print(
            "warning: creating an INCOMPLETE development archive; missing:\n  "
            + "\n  ".join(missing),
            file=sys.stderr,
        )
    if not source_files:
        raise HandoffError("explicit source selection produced no files")

    scan_content(source_files, local_identifiers(repo))
    file_manifest = [
        {
            "mode": f"{mode:04o}",
            "path": path,
            "sha256": sha256(data),
            "size": len(data),
        }
        for path, (mode, data) in sorted(source_files.items())
    ]
    manifest = {
        "artifact": ARTIFACT_NAME,
        "files": file_manifest,
        "incomplete": bool(missing),
        "missingRequired": missing,
        "normalization": {
            "directoryMode": "0755",
            "gid": 0,
            "group": "",
            "owner": "",
            "regularFileMode": "0644",
            "uid": 0,
        },
        "productionGate": (
            {
                "evidence": "self-hosted/customer-release-evidence.json",
                "evidenceSha256": sha256(
                    source_files["self-hosted/customer-release-evidence.json"][1]
                ),
                "status": "passed",
            }
            if not preview
            else {
                "status": "not-run",
                "warning": "NOT FOR PRODUCTION OR CUSTOMER RELEASE",
            }
        ),
        "releaseMode": args.mode,
        "root": ARTIFACT_NAME,
        "schemaVersion": 1,
        "source": {
            "commitTimestamp": timestamp,
            "revision": revision,
            "sourceDateEpoch": epoch,
            "tree": tree,
        },
    }
    manifest_data = canonical_json(manifest)
    packaged_files = dict(source_files)
    packaged_files[MANIFEST_NAME] = (0o644, manifest_data)
    checksum_lines = [
        f"{sha256(data)}  {path}\n"
        for path, (_, data) in sorted(packaged_files.items())
    ]
    packaged_files[CHECKSUMS_NAME] = (0o644, "".join(checksum_lines).encode("utf-8"))

    output_dir = Path(args.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    suffix = "-DEVELOPMENT-PREVIEW" if preview else ""
    if missing:
        suffix += "-INCOMPLETE"
    base_name = f"{ARTIFACT_NAME}-{revision[:12]}{suffix}"
    formats = ("tar.gz", "zip") if args.format == "both" else (args.format,)
    completed: list[Path] = []
    for format_name in formats:
        final_path = output_dir / f"{base_name}.{format_name}"
        fd, temporary_name = tempfile.mkstemp(
            prefix=f".{final_path.name}.", dir=output_dir
        )
        os.close(fd)
        temporary_path = Path(temporary_name)
        try:
            if format_name == "tar.gz":
                write_tar_gz(
                    temporary_path, ARTIFACT_NAME, packaged_files, epoch
                )
            else:
                write_zip(temporary_path, ARTIFACT_NAME, packaged_files, epoch)
            verify_archive(
                temporary_path,
                expected_revision=revision,
                allow_incomplete=bool(missing),
                allow_preview=preview,
            )
            os.replace(temporary_path, final_path)
        finally:
            temporary_path.unlink(missing_ok=True)
        completed.append(final_path)

    outer_checksums = "".join(
        f"{sha256(path.read_bytes())}  {path.name}\n" for path in sorted(completed)
    ).encode("utf-8")
    checksum_path = output_dir / CHECKSUMS_NAME
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{CHECKSUMS_NAME}.", dir=output_dir
    )
    os.close(fd)
    temporary_path = Path(temporary_name)
    try:
        temporary_path.write_bytes(outer_checksums)
        os.replace(temporary_path, checksum_path)
    finally:
        temporary_path.unlink(missing_ok=True)

    for path in completed:
        print(f"{sha256(path.read_bytes())}  {path}")
    print(f"checksums: {checksum_path}")
    print(f"source revision: {revision}")


def verify_outer_checksums(path: Path) -> list[Path]:
    checksum_path = path / CHECKSUMS_NAME
    if not checksum_path.is_file():
        raise HandoffError(f"outer checksum file is missing: {checksum_path}")
    checksums = parse_checksums(checksum_path.read_bytes())
    archives: list[Path] = []
    for name, expected in sorted(checksums.items()):
        if PurePosixPath(name).name != name:
            raise HandoffError(f"outer checksum path must be a basename: {name}")
        archive = path / name
        if not archive.is_file():
            raise HandoffError(f"checksummed archive is missing: {archive}")
        actual = sha256(archive.read_bytes())
        if actual != expected:
            raise HandoffError(f"outer checksum mismatch: {archive}")
        archives.append(archive)
    return archives


def verify(repo: Path, args: argparse.Namespace) -> None:
    target = Path(args.target).expanduser().resolve()
    expected = None
    if args.expect_revision:
        expected = git(
            repo, "rev-parse", "--verify", f"{args.expect_revision}^{{commit}}"
        ).decode().strip()
    archives = verify_outer_checksums(target) if target.is_dir() else [target]
    for archive in archives:
        result = verify_archive(
            archive,
            expected_revision=expected,
            allow_incomplete=args.dev_allow_incomplete,
            allow_preview=args.dev_allow_preview,
        )
        qualifier = " INCOMPLETE-DEVELOPMENT" if result["incomplete"] else ""
        if result["releaseMode"] == "preview":
            qualifier += " DEVELOPMENT-PREVIEW-NOT-FOR-PRODUCTION"
        print(
            f"VERIFIED{qualifier} {archive} "
            f"revision={result['revision']} files={result['fileCount']} "
            f"sha256={result['sha256']}"
        )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description=(
            "Build or verify deterministic, source-revision customer handoff archives."
        )
    )
    commands = result.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser(
        "build", help="build deterministic tar.gz and/or ZIP archives"
    )
    build_parser.add_argument("--output-dir", required=True)
    build_parser.add_argument(
        "--format", choices=("tar.gz", "zip", "both"), default="both"
    )
    build_parser.add_argument("--revision", default="HEAD")
    build_parser.add_argument(
        "--mode",
        choices=("release", "preview"),
        default="release",
        help="release runs every production gate; preview is always marked non-production",
    )
    build_parser.add_argument(
        "--dev-allow-dirty",
        action="store_true",
        help=(
            "development only: ignore worktree changes and package the selected "
            "committed revision"
        ),
    )
    build_parser.add_argument(
        "--dev-allow-incomplete",
        action="store_true",
        help=(
            "development only: produce an INCOMPLETE archive when required "
            "tracked inputs are absent"
        ),
    )
    verify_parser = commands.add_parser(
        "verify", help="verify an archive or an output directory"
    )
    verify_parser.add_argument("target")
    verify_parser.add_argument("--expect-revision")
    verify_parser.add_argument(
        "--dev-allow-incomplete",
        action="store_true",
        help="development only: accept an archive marked incomplete",
    )
    verify_parser.add_argument(
        "--dev-allow-preview",
        action="store_true",
        help="development only: accept a preview archive marked non-production",
    )
    return result


def main() -> int:
    args = parser().parse_args(sys.argv[2:])
    repo = Path(sys.argv[1]).resolve()
    try:
        if args.command == "build":
            build(repo, args)
        else:
            verify(repo, args)
    except HandoffError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


raise SystemExit(main())
PY
