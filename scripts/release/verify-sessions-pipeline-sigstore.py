#!/usr/bin/env python3
"""Verify the relayhistory-pipeline release-receipt Sigstore artifact."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import pathlib
import re
import subprocess
import sys
from typing import NoReturn


DIGEST = re.compile(r"^sha256:([a-f0-9]{64})$")
COMMIT = re.compile(r"^[a-f0-9]{40}$")
RUN_ID = re.compile(r"^[1-9][0-9]{0,19}$")
REPOSITORY = "https://github.com/AgentWorkforce/relayhistory-pipeline"
SOURCE_REF = "refs/heads/main"
WORKFLOW = ".github/workflows/publish-image.yml"
IDENTITY_REGEXP = (
    r"^https://github.com/AgentWorkforce/relayhistory-pipeline/"
    r"\.github/workflows/publish-image\.yml@refs/heads/main$"
)
ISSUER = "https://token.actions.githubusercontent.com"
IMAGE_REPOSITORIES = (
    "ghcr.io/agentworkforce/sessions-pipeline",
    "ghcr.io/agentworkforce/96bulls-services",
)
FILES = {
    "services-index.json": 1024 * 1024,
    "release-receipt.json": 1024 * 1024,
    "build-provenance.sigstore.json": 4 * 1024 * 1024,
    "reviewed-source.sigstore.json": 4 * 1024 * 1024,
}
BUILD_TYPE = "https://slsa.dev/provenance/v1"
SOURCE_TYPE = "https://agentrelay.com/attestations/reviewed-image-source/v1"


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def read_json(path: pathlib.Path) -> object:
    if path.is_symlink() or not path.is_file():
        fail(f"{path}: expected a regular file")
    size = path.stat().st_size
    if size <= 0 or size > FILES[path.name]:
        fail(f"{path}: invalid file size")
    return json.loads(path.read_text(encoding="utf-8"))


def statement(bundle: object, path: pathlib.Path) -> dict[str, object]:
    if not isinstance(bundle, dict):
        fail(f"{path}: bundle must be an object")
    envelope = bundle.get("dsseEnvelope")
    if not isinstance(envelope, dict) or not isinstance(envelope.get("payload"), str):
        fail(f"{path}: missing DSSE payload")
    try:
        decoded = base64.b64decode(envelope["payload"], validate=True)
        value = json.loads(decoded)
    except (ValueError, json.JSONDecodeError) as error:
        fail(f"{path}: invalid DSSE payload: {error}")
    if not isinstance(value, dict):
        fail(f"{path}: statement must be an object")
    return value


def check_subject(value: dict[str, object], digest_hex: str, path: pathlib.Path) -> None:
    expected = [{"name": "services-index.json", "digest": {"sha256": digest_hex}}]
    if value.get("_type") != "https://in-toto.io/Statement/v0.1":
        fail(f"{path}: unexpected statement type")
    if value.get("subject") != expected:
        fail(f"{path}: subject does not match the pinned image digest")


def run_cosign(receipt_dir: pathlib.Path) -> None:
    index = receipt_dir / "services-index.json"
    for bundle, predicate_type in (
        ("build-provenance.sigstore.json", "slsaprovenance1"),
        ("reviewed-source.sigstore.json", SOURCE_TYPE),
    ):
        subprocess.run(
            [
                "cosign",
                "verify-blob-attestation",
                "--new-bundle-format",
                "--type",
                predicate_type,
                "--bundle",
                str(receipt_dir / bundle),
                "--certificate-oidc-issuer",
                ISSUER,
                "--certificate-identity-regexp",
                IDENTITY_REGEXP,
                str(index),
            ],
            check=True,
        )


def verify(receipt_dir: pathlib.Path, digest: str, source_sha: str, publish_run_id: str) -> None:
    match = DIGEST.fullmatch(digest)
    if not match:
        fail("digest must be lowercase sha256:<64 hex>")
    if not COMMIT.fullmatch(source_sha):
        fail("source_sha must be a full lowercase Git commit")
    if not RUN_ID.fullmatch(publish_run_id):
        fail("publish_run_id must be a positive run id")
    if receipt_dir.is_symlink() or not receipt_dir.is_dir():
        fail(f"{receipt_dir}: expected a receipt directory")
    actual_files = {entry.name for entry in receipt_dir.iterdir() if entry.is_file()}
    if actual_files != set(FILES) or any(entry.is_dir() for entry in receipt_dir.iterdir()):
        fail(f"{receipt_dir}: expected exactly the four release-receipt files")

    values = {name: read_json(receipt_dir / name) for name in FILES}
    index_bytes = (receipt_dir / "services-index.json").read_bytes()
    if hashlib.sha256(index_bytes).hexdigest() != match.group(1):
        fail("services-index.json sha256 does not match the pinned digest")

    pinned_images = [f"{repository}@{digest}" for repository in IMAGE_REPOSITORIES]
    receipt = values["release-receipt.json"]
    if not isinstance(receipt, dict):
        fail("release-receipt.json must be an object")
    expected_receipt = {
        "repository": REPOSITORY,
        "image": pinned_images[0],
        "images": pinned_images,
        "source_sha": source_sha,
        "source_ref": SOURCE_REF,
        "attestation_backend": "sigstore",
        "publish_run_id": publish_run_id,
    }
    for key, expected in expected_receipt.items():
        if receipt.get(key) != expected:
            fail(f"release-receipt.json {key} does not match the candidate pin")
    workflow_sha = receipt.get("workflow_sha")
    attempt = receipt.get("publish_run_attempt")
    ci_run_id = receipt.get("ci_run_id")
    if not isinstance(workflow_sha, str) or not COMMIT.fullmatch(workflow_sha):
        fail("release-receipt.json has an invalid workflow_sha")
    if not isinstance(attempt, str) or not RUN_ID.fullmatch(attempt):
        fail("release-receipt.json has an invalid publish_run_attempt")
    if not isinstance(ci_run_id, str) or not RUN_ID.fullmatch(ci_run_id):
        fail("release-receipt.json has an invalid ci_run_id")

    run_cosign(receipt_dir)

    build_path = receipt_dir / "build-provenance.sigstore.json"
    build = statement(values[build_path.name], build_path)
    check_subject(build, match.group(1), build_path)
    if build.get("predicateType") != BUILD_TYPE:
        fail(f"{build_path}: unexpected predicate type")
    build_predicate = build.get("predicate")
    if not isinstance(build_predicate, dict):
        fail(f"{build_path}: missing predicate")
    definition = build_predicate.get("buildDefinition")
    run_details = build_predicate.get("runDetails")
    if not isinstance(definition, dict) or not isinstance(run_details, dict):
        fail(f"{build_path}: malformed SLSA predicate")
    expected_parameters = {
        "image": IMAGE_REPOSITORIES[0],
        "images": list(IMAGE_REPOSITORIES),
        "repository": REPOSITORY,
        "source_ref": SOURCE_REF,
        "source_sha": source_sha,
    }
    if definition.get("buildType") != "https://agentrelay.com/builders/services-image/v1":
        fail(f"{build_path}: unexpected build type")
    if definition.get("externalParameters") != expected_parameters:
        fail(f"{build_path}: external parameters do not match the candidate pin")
    dependency = {
        "digest": {"gitCommit": source_sha},
        "uri": f"git+{REPOSITORY}",
    }
    if definition.get("resolvedDependencies") != [dependency]:
        fail(f"{build_path}: source dependency does not match the candidate pin")
    builder = run_details.get("builder")
    metadata = run_details.get("metadata")
    if not isinstance(builder, dict) or builder.get("id") != (
        f"{REPOSITORY}/{WORKFLOW}@{workflow_sha}"
    ):
        fail(f"{build_path}: builder identity does not match the receipt")
    expected_invocation = (
        f"{REPOSITORY}/actions/runs/{publish_run_id}/attempts/{attempt}"
    )
    if not isinstance(metadata, dict) or metadata.get("invocationId") != expected_invocation:
        fail(f"{build_path}: invocation does not match the publish run")

    source_path = receipt_dir / "reviewed-source.sigstore.json"
    source = statement(values[source_path.name], source_path)
    check_subject(source, match.group(1), source_path)
    if source.get("predicateType") != SOURCE_TYPE:
        fail(f"{source_path}: unexpected predicate type")
    expected_source = {
        "ci_run_id": ci_run_id,
        "image": pinned_images[0],
        "images": pinned_images,
        "repository": REPOSITORY,
        "source_ref": SOURCE_REF,
        "source_sha": source_sha,
        "workflow_sha": workflow_sha,
    }
    if source.get("predicate") != expected_source:
        fail(f"{source_path}: reviewed source does not match the candidate pin")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt-dir", type=pathlib.Path, required=True)
    parser.add_argument("--digest", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--publish-run-id", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        verify(args.receipt_dir, args.digest, args.source_sha, args.publish_run_id)
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"verify-sessions-pipeline-sigstore: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
