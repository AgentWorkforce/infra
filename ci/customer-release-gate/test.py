#!/usr/bin/env python3
"""Positive and negative-category regression tests for the release gate."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).resolve().parent / "fixtures/positive"
GATE = ROOT / "scripts/release/validate-customer-release.py"
SCHEMA = ROOT / "self-hosted/customer-release-evidence.schema.json"


def read(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def write(path: Path, value: Any) -> None:
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )


def set_manifest_hash(work: Path) -> None:
    digest = "sha256:" + hashlib.sha256(
        (work / "customer-images.yaml").read_bytes()
    ).hexdigest()
    evidence = read(work / "evidence.json")
    evidence["release"]["imageManifestSha256"] = digest
    evidence["upgradeRestore"]["upgrade"]["imageManifestSha256"] = digest
    evidence["upgradeRestore"]["restore"]["imageManifestSha256"] = digest
    write(work / "evidence.json", evidence)


def run(
    work: Path, require_clean: bool = False, consistency: bool = False
) -> subprocess.CompletedProcess[str]:
    command = [
        sys.executable,
        str(GATE),
        "--root",
        str(work),
        "--scan-root",
        ".",
        "--evidence",
        "evidence.json",
        "--schema",
        "schema.json",
        "--customer-images",
        "customer-images.yaml",
    ]
    if require_clean:
        command.append("--require-clean")
    if consistency:
        command.append("--consistency")
    return subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def manifest_case(
    change: Callable[[dict[str, Any]], None],
) -> Callable[[Path], None]:
    def apply(work: Path) -> None:
        manifest = read(work / "customer-images.yaml")
        change(manifest)
        write(work / "customer-images.yaml", manifest)
        set_manifest_hash(work)

    return apply


def evidence_case(
    change: Callable[[dict[str, Any]], None],
) -> Callable[[Path], None]:
    def apply(work: Path) -> None:
        evidence = read(work / "evidence.json")
        change(evidence)
        write(work / "evidence.json", evidence)

    return apply


def values_case(
    change: Callable[[dict[str, Any]], None],
) -> Callable[[Path], None]:
    def apply(work: Path) -> None:
        values = read(work / "values.yaml")
        change(values)
        write(work / "values.yaml", values)

    return apply


def image(manifest: dict[str, Any]) -> dict[str, Any]:
    return manifest["images"][0]


def add_hard_blocker(manifest: dict[str, Any]) -> None:
    manifest["status"] = "blocked"
    manifest["blockers"] = [
        {"id": "IMG-BLOCK-TEST", "severity": "hard", "images": ["relay-control"]}
    ]


def compose(*steps: Callable[[Path], None]) -> Callable[[Path], None]:
    def apply(work: Path) -> None:
        for step in steps:
            step(work)

    return apply


UNREVIEWED = "docker.io/attacker/unreviewed@sha256:" + ("e" * 64)


def extra_rendered_image(work: Path) -> None:
    (work / "charts/agent-relay/templates/extra.yaml").write_text(
        "apiVersion: v1\nkind: Pod\nmetadata:\n  name: extra\nspec:\n"
        f"  containers:\n    - name: extra\n      image: {UNREVIEWED}\n",
        encoding="utf-8",
    )


def chart_default_drift(work: Path) -> None:
    path = work / "charts/agent-relay/values.yaml"
    path.write_text(
        path.read_text(encoding="utf-8").replace("d" * 64, "f" * 64),
        encoding="utf-8",
    )


def unrendered_manifest_image(manifest: dict[str, Any]) -> None:
    extra = json.loads(json.dumps(image(manifest)))
    extra["id"] = "relay-control-unused"
    extra["current"]["repository"] = "registry.northwind.io/agent-relay/unused"
    manifest["images"].append(extra)


def placeholder_values(values: dict[str, Any]) -> None:
    values["control"]["image"][
        "repository"
    ] = "us-central1-docker.pkg.dev/example-project/example-images/relay-control"


def placeholder_manifest(manifest: dict[str, Any]) -> None:
    image(manifest)["current"][
        "repository"
    ] = "us-central1-docker.pkg.dev/example-project/example-images/relay-control"


def drop_control_license(evidence: dict[str, Any]) -> None:
    evidence["licenses"]["firstParty"] = [
        x for x in evidence["licenses"]["firstParty"] if x["id"] != "relay-control"
    ]


def stale_manifest_hash(work: Path) -> None:
    with (work / "customer-images.yaml").open("a", encoding="utf-8") as stream:
        stream.write("\n")


def non_test_hook(work: Path) -> None:
    path = work / "charts/fixture/templates/release-job.yaml"
    path.write_text(
        'metadata:\n  annotations:\n    "helm.sh/hook": pre-upgrade\n',
        encoding="utf-8",
    )


CASES: list[tuple[str, str, Callable[[Path], None]]] = [
    ("unresolved hard blocker", "hard-blocker", manifest_case(add_hard_blocker)),
    (
        "proof registry",
        "registry",
        manifest_case(
            lambda m: image(m)["current"].update(
                repository="proof.registry.example.com/relay-control"
            )
        ),
    ),
    (
        "private vendor registry",
        "registry",
        manifest_case(
            lambda m: image(m)["current"].update(
                repository="private.registry.example.com/relay-control"
            )
        ),
    ),
    (
        "uncommitted source revision",
        "source-revision",
        manifest_case(
            lambda m: image(m)["source"].update(
                revision=None, reproducibleReference=False
            )
        ),
    ),
    (
        "missing first-party license decision",
        "first-party-license",
        evidence_case(
            lambda e: e["licenses"].update(
                firstParty=[
                    x
                    for x in e["licenses"]["firstParty"]
                    if x["id"] != "relay-control"
                ]
            )
        ),
    ),
    (
        "missing image platforms",
        "image-platforms",
        manifest_case(
            lambda m: image(m)["platforms"].update(
                verifiedFromRegistry=["linux/amd64"], status="incomplete"
            )
        ),
    ),
    (
        "missing SBOM",
        "sbom",
        manifest_case(
            lambda m: image(m)["release"].update(publishesSbom=False)
        ),
    ),
    (
        "missing provenance",
        "provenance",
        manifest_case(
            lambda m: image(m)["release"].update(publishesProvenance=False)
        ),
    ),
    ("non-test Helm hook", "helm-hooks", non_test_hook),
    (
        "mutable image tag",
        "mutable-image",
        values_case(
            lambda v: v["control"]["image"].update(
                digest="", tag="latest"
            )
        ),
    ),
    (
        "values image differs from the manifest",
        "rendered-images",
        values_case(
            lambda v: v["control"]["image"].update(
                repository="docker.io/attacker/unreviewed"
            )
        ),
    ),
    ("extra rendered image", "rendered-images", extra_rendered_image),
    ("chart default image drift", "rendered-images", chart_default_drift),
    (
        "active manifest image not rendered",
        "rendered-images",
        manifest_case(unrendered_manifest_image),
    ),
    (
        "placeholder repository",
        "registry",
        compose(values_case(placeholder_values), manifest_case(placeholder_manifest)),
    ),
    (
        "empty source repository",
        "source-repository",
        compose(
            manifest_case(lambda m: image(m)["source"].update(repository="")),
            evidence_case(drop_control_license),
        ),
    ),
    (
        "source repository not allowlisted",
        "source-repository",
        manifest_case(
            lambda m: image(m)["source"].update(
                repository="https://github.com/attacker/relay-control"
            )
        ),
    ),
    (
        "first-party image marked third-party",
        "source-repository",
        manifest_case(lambda m: image(m).update(firstParty=False)),
    ),
    (
        "manifest vocabulary",
        "manifest-vocabulary",
        manifest_case(
            lambda m: image(m)["release"].update(publishesProvenance="max")
        ),
    ),
    ("stale image manifest hash", "images-manifest", stale_manifest_hash),
    (
        "missing operational readiness",
        "schema",
        evidence_case(lambda e: e.pop("operationalReadiness")),
    ),
    (
        "missing version compatibility",
        "schema",
        evidence_case(lambda e: e.pop("versionCompatibility")),
    ),
    (
        "failed load test",
        "operational-readiness",
        evidence_case(
            lambda e: e["operationalReadiness"]["loadTest"].update(result="fail")
        ),
    ),
    (
        "load test for another chart version",
        "operational-readiness",
        evidence_case(
            lambda e: e["operationalReadiness"]["loadTest"].update(
                chartVersion="0.9.0"
            )
        ),
    ),
    (
        "empty observability evidence",
        "schema",
        evidence_case(
            lambda e: e["operationalReadiness"]["observability"]["alerts"].update(
                evidence=""
            )
        ),
    ),
    (
        "failed compatibility cell",
        "version-compatibility",
        evidence_case(
            lambda e: e["versionCompatibility"]["matrix"][
                "serverPreviousDesktopCurrent"
            ].update(result="not-run")
        ),
    ),
    (
        "approved with Desktop not run",
        "schema",
        evidence_case(lambda e: e["desktop"].update(result="not-run")),
    ),
    (
        "zero upgrade artifact digest",
        "upgrade-evidence",
        evidence_case(
            lambda e: e["upgradeRestore"]["upgrade"].update(
                artifactSha256="sha256:" + ("0" * 64)
            )
        ),
    ),
    (
        "missing branch controls",
        "branch-controls",
        evidence_case(
            lambda e: e["release"]["branchControls"].update(protected=False)
        ),
    ),
    (
        "missing environment controls",
        "environment-controls",
        evidence_case(
            lambda e: e["release"]["environmentControls"].update(protected=False)
        ),
    ),
    (
        "missing upgrade evidence",
        "upgrade-evidence",
        evidence_case(
            lambda e: e["upgradeRestore"]["upgrade"].update(
                result="not-run", evidence=""
            )
        ),
    ),
    (
        "missing restore evidence",
        "restore-evidence",
        evidence_case(
            lambda e: e["upgradeRestore"]["restore"].update(
                result="not-run", evidence=""
            )
        ),
    ),
    (
        "unsupported Desktop platform",
        "desktop-platforms",
        evidence_case(
            lambda e: e["desktop"].update(
                customerPlatforms=["windows/amd64"],
                testedPlatforms=["windows/amd64"],
            )
        ),
    ),
]


def main() -> int:
    failures = 0
    with tempfile.TemporaryDirectory(prefix="customer-release-gate-") as temporary:
        base = Path(temporary)
        positive = base / "positive"
        shutil.copytree(FIXTURE, positive)
        shutil.copy2(SCHEMA, positive / "schema.json")
        result = run(positive)
        if result.returncode != 0:
            print(f"FAIL positive fixture\n{result.stderr}", file=sys.stderr)
            failures += 1
        else:
            print("ok   positive fixture")

        clean = base / "clean-worktree"
        shutil.copytree(FIXTURE, clean)
        shutil.copy2(SCHEMA, clean / "schema.json")
        for command in (
            ("git", "init", "-q"),
            ("git", "add", "."),
            (
                "git",
                "-c",
                "user.name=Release Gate Test",
                "-c",
                "user.email=release-gate@example.invalid",
                "commit",
                "-qm",
                "fixture",
            ),
        ):
            subprocess.run(command, cwd=clean, check=True)
        result = run(clean, require_clean=True)
        if result.returncode != 0:
            print(f"FAIL clean worktree fixture\n{result.stderr}", file=sys.stderr)
            failures += 1
        else:
            print("ok   clean worktree fixture")
        with (clean / "values.yaml").open("a", encoding="utf-8") as stream:
            stream.write("\n")
        result = run(clean, require_clean=True)
        if result.returncode == 0 or "ERROR [source-worktree:" not in result.stderr:
            print(
                f"FAIL dirty source worktree was not rejected\n{result.stderr}",
                file=sys.stderr,
            )
            failures += 1
        else:
            print("ok   dirty source worktree")

        result = run(positive, consistency=True)
        if result.returncode != 0:
            print(f"FAIL consistency mode\n{result.stderr}", file=sys.stderr)
            failures += 1
        else:
            print("ok   consistency mode")
        stale = base / "stale-consistency"
        shutil.copytree(FIXTURE, stale)
        shutil.copy2(SCHEMA, stale / "schema.json")
        stale_manifest_hash(stale)
        result = run(stale, consistency=True)
        if result.returncode == 0 or "ERROR [images-manifest:" not in result.stderr:
            print(
                f"FAIL consistency mode accepted a stale hash\n{result.stderr}",
                file=sys.stderr,
            )
            failures += 1
        else:
            print("ok   consistency mode stale hash")

        for index, (name, category, mutate) in enumerate(CASES):
            work = base / f"negative-{index:02d}"
            shutil.copytree(FIXTURE, work)
            shutil.copy2(SCHEMA, work / "schema.json")
            mutate(work)
            result = run(work)
            marker = f"ERROR [{category}:"
            if result.returncode == 0:
                print(f"FAIL {name}: gate passed", file=sys.stderr)
                failures += 1
            elif marker not in result.stderr:
                print(
                    f"FAIL {name}: expected {marker!r}\n{result.stderr}",
                    file=sys.stderr,
                )
                failures += 1
            else:
                print(f"ok   {name}")
    if failures:
        print(f"customer release gate tests: FAIL ({failures})", file=sys.stderr)
        return 1
    print(f"customer release gate tests: PASS ({5 + len(CASES)} cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
