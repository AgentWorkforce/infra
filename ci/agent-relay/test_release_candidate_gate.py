import argparse
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "release_candidate_gate",
    ROOT / "scripts/release/validate-release-candidate-gate.py",
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
ACCEPTANCE_SPEC = importlib.util.spec_from_file_location(
    "release_acceptance",
    ROOT / "scripts/release/validate-release-acceptance.py",
)
assert ACCEPTANCE_SPEC and ACCEPTANCE_SPEC.loader
ACCEPTANCE_MODULE = importlib.util.module_from_spec(ACCEPTANCE_SPEC)
ACCEPTANCE_SPEC.loader.exec_module(ACCEPTANCE_MODULE)

REPOSITORY = "AgentWorkforce/infra"
HEAD = "a" * 40
MERGE = "b" * 40
DIGESTS = {
    name: "sha256:" + value * 64
    for name, value in zip(
        ("relay-control", "relay-webapp", "sessions-pipeline"),
        ("1", "2", "3"),
    )
}


def fixture():
    prefix = "releases/agent-relay-2026.11.1/"
    return {
        "pr": {
            "number": 42,
            "merged": True,
            "merge_commit_sha": MERGE,
            "user": {"login": "release-bot"},
            "head": {
                "ref": "release/agent-relay-2026.11.1",
                "sha": HEAD,
                "repo": {"full_name": REPOSITORY},
            },
            "base": {"ref": "main", "repo": {"full_name": REPOSITORY}},
        },
        "reviews": [[
            {
                "id": 10,
                "user": {"login": "reviewer"},
                "state": "APPROVED",
                "commit_id": HEAD,
            }
        ]],
        "files": [[
            {"filename": prefix + "pins.json"},
            {"filename": prefix + "values.yaml"},
        ]],
        "checks": {
            "check_runs": [
                {
                    "id": 123,
                    "name": "acceptance",
                    "head_sha": HEAD,
                    "status": "completed",
                    "conclusion": "success",
                    "app": {"slug": "github-actions"},
                    "external_id": f"agent-relay-acceptance:123:{HEAD}",
                    "details_url": f"https://github.com/{REPOSITORY}/actions/runs/123",
                    "pull_requests": [{"number": 42}],
                }
            ]
        },
        "acceptance_run": {
            "id": 123,
            "event": "repository_dispatch",
            "path": ".github/workflows/local-acceptance.yml",
            "head_branch": "main",
            "status": "completed",
            "conclusion": "success",
            "repository": {"full_name": REPOSITORY},
        },
    }


def acceptance_fixture():
    repositories = {
        "relay-control": "ghcr.io/agentworkforce/relay-control",
        "relay-webapp": "ghcr.io/agentworkforce/relay-webapp",
        "sessions-pipeline": "ghcr.io/agentworkforce/sessions-pipeline",
    }
    pins = {
        component: {"repository": repository, "digest": DIGESTS[component]}
        for component, repository in repositories.items()
    }
    return {
        "ledger": {"pins": pins},
        "receipt": {
            "payload": {
                "schema": "agent-relay.local-acceptance/v1",
                "suite": "full",
                "status": "pass",
                "qualificationComplete": True,
                "pendingQualificationChecks": [],
                "checks": [{"id": "preflight", "status": "pass"}],
                "context": {
                    "sourceRevision": HEAD,
                    "pins": {
                        "control": (
                            repositories["relay-control"]
                            + "@"
                            + DIGESTS["relay-control"]
                        ),
                        "webapp": (
                            repositories["relay-webapp"]
                            + "@"
                            + DIGESTS["relay-webapp"]
                        ),
                        "pipeline": (
                            repositories["sessions-pipeline"]
                            + "@"
                            + DIGESTS["sessions-pipeline"]
                        ),
                    },
                },
            }
        },
    }


class ReleaseCandidateGateTest(unittest.TestCase):
    def validate(self, data):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            paths = {}
            for name in ("pr", "reviews", "files", "checks", "acceptance_run"):
                paths[name] = root / f"{name}.json"
                paths[name].write_text(json.dumps(data[name]), encoding="utf-8")
            return MODULE.validate(
                argparse.Namespace(
                    repository=REPOSITORY,
                    acceptance_run=paths.pop("acceptance_run"),
                    **paths,
                )
            )

    def validate_acceptance(self, data, trusted_source=HEAD):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            receipt = root / "acceptance.json"
            pins = root / "pins.json"
            receipt.write_text(json.dumps(data["receipt"]), encoding="utf-8")
            pins.write_text(json.dumps(data["ledger"]), encoding="utf-8")
            return ACCEPTANCE_MODULE.validate(receipt, pins, trusted_source)

    def test_signed_receipt_is_bound_to_trusted_source_and_candidate_pins(self):
        self.assertEqual(
            self.validate_acceptance(acceptance_fixture()),
            {
                "qualificationComplete": True,
                "trustedSource": HEAD,
                "components": ["relay-control", "relay-webapp", "sessions-pipeline"],
            },
        )

    def test_receipt_binding_rejects_negative_identity_cases(self):
        cases = []
        wrong_runtime = acceptance_fixture()
        wrong_runtime["receipt"]["payload"]["context"]["pins"]["control"] += "bad"
        cases.append((wrong_runtime, HEAD, "runtime pin"))
        wrong_source = acceptance_fixture()
        cases.append((wrong_source, "c" * 40, "observer source"))
        incomplete = acceptance_fixture()
        del incomplete["ledger"]["pins"]["relay-webapp"]
        cases.append((incomplete, HEAD, "three published"))
        pending = acceptance_fixture()
        pending["receipt"]["payload"]["pendingQualificationChecks"] = ["ui"]
        cases.append((pending, HEAD, "complete full-suite"))
        failed = acceptance_fixture()
        failed["receipt"]["payload"]["checks"][0]["status"] = "fail"
        cases.append((failed, HEAD, "complete full-suite"))
        for data, trusted_source, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(
                ValueError, message
            ):
                self.validate_acceptance(data, trusted_source)

    def test_accepts_exact_head_full_gate_and_different_user_approval(self):
        self.assertEqual(
            self.validate(fixture()),
            {
                "version": "2026.11.1",
                "headSha": HEAD,
                "mergeSha": MERGE,
                "acceptanceRunId": 123,
                "approvalCount": 1,
                "approvers": ["reviewer"],
            },
        )

    def test_release_branch_is_strict_stable_semver(self):
        for branch in (
            "release/agent-relay-v2026.11.1",
            "release/agent-relay-02026.11.1",
            "release/agent-relay-2026.11.1-rc.1",
            "topic/agent-relay-2026.11.1",
        ):
            data = fixture()
            data["pr"]["head"]["ref"] = branch
            with self.subTest(branch=branch), self.assertRaisesRegex(
                ValueError, "strict stable SemVer"
            ):
                self.validate(data)

    def test_candidate_pr_cannot_change_gate_code_or_omit_ledger(self):
        data = fixture()
        data["files"][0].append({"filename": ".github/workflows/local-acceptance.yml"})
        with self.assertRaisesRegex(ValueError, "outside its candidate directory"):
            self.validate(data)
        data = fixture()
        data["files"][0] = data["files"][0][1:]
        with self.assertRaisesRegex(ValueError, "missing candidate pins"):
            self.validate(data)

    def test_candidate_pr_cannot_hide_cross_directory_rename(self):
        data = fixture()
        data["files"][0].append(
            {
                "filename": "releases/agent-relay-2026.11.1/old-makefile",
                "previous_filename": "Makefile",
            }
        )
        with self.assertRaisesRegex(ValueError, "renamed a file from outside"):
            self.validate(data)

    def test_approval_must_be_different_user_latest_and_exact_head(self):
        cases = []
        same_author = fixture()
        same_author["reviews"][0][0]["user"]["login"] = "release-bot"
        cases.append(same_author)
        stale_commit = fixture()
        stale_commit["reviews"][0][0]["commit_id"] = "c" * 40
        cases.append(stale_commit)
        superseded = fixture()
        superseded["reviews"][0].append(
            {
                "id": 11,
                "user": {"login": "reviewer"},
                "state": "CHANGES_REQUESTED",
                "commit_id": HEAD,
            }
        )
        cases.append(superseded)
        for data in cases:
            with self.subTest(data=data["reviews"]), self.assertRaisesRegex(
                ValueError, "exact-head approval"
            ):
                self.validate(data)

    def test_comment_only_review_does_not_erase_exact_head_approval(self):
        data = fixture()
        data["reviews"][0].append(
            {
                "id": 11,
                "user": {"login": "reviewer"},
                "state": "COMMENTED",
                "commit_id": HEAD,
            }
        )
        self.assertEqual(self.validate(data)["approvers"], ["reviewer"])

    def test_acceptance_check_must_be_exact_head_success_from_github_actions(self):
        for patch in (
            {"head_sha": "c" * 40},
            {"name": "api"},
            {"status": "in_progress", "conclusion": None},
            {"conclusion": "failure"},
            {"app": {"slug": "untrusted"}},
            {"pull_requests": [{"number": 99}]},
        ):
            data = fixture()
            data["checks"]["check_runs"][0].update(patch)
            with self.subTest(patch=patch), self.assertRaisesRegex(
                ValueError, "acceptance check"
            ):
                self.validate(data)

    def test_newer_failed_acceptance_supersedes_an_older_success(self):
        data = fixture()
        failed = dict(data["checks"]["check_runs"][0])
        failed.update(
            {
                "id": 124,
                "status": "completed",
                "conclusion": "failure",
                "external_id": f"agent-relay-acceptance:124:{HEAD}",
                "details_url": f"https://github.com/{REPOSITORY}/actions/runs/124",
            }
        )
        data["checks"]["check_runs"].append(failed)
        with self.assertRaisesRegex(ValueError, "latest exact-head"):
            self.validate(data)

    def test_acceptance_check_identity_binds_run_and_head(self):
        for external in (
            None,
            "agent-relay-acceptance:0:" + HEAD,
            "agent-relay-acceptance:123:" + "c" * 40,
            "other:123:" + HEAD,
        ):
            data = fixture()
            data["checks"]["check_runs"][0]["external_id"] = external
            with self.subTest(external=external), self.assertRaisesRegex(
                ValueError, "check identity"
            ):
                self.validate(data)

    def test_acceptance_run_must_be_the_trusted_main_workflow(self):
        for patch in (
            {"id": 999},
            {"event": "pull_request"},
            {"path": ".github/workflows/other.yml"},
            {"head_branch": "release/agent-relay-2026.11.1"},
            {"status": "in_progress", "conclusion": None},
            {"conclusion": "failure"},
            {"repository": {"full_name": "fork/infra"}},
        ):
            data = fixture()
            data["acceptance_run"].update(patch)
            with self.subTest(patch=patch), self.assertRaisesRegex(
                ValueError, "trusted main workflow"
            ):
                self.validate(data)

    def test_workflow_contract_never_treats_api_only_as_qualification(self):
        acceptance = (ROOT / ".github/workflows/local-acceptance.yml").read_text()
        tagging = (ROOT / ".github/workflows/release-candidate-tag.yml").read_text()
        intake = (ROOT / ".github/workflows/release-candidate.yml").read_text()
        makefile = (ROOT / "Makefile").read_text()
        documentation = (ROOT / "docs/local-acceptance.md").read_text()
        receipt_validator = (
            ROOT / "scripts/release/validate-release-acceptance.py"
        ).read_text()
        self.assertIn("group: infra-acceptance-arlap", acceptance)
        self.assertIn("labels: [self-hosted, arlap, kind]", acceptance)
        self.assertIn("repository_dispatch:", acceptance)
        self.assertIn("workflow_dispatch:", acceptance)
        self.assertNotIn("pull_request:", acceptance)
        self.assertIn(
            "group: local-acceptance-${{ github.event.client_payload.pr_number || "
            "inputs.pr_number }}-${{ github.event.client_payload.head_sha || "
            "inputs.head_sha }}",
            acceptance,
        )
        self.assertIn("cancel-in-progress: false", acceptance)
        self.assertNotIn("cancel-in-progress: true", acceptance)
        self.assertIn("Check out the trusted verifier from main", acceptance)
        self.assertIn("Check out the candidate head as data", acceptance)
        self.assertIn('"diff", "--name-status", "-z", "--find-renames"', acceptance)
        self.assertIn('python3 "$trusted/scripts/release/update-release-candidate.py"', acceptance)
        self.assertIn('make -C "$trusted" local-acceptance', acceptance)
        self.assertIn("ACCEPTANCE_SUITE=full", acceptance)
        self.assertNotIn("ACCEPTANCE_SUITE=api", acceptance)
        self.assertIn("validate-release-acceptance.py", acceptance)
        self.assertIn('payload.get("qualificationComplete") is not True', receipt_validator)
        self.assertIn('payload.get("pendingQualificationChecks") != []', receipt_validator)
        self.assertIn('"relay-control": "control"', receipt_validator)
        self.assertIn('"relay-webapp": "webapp"', receipt_validator)
        self.assertIn('"sessions-pipeline": "pipeline"', receipt_validator)
        self.assertIn("commits/${head_sha}/check-runs", tagging)
        self.assertIn("agent-relay-acceptance:", tagging)
        self.assertIn("Request exact-head full acceptance", intake)
        self.assertIn("release-candidate-acceptance", intake)
        self.assertIn("client_payload[head_sha]", intake)
        self.assertIn("git merge --no-edit origin/main", intake)
        self.assertIn("if ! git diff --cached --quiet; then", intake)
        self.assertIn("validate-release-candidate-gate.py", tagging)
        self.assertIn("collaborators/$approver/permission", tagging)
        self.assertIn("No exact-head approver has repository push permission", tagging)
        self.assertIn("Check out the trusted release gate", tagging)
        self.assertNotIn('merge-base --is-ancestor "$HEAD_SHA"', tagging)
        self.assertIn('git rev-parse "$HEAD_SHA^{tree}"', tagging)
        self.assertIn('git rev-parse "$MERGE_SHA^{tree}"', tagging)
        self.assertIn('tag="agent-relay-${VERSION}"', tagging)
        self.assertIn("ACCEPTANCE_OUTPUT ?=", makefile)
        self.assertIn("ACCEPTANCE_KEY ?=", makefile)
        self.assertIn(
            "AgentWorkforce/infra/.github/workflows/local-acceptance.yml@refs/heads/main",
            documentation,
        )
        self.assertIn("Selected repositories", documentation)
        self.assertIn("Selected workflows", documentation)

    def test_acceptance_scheduler_slots_are_isolated_by_candidate_head(self):
        def group(pr_number, head_sha):
            return f"local-acceptance-{pr_number}-{head_sha}"

        active_a = group(245, "a" * 40)
        pending_b = group(245, "b" * 40)
        delayed_a = group(245, "a" * 40)

        self.assertEqual(active_a, delayed_a)
        self.assertNotEqual(pending_b, delayed_a)


if __name__ == "__main__":
    unittest.main()
