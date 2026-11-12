#!/usr/bin/env python3
"""Validate exact-head approval and local acceptance before release tagging."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys


BRANCH = re.compile(r"^release/agent-relay-((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$")
SHA = re.compile(r"^[a-f0-9]{40}$")


def fail(message: str) -> None:
    raise ValueError(message)


def load(path: pathlib.Path):
    return json.loads(path.read_text(encoding="utf-8"))


def flatten_pages(value, name: str) -> list:
    if not isinstance(value, list) or not all(isinstance(page, list) for page in value):
        fail(f"{name} pagination is malformed")
    return [item for page in value for item in page]


def validate(args: argparse.Namespace) -> dict[str, object]:
    pr = load(args.pr)
    reviews = flatten_pages(load(args.reviews), "reviews")
    files = flatten_pages(load(args.files), "files")
    checks = load(args.checks)
    acceptance_run = load(args.acceptance_run)
    if not isinstance(pr, dict) or not pr.get("merged"):
        fail("release pull request is not merged")
    head = pr.get("head", {})
    base = pr.get("base", {})
    match = BRANCH.fullmatch(head.get("ref", ""))
    if not match:
        fail("release branch is not strict stable SemVer")
    version = match.group(1)
    head_sha = head.get("sha", "")
    merge_sha = pr.get("merge_commit_sha", "")
    if not SHA.fullmatch(head_sha) or not SHA.fullmatch(merge_sha):
        fail("release pull request commit identity is invalid")
    if (
        base.get("ref") != "main"
        or head.get("repo", {}).get("full_name") != args.repository
        or base.get("repo", {}).get("full_name") != args.repository
    ):
        fail("release pull request repository identity is invalid")

    prefix = f"releases/agent-relay-{version}/"
    filenames = [item.get("filename") for item in files if isinstance(item, dict)]
    if len(filenames) != len(files) or not filenames or not all(
        isinstance(name, str) and name.startswith(prefix) for name in filenames
    ):
        fail("release pull request changed files outside its candidate directory")
    if not all(
        "previous_filename" not in item
        or (
            isinstance(item["previous_filename"], str)
            and item["previous_filename"].startswith(prefix)
        )
        for item in files
    ):
        fail("release pull request renamed a file from outside its candidate directory")
    if not {prefix + "pins.json", prefix + "values.yaml"}.issubset(filenames):
        fail("release pull request is missing candidate pins or values")

    latest = {}
    for review in reviews:
        try:
            login = review["user"]["login"]
            review_id = review["id"]
        except (KeyError, TypeError):
            fail("release review metadata is malformed")
        if not isinstance(login, str) or not isinstance(review_id, int):
            fail("release review identity is malformed")
        if review.get("state") == "COMMENTED":
            continue
        if login not in latest or review_id > latest[login]["id"]:
            latest[login] = review
    author = pr.get("user", {}).get("login")
    if not isinstance(author, str) or not author:
        fail("release pull request author identity is invalid")
    approved = [
        review
        for login, review in latest.items()
        if login != author
        and review.get("state") == "APPROVED"
        and review.get("commit_id") == head_sha
    ]
    if not approved:
        fail("release pull request lacks a different-user exact-head approval")

    check_runs = checks.get("check_runs") if isinstance(checks, dict) else None
    if not isinstance(check_runs, list):
        fail("acceptance check metadata is malformed")
    candidate_checks = [
        check
        for check in check_runs
        if check.get("name") == "acceptance"
        and check.get("head_sha") == head_sha
        and check.get("app", {}).get("slug") == "github-actions"
        and isinstance(check.get("pull_requests"), list)
        and any(item.get("number") == pr.get("number") for item in check["pull_requests"])
    ]
    if not candidate_checks or not all(
        isinstance(check.get("id"), int) and check["id"] > 0 for check in candidate_checks
    ):
        fail("exact-head acceptance check is missing or malformed")
    check = max(candidate_checks, key=lambda item: item["id"])
    if check.get("status") != "completed" or check.get("conclusion") != "success":
        fail("latest exact-head acceptance check did not succeed")
    external_id = check.get("external_id")
    if not isinstance(external_id, str):
        fail("exact-head acceptance check identity is invalid")
    external = re.fullmatch(
        rf"agent-relay-acceptance:([1-9][0-9]*):{re.escape(head_sha)}",
        external_id,
    )
    if not external:
        fail("exact-head acceptance check identity is invalid")
    run_id = int(external.group(1))
    if check.get("details_url") != f"https://github.com/{args.repository}/actions/runs/{run_id}":
        fail("exact-head acceptance check run link is invalid")
    if (
        not isinstance(acceptance_run, dict)
        or acceptance_run.get("id") != run_id
        or acceptance_run.get("event") not in {"repository_dispatch", "workflow_dispatch"}
        or acceptance_run.get("path") != ".github/workflows/local-acceptance.yml"
        or acceptance_run.get("head_branch") != "main"
        or acceptance_run.get("status") != "completed"
        or acceptance_run.get("conclusion") != "success"
        or acceptance_run.get("repository", {}).get("full_name") != args.repository
    ):
        fail("acceptance check does not belong to the trusted main workflow")
    return {
        "version": version,
        "headSha": head_sha,
        "mergeSha": merge_sha,
        "acceptanceRunId": run_id,
        "approvalCount": len(approved),
        "approvers": sorted(review["user"]["login"] for review in approved),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True)
    parser.add_argument("--pr", type=pathlib.Path, required=True)
    parser.add_argument("--reviews", type=pathlib.Path, required=True)
    parser.add_argument("--files", type=pathlib.Path, required=True)
    parser.add_argument("--checks", type=pathlib.Path, required=True)
    parser.add_argument("--acceptance-run", type=pathlib.Path, required=True)
    return parser.parse_args()


def main() -> int:
    try:
        print(json.dumps(validate(parse_args()), sort_keys=True))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"validate-release-candidate-gate: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
