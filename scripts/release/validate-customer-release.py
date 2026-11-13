#!/usr/bin/env python3
"""Fail-closed production gate for the Agent Relay customer bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
REVISION = re.compile(r"^[0-9a-f]{40,64}$")
APPROVED_LICENSES = {"approved", "approved-upstream"}
APPROVED_ACQUISITION = {
    "available-public",
    "approved-entitlement",
    "promoted-customer-registry",
}
APPROVED_IMAGE = {"approved", "customer-ready"}
ZERO_DIGEST = "sha256:" + ("0" * 64)
# Closed vocabularies shared with self-hosted/customer-images.yaml. Anything
# else is a manifest error (checked in --consistency mode and on release).
IMAGE_APPROVAL_STATUSES = APPROVED_IMAGE | {"blocked", "provenance-review-required"}
PLATFORM_STATUSES = {"verified", "unverified"}
LICENSE_STATUSES = APPROVED_LICENSES | {"blocked", "review-required"}
ACQUISITION_STATUSES = APPROVED_ACQUISITION | {
    "blocked",
    "available-public-review-required",
}
# Source repositories must be exact GitHub repositories from a reviewed
# organisation. The organisation decides whether an image is first-party
# (and so needs a first-party license decision); the manifest's firstParty
# flag must agree. Adding an upstream organisation is a reviewed gate change.
SOURCE_REPOSITORY = re.compile(
    r"^https://github\.com/(?P<org>[A-Za-z0-9][A-Za-z0-9-]*)/[A-Za-z0-9._-]+$"
)
SOURCE_ORGS = {"agentworkforce": True, "cloudnative-pg": False}
REQUIRED_IMAGE_PLATFORMS = {"linux/amd64", "linux/arm64"}
DESKTOP_PLATFORMS = {
    "darwin/amd64",
    "darwin/arm64",
    "linux/amd64",
    "linux/arm64",
}
PROOF_OR_PRIVATE = re.compile(
    r"(?:^|[./_-])(proof|conformance)(?:[./_-]|$)|"
    r"(?:^|[./_-])private(?:[./_-]|$)|<|>",
    re.IGNORECASE,
)
PLACEHOLDER = re.compile(
    r"(?:^|[./_-])(example|placeholder|changeme|change-me|replace-me|todo)"
    r"(?:[./_-]|$)",
    re.IGNORECASE,
)
IMAGE_REF = re.compile(
    r"^(?P<repository>[^@\s]+?)(?::(?P<tag>[A-Za-z0-9_][A-Za-z0-9._-]{0,127}))?"
    r"(?:@(?P<digest>sha256:[0-9a-f]{64}))?$"
)
HOOK = re.compile(r"""["']?helm\.sh/hook["']?\s*:\s*["']?([^"'\s#}]+)""")


class Gate:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def reject(self, category: str, detail: str) -> None:
        self.errors.append(f"{category}: {detail}")

    def require(self, condition: bool, category: str, detail: str) -> None:
        if not condition:
            self.reject(category, detail)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_json(path: Path, gate: Gate, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        gate.reject("schema", f"cannot read {label} {path}: {exc}")
        return {}


def load_yaml(path: Path, gate: Gate) -> Any:
    try:
        process = subprocess.run(
            ("yq", "-o=json", "explode(.)", str(path)),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return json.loads(process.stdout)
    except FileNotFoundError:
        gate.reject("schema", "yq v4 is required to read customer-images.yaml")
    except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        detail = (
            exc.stderr.strip()
            if isinstance(exc, subprocess.CalledProcessError)
            else str(exc)
        )
        gate.reject("schema", f"cannot parse {path}: {detail}")
    return {}


def mapping(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def sequence(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def text(value: Any) -> str:
    return value if isinstance(value, str) else ""


def safe_input(root: Path, value: str, gate: Gate, label: str) -> Path:
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = root / candidate
    try:
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(root)
    except (OSError, ValueError):
        gate.reject("schema", f"{label} must be an existing path beneath {root}")
        return candidate
    if "dist" in resolved.relative_to(root).parts:
        gate.reject("schema", f"{label} may not use dist/")
    return resolved


def validate_evidence_shape(evidence: Any, schema: Any, gate: Gate) -> None:
    """Validate the evidence with a real JSON Schema Draft 2020-12 validator,
    including the releaseDecision=approved conditionals. Fails closed when the
    validator is unavailable."""
    e = mapping(evidence)
    s = mapping(schema)
    gate.require(
        s.get("$schema") == "https://json-schema.org/draft/2020-12/schema",
        "schema",
        "release evidence schema must use JSON Schema 2020-12",
    )
    try:
        import jsonschema  # type: ignore[import-untyped]
    except ImportError:
        gate.reject(
            "schema",
            "the jsonschema package (>= 4.18, Draft 2020-12) is required: "
            "python3 -m pip install 'jsonschema>=4.18'",
        )
    else:
        validator_class = jsonschema.Draft202012Validator
        try:
            validator_class.check_schema(s)
        except jsonschema.exceptions.SchemaError as exc:
            gate.reject("schema", f"release evidence schema is invalid: {exc.message}")
        else:
            for error in sorted(
                validator_class(s).iter_errors(evidence),
                key=lambda item: list(item.absolute_path),
            ):
                where = "/".join(str(part) for part in error.absolute_path) or "(root)"
                gate.reject("schema", f"{where}: {error.message}")
    gate.require(e.get("schemaVersion") == 1, "schema", "schemaVersion must be 1")
    for key in (
        "release",
        "licenses",
        "upgradeRestore",
        "desktop",
    ):
        gate.require(
            isinstance(e.get(key), dict),
            "schema",
            f"release evidence {key} must be an object",
        )


def validate_controls(evidence: dict[str, Any], gate: Gate) -> None:
    gate.require(
        evidence.get("releaseDecision") == "approved",
        "release-decision",
        "releaseDecision must be approved",
    )
    release = mapping(evidence.get("release"))
    branch = mapping(release.get("branchControls"))
    gate.require(text(branch.get("branch")) != "", "branch-controls", "branch missing")
    gate.require(branch.get("protected") is True, "branch-controls", "branch not protected")
    gate.require(
        branch.get("requiresPullRequest") is True,
        "branch-controls",
        "pull requests are not required",
    )
    gate.require(
        isinstance(branch.get("requiredApprovals"), int)
        and branch["requiredApprovals"] >= 1,
        "branch-controls",
        "at least one branch approval is required",
    )
    checks = sequence(branch.get("requiredStatusChecks"))
    gate.require(
        "customer-release-gate" in checks,
        "branch-controls",
        "customer-release-gate is not a required status check",
    )
    environment = mapping(release.get("environmentControls"))
    gate.require(
        text(environment.get("name")) != "",
        "environment-controls",
        "release environment missing",
    )
    gate.require(
        environment.get("protected") is True,
        "environment-controls",
        "release environment not protected",
    )
    gate.require(
        isinstance(environment.get("requiredApprovals"), int)
        and environment["requiredApprovals"] >= 1,
        "environment-controls",
        "at least one environment approval is required",
    )
    gate.require(
        environment.get("preventsSelfReview") is True,
        "environment-controls",
        "environment permits self-review",
    )


def validate_license_decisions(
    evidence: dict[str, Any], images: list[Any], gate: Gate
) -> None:
    decisions = {}
    for item in sequence(mapping(evidence.get("licenses")).get("firstParty")):
        row = mapping(item)
        identifier = text(row.get("id"))
        if identifier:
            if identifier in decisions:
                gate.reject("first-party-license", f"duplicate decision for {identifier}")
            decisions[identifier] = row
    required = {"helm-charts"}
    for item in images:
        image = mapping(item)
        # validate_images() rejects any active image whose firstParty flag is
        # not a boolean or disagrees with its allowlisted source organisation;
        # an image that is not explicitly third-party needs a decision here.
        if image.get("active") is True and image.get("firstParty") is not False:
            required.add(text(image.get("id")) or "(unnamed)")
    for identifier in sorted(required):
        row = mapping(decisions.get(identifier))
        gate.require(
            row.get("decision") == "approved"
            and text(row.get("spdx")) != ""
            and text(row.get("evidence")).strip() != "",
            "first-party-license",
            f"{identifier} lacks an approved SPDX license decision and evidence",
        )


def validate_images(manifest: dict[str, Any], gate: Gate) -> list[Any]:
    gate.require(
        manifest.get("apiVersion") == "selfhost.agentrelay.com/v1alpha1"
        and manifest.get("kind") == "CustomerImageSourceManifest",
        "images-manifest",
        "unexpected customer image manifest identity",
    )
    gate.require(
        manifest.get("status") == "ready",
        "hard-blocker",
        "customer-images status is not ready",
    )
    for blocker in sequence(manifest.get("blockers")):
        row = mapping(blocker)
        if row.get("severity") == "hard":
            gate.reject(
                "hard-blocker",
                f"{text(row.get('id')) or '(unnamed)'} remains unresolved",
            )

    images = sequence(manifest.get("images"))
    gate.require(bool(images), "images-manifest", "images list is empty")
    ids: set[str] = set()
    for item in images:
        image = mapping(item)
        if image.get("active") is not True:
            continue
        identifier = text(image.get("id")) or "(unnamed)"
        if identifier in ids:
            gate.reject("images-manifest", f"duplicate active image id {identifier}")
        ids.add(identifier)
        current = mapping(image.get("current"))
        repository = text(current.get("repository"))
        digest = text(current.get("digest"))
        gate.require(
            repository != ""
            and not PROOF_OR_PRIVATE.search(repository)
            and not PLACEHOLDER.search(repository),
            "registry",
            f"{identifier} uses a proof/private/placeholder registry",
        )
        gate.require(
            bool(DIGEST.fullmatch(digest)) and digest != ZERO_DIGEST,
            "mutable-image",
            f"{identifier} lacks a non-zero immutable digest",
        )
        for key, value in current.items():
            if "tag" in key.lower() and value not in (None, ""):
                gate.reject("mutable-image", f"{identifier} supplies mutable {key}")

        source = mapping(image.get("source"))
        gate.require(
            bool(REVISION.fullmatch(text(source.get("revision"))))
            and source.get("reproducibleReference") is True,
            "source-revision",
            f"{identifier} is not tied to a reproducible committed revision",
        )
        source_match = SOURCE_REPOSITORY.fullmatch(text(source.get("repository")))
        org = source_match.group("org").lower() if source_match else ""
        gate.require(
            org in SOURCE_ORGS,
            "source-repository",
            f"{identifier} source.repository must be an allowlisted "
            "https://github.com/<org>/<repo> repository",
        )
        gate.require(
            isinstance(image.get("firstParty"), bool)
            and (org not in SOURCE_ORGS or image.get("firstParty") is SOURCE_ORGS[org]),
            "source-repository",
            f"{identifier} firstParty must be a boolean matching its source organisation",
        )
        license_row = mapping(image.get("license"))
        gate.require(
            license_row.get("status") in APPROVED_LICENSES
            and text(license_row.get("spdx")) != ""
            and text(license_row.get("evidence")) != "",
            "image-license",
            f"{identifier} license is not approved",
        )
        platforms = mapping(image.get("platforms"))
        expected = set(sequence(platforms.get("expected")))
        verified = set(sequence(platforms.get("verifiedFromRegistry")))
        gate.require(
            REQUIRED_IMAGE_PLATFORMS <= expected
            and expected <= verified
            and platforms.get("status") == "verified",
            "image-platforms",
            f"{identifier} required platforms are not registry-verified",
        )
        release = mapping(image.get("release"))
        gate.require(
            text(release.get("workflow")) != ""
            and text(release.get("run")) != ""
            and release.get("buildsCommittedRevision") is True,
            "source-revision",
            f"{identifier} lacks a reviewed committed-revision release run",
        )
        gate.require(
            release.get("publishesSbom") is True,
            "sbom",
            f"{identifier} does not publish an SBOM",
        )
        gate.require(
            release.get("publishesProvenance") is True,
            "provenance",
            f"{identifier} does not publish verifiable provenance",
        )
        acquisition = mapping(image.get("customerAcquisition"))
        gate.require(
            acquisition.get("status") in APPROVED_ACQUISITION
            and text(acquisition.get("procedure")) != "",
            "registry",
            f"{identifier} lacks an approved customer acquisition procedure",
        )
        approval = mapping(image.get("approval"))
        gate.require(
            approval.get("status") in APPROVED_IMAGE
            and sequence(approval.get("blockingReasons")) == [],
            "hard-blocker",
            f"{identifier} is not approved for customer release",
        )
    return images


def validate_manifest_vocabulary(manifest: dict[str, Any], gate: Gate) -> None:
    """customer-images.yaml uses the gate's closed vocabularies, so a record
    that is otherwise ready cannot fail on spelling, and every blocked image
    names a recorded blocker."""
    category = "manifest-vocabulary"
    gate.require(
        manifest.get("status") in ("ready", "blocked"),
        category,
        "status must be ready or blocked",
    )
    blockers: dict[str, dict[str, Any]] = {}
    for item in sequence(manifest.get("blockers")):
        row = mapping(item)
        identifier = text(row.get("id"))
        gate.require(identifier != "", category, "a blocker has no id")
        gate.require(
            row.get("severity") in ("hard", "review"),
            category,
            f"blocker {identifier} severity must be hard or review",
        )
        blockers[identifier] = row
    if any(row.get("severity") == "hard" for row in blockers.values()):
        gate.require(
            manifest.get("status") == "blocked",
            category,
            "status must be blocked while a hard blocker is recorded",
        )
    for item in sequence(manifest.get("images")):
        image = mapping(item)
        identifier = text(image.get("id")) or "(unnamed)"
        gate.require(
            isinstance(image.get("active"), bool),
            category,
            f"{identifier} active must be a boolean",
        )
        if image.get("active") is not True:
            continue
        gate.require(
            isinstance(image.get("firstParty"), bool),
            category,
            f"{identifier} firstParty must be a boolean",
        )
        for key, value in mapping(image.get("current")).items():
            gate.require(
                "tag" not in key.lower(),
                category,
                f"{identifier} current.{key} is not allowed; record published "
                "tags under release.publishedTags",
            )
        checks = (
            ("approval", "status", IMAGE_APPROVAL_STATUSES),
            ("platforms", "status", PLATFORM_STATUSES),
            ("license", "status", LICENSE_STATUSES),
            ("customerAcquisition", "status", ACQUISITION_STATUSES),
        )
        for section, key, allowed in checks:
            value = mapping(image.get(section)).get(key)
            gate.require(
                value in allowed,
                category,
                f"{identifier} {section}.{key} {value!r} is not one of "
                f"{', '.join(sorted(allowed))}",
            )
        release = mapping(image.get("release"))
        for key in ("buildsCommittedRevision", "publishesSbom", "publishesProvenance"):
            gate.require(
                isinstance(release.get(key), bool),
                category,
                f"{identifier} release.{key} must be a boolean",
            )
        gate.require(
            isinstance(mapping(image.get("source")).get("reproducibleReference"), bool),
            category,
            f"{identifier} source.reproducibleReference must be a boolean",
        )
        approval = mapping(image.get("approval"))
        reasons = [text(reason) for reason in sequence(approval.get("blockingReasons"))]
        for reason in reasons:
            gate.require(
                reason in blockers
                and identifier in sequence(blockers[reason].get("images")),
                category,
                f"{identifier} blocking reason {reason} is not a recorded blocker "
                "for this image",
            )
        if approval.get("status") not in APPROVED_IMAGE:
            gate.require(
                bool(reasons),
                category,
                f"{identifier} is not approved but names no blocking reason",
            )
        else:
            gate.require(
                not reasons,
                category,
                f"{identifier} is approved but still names blocking reasons",
            )
    for identifier, row in blockers.items():
        for image_id in sequence(row.get("images")):
            image = next(
                (
                    mapping(x)
                    for x in sequence(manifest.get("images"))
                    if mapping(x).get("id") == image_id
                ),
                {},
            )
            gate.require(
                identifier in sequence(mapping(image.get("approval")).get("blockingReasons")),
                category,
                f"blocker {identifier} names {image_id}, which does not list it",
            )


def walk_image_values(value: Any, location: str = "$") -> list[tuple[str, dict[str, Any]]]:
    found: list[tuple[str, dict[str, Any]]] = []
    if isinstance(value, dict):
        if "repository" in value:
            found.append((location, value))
        for key, child in value.items():
            found.extend(walk_image_values(child, f"{location}.{key}"))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found.extend(walk_image_values(child, f"{location}[{index}]"))
    return found


def validate_values(values: Any, gate: Gate) -> None:
    """Values-level hygiene: no explicit mutable tags in the release values.
    Which images actually ship is decided from the rendered chart below."""
    for location, image in walk_image_values(values):
        gate.require(
            image.get("tag") in (None, ""),
            "mutable-image",
            f"{location} supplies a mutable tag",
        )


def walk_rendered_images(value: Any, location: str = "$") -> list[tuple[str, str]]:
    """Every string `image`/`imageName` field in the rendered objects
    (containers, initContainers, ephemeralContainers, operator CRs)."""
    found: list[tuple[str, str]] = []
    if isinstance(value, dict):
        for key, child in value.items():
            here = f"{location}.{key}"
            if key in ("image", "imageName") and isinstance(child, str):
                found.append((here, child))
            else:
                found.extend(walk_rendered_images(child, here))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found.extend(walk_rendered_images(child, f"{location}[{index}]"))
    return found


def render_chart(chart_dir: Path, values_file: Path, gate: Gate) -> list[Any] | None:
    try:
        rendered = subprocess.run(
            (
                "helm",
                "template",
                "agent-relay",
                str(chart_dir),
                "--namespace",
                "agent-relay",
                "-f",
                str(values_file),
            ),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout
    except FileNotFoundError:
        gate.reject("render", "helm is required to render the release chart")
        return None
    except subprocess.CalledProcessError as exc:
        gate.reject(
            "render",
            f"helm template {chart_dir} -f {values_file} failed (run "
            f"`helm dependency build` first): {exc.stderr.strip()}",
        )
        return None
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as stream:
        stream.write(rendered)
        rendered_path = Path(stream.name)
    try:
        documents = subprocess.run(
            ("yq", "eval-all", "-o=json", "-I=0", "[.]", str(rendered_path)),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout
        return [doc for doc in sequence(json.loads(documents)) if doc]
    except FileNotFoundError:
        gate.reject("render", "yq v4 is required to parse the rendered chart")
    except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        gate.reject("render", f"cannot parse the rendered chart: {exc}")
    finally:
        rendered_path.unlink(missing_ok=True)
    return None


def validate_rendered_images(
    documents: list[Any], images: list[Any], gate: Gate
) -> None:
    """Every rendered image must be an exact repository@digest of an active,
    approved customer-images.yaml entry, and every active entry must render."""
    approved: dict[tuple[str, str], str] = {}
    active: dict[tuple[str, str], str] = {}
    for item in images:
        image = mapping(item)
        if image.get("active") is not True:
            continue
        current = mapping(image.get("current"))
        key = (text(current.get("repository")), text(current.get("digest")))
        active[key] = text(image.get("id")) or "(unnamed)"
        approval = mapping(image.get("approval"))
        if (
            approval.get("status") in APPROVED_IMAGE
            and sequence(approval.get("blockingReasons")) == []
        ):
            approved[key] = active[key]

    rendered = [
        (f"{text(mapping(doc.get('metadata')).get('name'))}/{doc.get('kind')}{where[1:]}", ref)
        for doc in documents
        for where, ref in walk_rendered_images(mapping(doc))
    ]
    gate.require(bool(rendered), "rendered-images", "the rendered chart contains no images")
    seen: set[tuple[str, str]] = set()
    for location, ref in rendered:
        match = IMAGE_REF.fullmatch(ref)
        repository = match.group("repository") if match else ref
        digest = (match.group("digest") or "") if match else ""
        if not digest or digest == ZERO_DIGEST:
            gate.reject(
                "mutable-image",
                f"{location} renders {ref!r} without a non-zero digest",
            )
            continue
        gate.require(
            not PROOF_OR_PRIVATE.search(repository) and not PLACEHOLDER.search(repository),
            "registry",
            f"{location} renders a proof/private/placeholder repository {repository}",
        )
        key = (repository, digest)
        seen.add(key)
        if key not in active:
            gate.reject(
                "rendered-images",
                f"{location} renders {repository}@{digest}, which is not an active "
                "customer-images.yaml entry",
            )
        elif key not in approved:
            gate.reject(
                "rendered-images",
                f"{location} renders {active[key]} ({repository}@{digest}), which "
                "is not approved for customer release",
            )
    for key, identifier in sorted(active.items(), key=lambda kv: kv[1]):
        gate.require(
            key in seen,
            "rendered-images",
            f"active customer-images.yaml entry {identifier} ({key[0]}@{key[1]}) "
            "is not rendered by the release values",
        )


def validate_hooks(scan_root: Path, gate: Gate) -> None:
    charts = scan_root / "charts"
    if not charts.is_dir():
        gate.reject("helm-hooks", f"chart scan root is missing: {charts}")
        return
    for path in sorted(charts.glob("*/templates/**/*")):
        if not path.is_file():
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeError:
            continue
        for match in HOOK.finditer(content):
            hooks = {part.strip() for part in match.group(1).split(",")}
            unsupported = sorted(hooks - {"test", "test-success"})
            if unsupported:
                gate.reject(
                    "helm-hooks",
                    f"{path.relative_to(scan_root)} declares {','.join(unsupported)}",
                )


def validate_test_evidence(
    evidence: dict[str, Any], image_manifest_sha: str, gate: Gate
) -> None:
    records = mapping(evidence.get("upgradeRestore"))
    release_version = text(mapping(evidence.get("release")).get("chartVersion"))
    for name in ("upgrade", "restore"):
        row = mapping(records.get(name))
        gate.require(
            row.get("result") == "pass",
            f"{name}-evidence",
            f"{name} result is not pass",
        )
        gate.require(
            text(row.get("chartVersion")) == release_version
            and text(row.get("evidence")).strip() != ""
            and DIGEST.fullmatch(text(row.get("artifactSha256"))) is not None
            and text(row.get("artifactSha256")) != ZERO_DIGEST,
            f"{name}-evidence",
            f"{name} evidence metadata is incomplete or for another chart version",
        )
        gate.require(
            text(row.get("imageManifestSha256")) == image_manifest_sha,
            f"{name}-evidence",
            f"{name} was not tested against this image manifest",
        )


def validate_gate_record(
    row: dict[str, Any], category: str, label: str, gate: Gate
) -> None:
    gate.require(row.get("result") == "pass", category, f"{label} result is not pass")
    gate.require(
        text(row.get("evidence")).strip() != "",
        category,
        f"{label} evidence is missing",
    )
    artifact = text(row.get("artifactSha256"))
    gate.require(
        bool(DIGEST.fullmatch(artifact)) and artifact != ZERO_DIGEST,
        category,
        f"{label} artifactSha256 is not a non-zero digest",
    )


def validate_operational_readiness(
    evidence: dict[str, Any], image_manifest_sha: str, gate: Gate
) -> None:
    row = mapping(evidence.get("operationalReadiness"))
    category = "operational-readiness"
    if not row:
        gate.reject(category, "operationalReadiness evidence is missing")
        return
    release_version = text(mapping(evidence.get("release")).get("chartVersion"))
    load = mapping(row.get("loadTest"))
    validate_gate_record(load, category, "loadTest", gate)
    gate.require(
        text(load.get("chartVersion")) == release_version
        and text(load.get("imageManifestSha256")) == image_manifest_sha,
        category,
        "loadTest was not run against this chart version and image manifest",
    )
    validate_gate_record(mapping(row.get("recovery")), category, "recovery", gate)
    observability = mapping(row.get("observability"))
    for name in ("alerts", "dashboards", "runbooks"):
        validate_gate_record(
            mapping(observability.get(name)), category, f"observability.{name}", gate
        )


def validate_version_compatibility(evidence: dict[str, Any], gate: Gate) -> None:
    row = mapping(evidence.get("versionCompatibility"))
    category = "version-compatibility"
    if not row:
        gate.reject(category, "versionCompatibility evidence is missing")
        return
    release_version = text(mapping(evidence.get("release")).get("chartVersion"))
    gate.require(
        text(row.get("serverCurrentVersion")) == release_version,
        category,
        "serverCurrentVersion does not match the release chartVersion",
    )
    customer = set(sequence(mapping(evidence.get("desktop")).get("customerPlatforms")))
    matrix = mapping(row.get("matrix"))
    for server in ("Current", "Previous"):
        for desktop in ("Current", "Previous"):
            name = f"server{server}Desktop{desktop}"
            cell = mapping(matrix.get(name))
            validate_gate_record(cell, category, f"matrix.{name}", gate)
            gate.require(
                text(cell.get("serverVersion"))
                == text(row.get(f"server{server}Version"))
                and text(cell.get("desktopVersion"))
                == text(row.get(f"desktop{desktop}Version")),
                category,
                f"matrix.{name} was run against other server/Desktop versions",
            )
            gate.require(
                customer <= set(sequence(cell.get("testedPlatforms"))),
                category,
                f"matrix.{name} does not cover every customer Desktop platform",
            )


def validate_desktop(evidence: dict[str, Any], gate: Gate) -> None:
    row = mapping(evidence.get("desktop"))
    customer = set(sequence(row.get("customerPlatforms")))
    tested = set(sequence(row.get("testedPlatforms")))
    gate.require(bool(customer), "desktop-platforms", "no customer platform recorded")
    unsupported = sorted(customer - DESKTOP_PLATFORMS)
    gate.require(
        not unsupported,
        "desktop-platforms",
        f"unsupported customer platform(s): {', '.join(unsupported)}",
    )
    gate.require(
        customer <= tested,
        "desktop-platforms",
        "every customer Desktop platform must have passing evidence",
    )
    gate.require(
        row.get("result") == "pass" and text(row.get("evidence")).strip() != "",
        "desktop-platforms",
        "Desktop platform evidence is missing or failed",
    )


def validate_git(root: Path, gate: Gate) -> None:
    try:
        top = subprocess.run(
            ("git", "-C", str(root), "rev-parse", "--show-toplevel"),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout.strip()
        gate.require(
            Path(top).resolve() == root,
            "source-worktree",
            "root is not the Git worktree root",
        )
        status = subprocess.run(
            (
                "git",
                "-C",
                str(root),
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--",
                ".",
                ":(exclude)dist",
            ),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout
        gate.require(
            status == "",
            "source-worktree",
            "tracked release source has uncommitted changes",
        )
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        gate.reject("source-worktree", f"cannot inspect Git worktree: {exc}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Validate all production customer-bundle release evidence."
    )
    result.add_argument("--root", default=".")
    result.add_argument(
        "--evidence", default="self-hosted/customer-release-evidence.json"
    )
    result.add_argument(
        "--schema", default="self-hosted/customer-release-evidence.schema.json"
    )
    result.add_argument(
        "--customer-images", default="self-hosted/customer-images.yaml"
    )
    result.add_argument(
        "--scan-root",
        help="root containing charts/; defaults to --root (fixture tests only)",
    )
    result.add_argument(
        "--consistency",
        action="store_true",
        help=(
            "check only that the checked-in records are consistent (evidence "
            "schema, manifest vocabulary, release.imageManifestSha256), not "
            "that the release is approved; used by CI on every change"
        ),
    )
    result.add_argument(
        "--require-clean",
        action="store_true",
        help="also require a clean Git worktree, excluding dist/",
    )
    return result


def main() -> int:
    args = parser().parse_args()
    root = Path(args.root).expanduser().resolve()
    gate = Gate()
    evidence_path = safe_input(root, args.evidence, gate, "evidence")
    schema_path = safe_input(root, args.schema, gate, "schema")
    images_path = safe_input(root, args.customer_images, gate, "customer images")
    scan_root = safe_input(root, args.scan_root or ".", gate, "scan root")
    evidence = load_json(evidence_path, gate, "release evidence")
    schema = load_json(schema_path, gate, "release evidence schema")
    manifest = load_yaml(images_path, gate)
    validate_evidence_shape(evidence, schema, gate)
    evidence_map = mapping(evidence)
    validate_manifest_vocabulary(mapping(manifest), gate)
    release = mapping(evidence_map.get("release"))
    try:
        manifest_sha = "sha256:" + sha256(images_path.read_bytes())
    except OSError:
        manifest_sha = ""
    gate.require(
        text(release.get("imageManifestSha256")) == manifest_sha,
        "images-manifest",
        "release evidence imageManifestSha256 does not match customer-images.yaml "
        f"({manifest_sha})",
    )
    if args.consistency:
        return report(gate, "customer release records: CONSISTENT")
    validate_controls(evidence_map, gate)
    images = validate_images(mapping(manifest), gate)
    validate_license_decisions(evidence_map, images, gate)

    chart_path = scan_root / "charts/agent-relay/Chart.yaml"
    chart = load_yaml(chart_path, gate)
    gate.require(
        text(mapping(chart).get("version")) == text(release.get("chartVersion")),
        "release-version",
        "release evidence chartVersion does not match charts/agent-relay/Chart.yaml",
    )
    values_file = safe_input(root, text(release.get("valuesFile")), gate, "valuesFile")
    values = load_yaml(values_file, gate)
    validate_values(values, gate)
    documents = render_chart(chart_path.parent, values_file, gate)
    if documents is not None:
        validate_rendered_images(documents, images, gate)
    validate_hooks(scan_root, gate)
    validate_test_evidence(evidence_map, manifest_sha, gate)
    validate_operational_readiness(evidence_map, manifest_sha, gate)
    validate_version_compatibility(evidence_map, gate)
    validate_desktop(evidence_map, gate)
    if args.require_clean:
        validate_git(root, gate)
    active = len([x for x in images if mapping(x).get("active") is True])
    return report(gate, f"customer release gate: PASS (images={active})")


def report(gate: Gate, success: str) -> int:
    if gate.errors:
        for error in gate.errors:
            print(f"ERROR [{error}]", file=sys.stderr)
        print(
            f"customer release gate: FAIL ({len(gate.errors)} error(s))",
            file=sys.stderr,
        )
        return 1
    print(success)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
