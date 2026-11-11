#!/usr/bin/env python3
"""Build the pull-release manifest from a rendered customer image set."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import NoReturn


SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
DIGEST = re.compile(r"^sha256:[a-f0-9]{64}$")
COMMIT = re.compile(r"^[a-f0-9]{40}$")
CHART_PATH = re.compile(r"^[A-Za-z0-9._/-]+$")
VALUES_OVERLAY = "release-images.values.yaml"
APPROVED_IMAGE_STATUSES = {"approved", "customer-ready"}


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def normalized_digest_ref(value: str) -> str:
    """Return repository@digest, dropping an optional tag before the digest."""
    if value.count("@") != 1:
        fail(f"image is not pinned by one digest: {value}")
    name, digest = value.split("@", 1)
    if not DIGEST.fullmatch(digest):
        fail(f"image does not use a lowercase sha256 digest: {value}")
    if not name or any(character.isspace() for character in name):
        fail(f"invalid image repository: {value}")
    slash = name.rfind("/")
    colon = name.rfind(":")
    if colon > slash:
        name = name[:colon]
    if not name:
        fail(f"invalid image repository: {value}")
    return f"{name}@{digest}"


def load_inventory(path: pathlib.Path) -> dict[str, tuple[str, str]]:
    by_ref: dict[str, tuple[str, str]] = {}
    names: set[str] = set()
    with path.open(encoding="utf-8") as stream:
        for line_number, raw in enumerate(stream, start=1):
            line = raw.rstrip("\n")
            if not line:
                continue
            fields = line.split("\t")
            if len(fields) != 4:
                fail(
                    f"{path}:{line_number}: expected name, repository, digest, "
                    "approval TSV"
                )
            name, repository, digest, approval = fields
            if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", name):
                fail(f"{path}:{line_number}: invalid image name: {name}")
            ref = normalized_digest_ref(f"{repository}@{digest}")
            if name in names:
                fail(f"{path}:{line_number}: duplicate image name: {name}")
            if ref in by_ref:
                fail(f"{path}:{line_number}: duplicate inventory ref: {ref}")
            names.add(name)
            by_ref[ref] = (name, approval)
    if not by_ref:
        fail(f"{path}: inventory is empty")
    return by_ref


def load_rendered_refs(path: pathlib.Path) -> list[str]:
    refs: set[str] = set()
    with path.open(encoding="utf-8") as stream:
        for line_number, raw in enumerate(stream, start=1):
            value = raw.strip()
            if not value:
                continue
            try:
                refs.add(normalized_digest_ref(value))
            except ValueError as error:
                fail(f"{path}:{line_number}: {error}")
    if not refs:
        fail(f"{path}: rendered customer pack contains no images")
    return sorted(refs)


def build(args: argparse.Namespace) -> dict[str, object]:
    if not SEMVER.fullmatch(args.version):
        fail("version must be stable SemVer")
    if not COMMIT.fullmatch(args.infra_commit):
        fail("infraCommit must be a full lowercase Git commit")
    if not CHART_PATH.fullmatch(args.chart_path) or args.chart_path.startswith("/"):
        fail("chart path must be a relative repository path")
    if not SEMVER.fullmatch(args.chart_version):
        fail("chart version must be stable SemVer")

    inventory = load_inventory(args.inventory)
    images = []
    for ref in load_rendered_refs(args.images):
        entry = inventory.get(ref)
        if entry is None:
            fail(f"rendered customer image is absent from the inventory: {ref}")
        name, approval = entry
        if approval not in APPROVED_IMAGE_STATUSES:
            fail(
                f"rendered customer image is not release-approved ({approval}): {ref}"
            )
        images.append({"name": name, "ref": ref})
    images.sort(key=lambda image: (image["name"], image["ref"]))

    return {
        "schema": 1,
        "version": args.version,
        "infraCommit": args.infra_commit,
        "chart": {"path": args.chart_path, "version": args.chart_version},
        "valuesOverlay": VALUES_OVERLAY,
        "images": images,
    }


def build_values_overlay(manifest: dict[str, object]) -> str:
    """Render the final image value keys consumed by the customer pack."""
    images = {image["name"]: image["ref"] for image in manifest["images"]}
    required = {
        "relaycast",
        "relayauth",
        "sessions-pipeline",
        "relayhistory",
        "relay-control",
        "relay-webapp",
        "sessions-migration-postgresql",
    }
    missing = sorted(required - images.keys())
    if missing:
        fail("customer pack is missing overlay images: " + ", ".join(missing))

    def pair(name: str, indent: int) -> list[str]:
        repository, digest = images[name].split("@", 1)
        spaces = " " * indent
        return [
            f"{spaces}repository: __IMAGE_MIRROR_ROOT__/{repository}",
            f"{spaces}digest: {digest}",
        ]

    postgres_repository, postgres_digest = images[
        "sessions-migration-postgresql"
    ].split("@", 1)
    postgres_ref = (
        f"__IMAGE_MIRROR_ROOT__/{postgres_repository}@{postgres_digest}"
    )
    lines = [
        "# Generated release asset. Replace only __IMAGE_MIRROR_ROOT__ with the",
        "# customer ECR mirror root, then pass this after the customer's values.",
        "relaycast:",
        "  image:",
        *pair("relaycast", 4),
        "  runtime:",
        "    postgres:",
        "      image:",
        *pair("relaycast", 8),
        "relayauth:",
        "  image:",
        *pair("relayauth", 4),
        "sessions-pipeline:",
        "  privilegedSql:",
        "    sqlImage:",
        *pair("sessions-pipeline", 6),
        "  searchWorkerRole:",
        "    bootstrapJob:",
        "      sqlImage:",
        *pair("sessions-pipeline", 8),
        "  runtimeRole:",
        "    bootstrapJob:",
        "      sqlImage:",
        *pair("sessions-pipeline", 8),
        "  functionDefaultRevoke:",
        "    bootstrapJob:",
        "      sqlImage:",
        *pair("sessions-pipeline", 8),
        "  worker:",
        "    image:",
        *pair("sessions-pipeline", 6),
        "    migrations:",
        "      waitForRole:",
        f"        image: {postgres_ref}",
        "  alleyoop:",
        "    image:",
        *pair("sessions-pipeline", 6),
        "  sessionReadApi:",
        "    image:",
        *pair("sessions-pipeline", 6),
        "  searchIndexer:",
        "    image:",
        *pair("sessions-pipeline", 6),
        "  ingestEdge:",
        "    image:",
        *pair("sessions-pipeline", 6),
        "  nativeConsumer:",
        "    image:",
        *pair("sessions-pipeline", 6),
        "  hoopdb:",
        "    cluster:",
        f"      imageName: {postgres_ref}",
        "relayhistory:",
        "  image:",
        *pair("relayhistory", 4),
        "relay-control:",
        "  image:",
        *pair("relay-control", 4),
        "relay-webapp:",
        "  image:",
        *pair("relay-webapp", 4),
    ]
    return "\n".join(lines) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--infra-commit", required=True)
    parser.add_argument("--chart-path", required=True)
    parser.add_argument("--chart-version", required=True)
    parser.add_argument("--images", type=pathlib.Path, required=True)
    parser.add_argument("--inventory", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--values-overlay-output", type=pathlib.Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        manifest = build(args)
        overlay = build_values_overlay(manifest)
    except (OSError, ValueError) as error:
        print(f"build-agent-relay-release-manifest: {error}", file=sys.stderr)
        return 1
    args.output.write_text(
        json.dumps(manifest, indent=2, sort_keys=False) + "\n", encoding="utf-8"
    )
    args.values_overlay_output.write_text(overlay, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
