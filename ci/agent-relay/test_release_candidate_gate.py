import argparse
import copy
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

REPOSITORY = "AgentWorkforce/infra"
HEAD = "a" * 40
MERGE = "b" * 40


def fixture():
    prefix = "releases/agent-relay-2026.11.1/"
    return {
        "pr": {
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
        "runs": {
            "workflow_runs": [
                {
                    "id": 123,
                    "head_sha": HEAD,
                    "head_branch": "release/agent-relay-2026.11.1",
                    "event": "pull_request",
                    "status": "completed",
                    "conclusion": "success",
                    "repository": {"full_name": REPOSITORY},
                    "head_repository": {"full_name": REPOSITORY},
                }
            ]
        },
        "jobs": {
            "jobs": [
                {
                    "id": 456,
                    "run_id": 123,
                    "head_sha": HEAD,
                    "name": "qualification",
                    "status": "completed",
                    "conclusion": "success",
                }
            ]
        },
    }


class ReleaseCandidateGateTest(unittest.TestCase):
    def validate(self, data):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            paths = {}
            for name in ("pr", "reviews", "files", "runs", "jobs"):
                paths[name] = root / f"{name}.json"
                paths[name].write_text(json.dumps(data[name]), encoding="utf-8")
            return MODULE.validate(
                argparse.Namespace(repository=REPOSITORY, **paths)
            )

    def test_accepts_exact_head_full_gate_and_different_user_approval(self):
        self.assertEqual(
            self.validate(fixture()),
            {
                "version": "2026.11.1",
                "headSha": HEAD,
                "mergeSha": MERGE,
                "acceptanceRunId": 123,
                "approvalCount": 1,
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

    def test_acceptance_run_must_be_exact_head_success_from_same_release_branch(self):
        for patch in (
            {"head_sha": "c" * 40},
            {"head_branch": "release/agent-relay-2026.11.0"},
            {"event": "workflow_dispatch"},
            {"status": "in_progress", "conclusion": None},
            {"conclusion": "failure"},
            {"repository": {"full_name": "fork/infra"}},
        ):
            data = fixture()
            data["runs"]["workflow_runs"][0].update(patch)
            with self.subTest(patch=patch), self.assertRaisesRegex(
                ValueError, "local acceptance"
            ):
                self.validate(data)

    def test_acceptance_run_id_must_be_a_positive_integer(self):
        for run_id in (None, "123", 0, -1):
            data = fixture()
            data["runs"]["workflow_runs"][0]["id"] = run_id
            with self.subTest(run_id=run_id), self.assertRaisesRegex(
                ValueError, "run identity"
            ):
                self.validate(data)

    def test_qualification_job_must_be_unique_and_successful(self):
        for patch in (
            {"run_id": 999},
            {"head_sha": "c" * 40},
            {"name": "api"},
            {"status": "in_progress", "conclusion": None},
            {"conclusion": "failure"},
        ):
            data = fixture()
            data["jobs"]["jobs"][0].update(patch)
            with self.subTest(patch=patch), self.assertRaisesRegex(
                ValueError, "qualification job"
            ):
                self.validate(data)
        data = fixture()
        data["jobs"]["jobs"].append(copy.deepcopy(data["jobs"]["jobs"][0]))
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            self.validate(data)

    def test_workflow_contract_never_treats_api_only_as_qualification(self):
        acceptance = (ROOT / ".github/workflows/local-acceptance.yml").read_text()
        tagging = (ROOT / ".github/workflows/release-candidate-tag.yml").read_text()
        makefile = (ROOT / "Makefile").read_text()
        documentation = (ROOT / "docs/local-acceptance.md").read_text()
        self.assertIn("group: infra-acceptance-arlap", acceptance)
        self.assertIn("labels: [self-hosted, arlap, kind]", acceptance)
        self.assertIn("Reject executable or cross-candidate changes before checkout", acceptance)
        self.assertLess(
            acceptance.index("Reject executable or cross-candidate changes before checkout"),
            acceptance.index("Check out the exact release candidate head"),
        )
        self.assertIn("ACCEPTANCE_SUITE=full", acceptance)
        self.assertNotIn("ACCEPTANCE_SUITE=api", acceptance)
        self.assertIn(".payload.qualificationComplete == true", acceptance)
        self.assertIn(".payload.pendingQualificationChecks | length", acceptance)
        self.assertIn("actions/workflows/local-acceptance.yml/runs", tagging)
        self.assertIn("validate-release-candidate-gate.py", tagging)
        self.assertIn("Check out the trusted release gate", tagging)
        self.assertNotIn('merge-base --is-ancestor "$HEAD_SHA"', tagging)
        self.assertIn('tag="agent-relay-${VERSION}"', tagging)
        self.assertIn("ACCEPTANCE_OUTPUT ?=", makefile)
        self.assertIn("ACCEPTANCE_KEY ?=", makefile)
        self.assertIn(
            "AgentWorkforce/infra/.github/workflows/local-acceptance.yml@refs/heads/main",
            documentation,
        )
        self.assertIn("Selected repositories", documentation)
        self.assertIn("Selected workflows", documentation)


if __name__ == "__main__":
    unittest.main()
