#!/usr/bin/env python3
"""Build a deterministic, customer-neutral Agent Relay AWS install pack."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import pathlib
import re
import tarfile
import sys


SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def checked_bytes(path: pathlib.Path) -> bytes:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"install-pack input must be a regular file: {path}")
    content = path.read_bytes()
    if not content:
        raise ValueError(f"install-pack input is empty: {path}")
    return content


def build(args: argparse.Namespace) -> None:
    if not SEMVER.fullmatch(args.version):
        raise ValueError("version must be stable SemVer")
    inputs = {
        "candidate-pins.json": args.candidate_pins,
        "overlay.yaml": args.platform_overlay,
        "release-images.values.yaml": args.image_overlay,
        "release-manifest.json": args.manifest,
        "values.yaml": args.base_values,
    }
    payload = {name: checked_bytes(path) for name, path in inputs.items()}
    manifest = json.loads(payload["release-manifest.json"])
    pins = json.loads(payload["candidate-pins.json"])
    if manifest.get("version") != args.version or pins.get("version") != args.version:
        raise ValueError("install-pack version does not match manifest and candidate pins")
    expected_pin_sha = manifest.get("candidatePins", {}).get("sha256")
    actual_pin_sha = hashlib.sha256(payload["candidate-pins.json"]).hexdigest()
    if expected_pin_sha != actual_pin_sha:
        raise ValueError("manifest candidatePins checksum does not match candidate-pins.json")

    checksums = "".join(
        f"{hashlib.sha256(payload[name]).hexdigest()}  {name}\n"
        for name in sorted(payload)
    ).encode()
    payload["SHA256SUMS"] = checksums

    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for name in sorted(payload):
            content = payload[name]
            info = tarfile.TarInfo(name)
            info.size = len(content)
            info.mode = 0o644
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            archive.addfile(info, io.BytesIO(content))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("wb") as stream:
        with gzip.GzipFile(fileobj=stream, mode="wb", filename="", mtime=0) as zipped:
            zipped.write(tar_buffer.getvalue())


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--base-values", type=pathlib.Path, required=True)
    parser.add_argument("--platform-overlay", type=pathlib.Path, required=True)
    parser.add_argument("--image-overlay", type=pathlib.Path, required=True)
    parser.add_argument("--manifest", type=pathlib.Path, required=True)
    parser.add_argument("--candidate-pins", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    return parser.parse_args()


def main() -> int:
    try:
        build(parse_args())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"build-agent-relay-install-pack: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
