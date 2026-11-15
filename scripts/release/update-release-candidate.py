#!/usr/bin/env python3
"""Maintain the immutable image overlay for an Agent Relay release candidate."""

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
RUN_ID = re.compile(r"^[1-9][0-9]{0,19}$")
ALLOWED_SCRUBBER = re.compile(r"^0\.5\.0-alpha\.(5|[89]|[1-9][0-9]+)$")
MARKER_START = "<!-- release-candidate-pins:start -->"
MARKER_END = "<!-- release-candidate-pins:end -->"
FROZEN_MARKER = "qualified-candidate/v1\n"

# This is deliberately an allowlist. A dispatch payload can select a known
# component, digest and source commit; it cannot select a registry, repository,
# workflow or file path.
COMPONENTS = {
    "relay-control": {
        "imageRepository": "ghcr.io/agentworkforce/relay-control",
        "sourceRepository": "AgentWorkforce/relay-control",
        "signerWorkflow": ".github/workflows/release-relay-control-image.yml",
    },
    "relay-webapp": {
        "imageRepository": "ghcr.io/agentworkforce/relay-webapp",
        "sourceRepository": "AgentWorkforce/relay-web",
        "signerWorkflow": ".github/workflows/container.yml",
    },
    "sessions-pipeline": {
        "imageRepository": "ghcr.io/agentworkforce/sessions-pipeline",
        "sourceRepository": "AgentWorkforce/relayhistory-pipeline",
        "signerWorkflow": ".github/workflows/publish-image.yml",
    },
}


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def validate_version(version: str) -> None:
    if not SEMVER.fullmatch(version):
        fail("version must be stable SemVer without a prefix or prerelease")


def validate_pin(component: str, digest: str, source_sha: str) -> None:
    if component not in COMPONENTS:
        fail(f"unsupported component: {component}")
    if not DIGEST.fullmatch(digest):
        fail("digest must be lowercase sha256:<64 hex>")
    if not COMMIT.fullmatch(source_sha):
        fail("source_sha must be a full lowercase Git commit")


def check_policy(
    blocked_path: pathlib.Path,
    component: str,
    digest: str,
    source_sha: str,
    scrub_pin_path: pathlib.Path | None = None,
) -> None:
    validate_pin(component, digest, source_sha)
    policy = json.loads(blocked_path.read_text(encoding="utf-8"))
    if not isinstance(policy, dict) or set(policy) != {"schema", "blocked"}:
        fail(f"{blocked_path}: malformed blocked-image policy")
    if policy["schema"] != 1 or not isinstance(policy["blocked"], dict):
        fail(f"{blocked_path}: unsupported blocked-image policy")
    unknown = set(policy["blocked"]) - set(COMPONENTS)
    if unknown:
        fail(f"{blocked_path}: unknown blocked components: {', '.join(sorted(unknown))}")
    blocked = policy["blocked"].get(component, {})
    if not isinstance(blocked, dict):
        fail(f"{blocked_path}: blocked digests for {component} must be an object")
    for blocked_digest, reason in blocked.items():
        if not DIGEST.fullmatch(blocked_digest) or not isinstance(reason, str) or not reason:
            fail(f"{blocked_path}: malformed blocked digest for {component}")
    if digest in blocked:
        fail(f"blocked image digest for {component}: {blocked[digest]}")

    if component != "sessions-pipeline":
        if scrub_pin_path is not None:
            fail("scrub-bindgen pin applies only to sessions-pipeline")
        return
    if scrub_pin_path is None:
        fail("sessions-pipeline requires scrub-bindgen-pin.json from the exact source")
    scrub_pin = json.loads(scrub_pin_path.read_text(encoding="utf-8"))
    if not isinstance(scrub_pin, dict):
        fail(f"{scrub_pin_path}: scrub pin must be an object")
    package_version = scrub_pin.get("package_version")
    manifest = scrub_pin.get("manifest")
    crate_version = manifest.get("crateVersion") if isinstance(manifest, dict) else None
    if not isinstance(package_version, str) or not ALLOWED_SCRUBBER.fullmatch(package_version):
        fail(f"disallowed relayscrubber version: {package_version}")
    if crate_version != package_version:
        fail("scrub pin package_version and manifest.crateVersion differ")


def candidate_dir(root: pathlib.Path, version: str) -> pathlib.Path:
    validate_version(version)
    return root / "releases" / f"agent-relay-{version}"


def frozen(path: pathlib.Path) -> bool:
    if not path.exists() and not path.is_symlink():
        return False
    if path.is_symlink() or not path.is_file():
        fail(f"{path}: FROZEN marker must be a regular file")
    if path.read_bytes() != FROZEN_MARKER.encode("utf-8"):
        fail(f"{path}: malformed FROZEN marker")
    return True


def load_pins(
    path: pathlib.Path,
    version: str,
    allow_legacy_sessions: bool = False,
) -> dict[str, object]:
    if not path.exists():
        return {"schema": 1, "version": version, "pins": {}}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or set(data) != {"schema", "version", "pins"}:
        fail(f"{path}: expected only schema, version and pins")
    if data["schema"] != 1 or data["version"] != version:
        fail(f"{path}: candidate schema or version mismatch")
    pins = data["pins"]
    if not isinstance(pins, dict):
        fail(f"{path}: pins must be an object")
    for component, pin in pins.items():
        if component not in COMPONENTS or not isinstance(pin, dict):
            fail(f"{path}: unsupported pin: {component}")
        base_fields = {"repository", "digest", "sourceRepository", "sourceRevision"}
        expected = set(base_fields)
        if component == "sessions-pipeline":
            expected.add("publishRunId")
        legacy_sessions = (
            component == "sessions-pipeline"
            and allow_legacy_sessions
            and set(pin) == base_fields
        )
        if set(pin) != expected and not legacy_sessions:
            fail(f"{path}: malformed pin: {component}")
        metadata = COMPONENTS[component]
        if pin["repository"] != metadata["imageRepository"]:
            fail(f"{path}: repository drift for {component}")
        if pin["sourceRepository"] != metadata["sourceRepository"]:
            fail(f"{path}: source repository drift for {component}")
        validate_pin(component, pin["digest"], pin["sourceRevision"])
        if component == "sessions-pipeline" and not legacy_sessions and (
            not isinstance(pin["publishRunId"], int)
            or isinstance(pin["publishRunId"], bool)
            or not RUN_ID.fullmatch(str(pin["publishRunId"]))
        ):
            fail(f"{path}: sessions-pipeline publishRunId must be a positive run id")
    return data


def image_pair(pin: dict[str, str], indent: int) -> list[str]:
    spaces = " " * indent
    return [
        f"{spaces}repository: {pin['repository']}",
        f"{spaces}digest: {pin['digest']}",
    ]


def render_values(data: dict[str, object]) -> str:
    pins = data["pins"]
    lines = [
        "# Generated by scripts/release/update-release-candidate.py.",
        f"# Candidate agent-relay-{data['version']}; apply after the base profile.",
        "# Do not hand-edit: pins.json is the provenance-bound source of truth.",
    ]
    sessions = pins.get("sessions-pipeline")
    if sessions:
        lines += [
            "sessions-pipeline:",
            "  privilegedSql:",
            "    sqlImage:",
            *image_pair(sessions, 6),
            "  searchWorkerRole:",
            "    bootstrapJob:",
            "      sqlImage:",
            *image_pair(sessions, 8),
            "  runtimeRole:",
            "    bootstrapJob:",
            "      sqlImage:",
            *image_pair(sessions, 8),
            "  functionDefaultRevoke:",
            "    bootstrapJob:",
            "      sqlImage:",
            *image_pair(sessions, 8),
            "  worker:",
            "    image:",
            *image_pair(sessions, 6),
            "  alleyoop:",
            "    image:",
            *image_pair(sessions, 6),
            "  sessionReadApi:",
            "    image:",
            *image_pair(sessions, 6),
            "  searchIndexer:",
            "    image:",
            *image_pair(sessions, 6),
            "  ingestEdge:",
            "    image:",
            *image_pair(sessions, 6),
            "  nativeConsumer:",
            "    image:",
            *image_pair(sessions, 6),
        ]
    for component in ("relay-control", "relay-webapp"):
        pin = pins.get(component)
        if pin:
            lines += [f"{component}:", "  image:", *image_pair(pin, 4)]
    return "\n".join(lines) + "\n"


def validate_candidate(pins_path: pathlib.Path, values_path: pathlib.Path, version: str) -> dict[str, object]:
    data = load_pins(pins_path, version)
    if values_path.read_bytes() != render_values(data).encode("utf-8"):
        fail(f"{values_path}: values overlay does not match the provenance ledger")
    return data


def update(
    root: pathlib.Path,
    version: str,
    component: str,
    digest: str,
    source_sha: str,
    publish_run_id: int | None = None,
    allow_frozen: bool = False,
) -> pathlib.Path:
    validate_version(version)
    validate_pin(component, digest, source_sha)
    if component == "sessions-pipeline":
        if (
            not isinstance(publish_run_id, int)
            or isinstance(publish_run_id, bool)
            or not RUN_ID.fullmatch(str(publish_run_id))
        ):
            fail("sessions-pipeline requires a positive publish_run_id")
    elif publish_run_id is not None:
        fail("publish_run_id applies only to sessions-pipeline")
    directory = candidate_dir(root, version)
    is_frozen = frozen(directory / "FROZEN")
    if is_frozen and not allow_frozen:
        fail(f"agent-relay-{version} is FROZEN as a qualified candidate")
    if allow_frozen and not is_frozen:
        fail("allow_frozen requires an existing qualified-candidate FROZEN marker")
    pins_path = directory / "pins.json"
    # The first Sessions dispatch after this field was introduced must be able
    # to migrate an already-open candidate. All validation and tag paths remain
    # strict, and the update below immediately writes the provenance-bound id.
    data = load_pins(
        pins_path,
        version,
        allow_legacy_sessions=component == "sessions-pipeline",
    )
    metadata = COMPONENTS[component]
    pin = {
        "repository": metadata["imageRepository"],
        "digest": digest,
        "sourceRepository": metadata["sourceRepository"],
        "sourceRevision": source_sha,
    }
    if component == "sessions-pipeline":
        pin["publishRunId"] = publish_run_id
    data["pins"][component] = pin
    data["pins"] = dict(sorted(data["pins"].items()))
    directory.mkdir(parents=True, exist_ok=True)
    pins_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    (directory / "values.yaml").write_text(render_values(data), encoding="utf-8")
    return directory


def pins_table(data: dict[str, object]) -> str:
    rows = [
        MARKER_START,
        "## Verified candidate pins",
        "",
        "| Component | Immutable image | Provenance source |",
        "| --- | --- | --- |",
    ]
    for component, pin in data["pins"].items():
        rows.append(
            f"| `{component}` | `{pin['repository']}@{pin['digest']}` | "
            f"`{pin['sourceRepository']}@{pin['sourceRevision']}`"
            + (
                f" (publish run `{pin['publishRunId']}`)"
                if component == "sessions-pipeline"
                else ""
            )
            + " |"
        )
    rows += ["", "Updated only after component provenance verification.", MARKER_END]
    return "\n".join(rows)


def render_body(body: str, data: dict[str, object]) -> str:
    table = pins_table(data)
    if MARKER_START in body or MARKER_END in body:
        if body.count(MARKER_START) != 1 or body.count(MARKER_END) != 1:
            fail("PR body has malformed release-candidate markers")
        start = body.index(MARKER_START)
        end = body.index(MARKER_END, start) + len(MARKER_END)
        body = body[:start].rstrip() + "\n\n" + table + body[end:]
    else:
        body = body.rstrip() + "\n\n" + table
    return body.strip() + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    describe = subparsers.add_parser("describe")
    describe.add_argument("--component", required=True)

    policy_parser = subparsers.add_parser("check-policy")
    policy_parser.add_argument("--blocked", type=pathlib.Path, required=True)
    policy_parser.add_argument("--component", required=True)
    policy_parser.add_argument("--digest", required=True)
    policy_parser.add_argument("--source-sha", required=True)
    policy_parser.add_argument("--scrub-pin", type=pathlib.Path)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--pins", type=pathlib.Path, required=True)
    validate_parser.add_argument("--values", type=pathlib.Path)
    validate_parser.add_argument("--version", required=True)

    frozen_parser = subparsers.add_parser("check-frozen")
    frozen_parser.add_argument("--path", type=pathlib.Path, required=True)

    update_parser = subparsers.add_parser("update")
    update_parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    update_parser.add_argument("--version", required=True)
    update_parser.add_argument("--component", required=True)
    update_parser.add_argument("--digest", required=True)
    update_parser.add_argument("--source-sha", required=True)
    update_parser.add_argument("--publish-run-id", type=int)
    update_parser.add_argument("--allow-frozen", action="store_true")

    body_parser = subparsers.add_parser("render-body")
    body_parser.add_argument("--pins", type=pathlib.Path, required=True)
    body_parser.add_argument("--body", type=pathlib.Path, required=True)
    body_parser.add_argument("--output", type=pathlib.Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "describe":
            if args.component not in COMPONENTS:
                fail(f"unsupported component: {args.component}")
            print(json.dumps(COMPONENTS[args.component], sort_keys=True))
        elif args.command == "check-policy":
            check_policy(
                args.blocked,
                args.component,
                args.digest,
                args.source_sha,
                args.scrub_pin,
            )
        elif args.command == "validate":
            if args.values is None:
                load_pins(args.pins, args.version)
            else:
                validate_candidate(args.pins, args.values, args.version)
        elif args.command == "check-frozen":
            print("true" if frozen(args.path) else "false")
        elif args.command == "update":
            directory = update(
                args.root,
                args.version,
                args.component,
                args.digest,
                args.source_sha,
                args.publish_run_id,
                args.allow_frozen,
            )
            print(directory)
        else:
            data = load_pins(args.pins, json.loads(args.pins.read_text())["version"])
            body = args.body.read_text(encoding="utf-8")
            args.output.write_text(render_body(body, data), encoding="utf-8")
    except (OSError, ValueError, json.JSONDecodeError, KeyError, TypeError) as error:
        print(f"update-release-candidate: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
