"""scripts/selfhost/ci-deploy.sh and ci_deploy_plan.py, offline: helm, kubectl, aws and curl are fakes."""
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SELFHOST = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SELFHOST))
from ci_deploy_plan import compare, leaves, load_allow  # noqa: E402

CM = "apiVersion: v1\nkind: ConfigMap\nmetadata: {name: cfg, namespace: ns}\ndata: {a: '1'}\n"
SECRET = "apiVersion: v1\nkind: Secret\nmetadata: {name: s, namespace: ns}\ndata: {pw: TElWRVBX}\n"
DEPLOY = "apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: web, namespace: ns}\nspec: {replicas: 1}\n"


def live_dir(d, values, manifest, hooks=""):
    Path(d, "values.json").write_text(json.dumps(values))
    Path(d, "manifest.yaml").write_text(manifest)
    Path(d, "hooks.yaml").write_text(hooks)
    return d


class CompareTest(unittest.TestCase):
    def test_identical_is_no_change(self):
        with tempfile.TemporaryDirectory() as d:
            live = live_dir(d, {"a": {"b": 1}}, CM + "---\n" + DEPLOY)
            s, diff = compare("r", live, {"config": {"a": {"b": 1}}, "manifest": DEPLOY + "---\n" + CM}, set(), set())
        self.assertTrue(s["no_changes"])
        self.assertEqual(diff, "")

    def test_dropped_value_and_resource_are_refused(self):
        with tempfile.TemporaryDirectory() as d:
            live = live_dir(d, {"feature": {"on": True, "url": "x"}, "keep": 1}, CM + "---\n" + DEPLOY)
            s, _ = compare("r", live, {"config": {"keep": 1}, "manifest": DEPLOY}, set(), set())
        self.assertEqual(s["refused"]["values"], ["feature.on", "feature.url"])
        self.assertEqual(s["refused"]["resources"], ["ConfigMap/ns/cfg"])

    def test_allowlist_covers_subtree(self):
        with tempfile.TemporaryDirectory() as d:
            live = live_dir(d, {"feature": {"on": True, "url": "x"}}, CM)
            s, _ = compare("r", live, {"config": {}, "manifest": ""}, {"feature"}, {"ConfigMap/ns/cfg"})
        self.assertEqual(s["refused"], {"values": [], "resources": []})
        self.assertEqual(s["values"]["dropped"], ["feature.on", "feature.url"])

    def test_secret_data_and_secret_values_never_in_diff(self):
        with tempfile.TemporaryDirectory() as d:
            live = live_dir(d, {"db": {"password": "LIVEPW"}}, SECRET)
            new_secret = SECRET.replace("TElWRVBX", "TkVXUFc=")
            s, diff = compare("r", live, {"config": {"db": {"password": "NEWPW"}}, "manifest": new_secret}, set(), set())
        self.assertEqual(s["resources"]["changed"], ["Secret/ns/s"])
        for v in ("LIVEPW", "NEWPW", "TElWRVBX", "TkVXUFc="):
            self.assertNotIn(v, diff)
        self.assertIn("sha256:", diff)

    def test_null_to_absent_is_a_change(self):
        with tempfile.TemporaryDirectory() as d:
            live = live_dir(d, {"keep": 1, "a": None}, DEPLOY)
            s, _ = compare("r", live, {"config": {"keep": 1}, "manifest": DEPLOY}, {"a"}, set())
        self.assertFalse(s["no_changes"])

    def test_nested_and_list_secrets_are_digests(self):
        with tempfile.TemporaryDirectory() as d:
            live = live_dir(d, {"dbPassword": {"value": "PW1"}, "credentials": {"database": {"url": "URL1"}},
                                "extraEnv": [{"name": "DB_PASSWORD", "value": "PW2"}], "image": {"tag": "v1"}}, DEPLOY)
            _, diff = compare("r", live, {"config": {"image": {"tag": "v2"}}, "manifest": DEPLOY},
                              {"dbPassword", "credentials", "extraEnv"}, set())
        for v in ("PW1", "URL1", "PW2"):
            self.assertNotIn(v, diff)
        self.assertIn('value image.tag: "v1" -> "v2"', diff)

    def test_hooks_count_as_resources(self):
        job = "apiVersion: batch/v1\nkind: Job\nmetadata: {name: migrate, namespace: ns}\n"
        with tempfile.TemporaryDirectory() as d:
            live = live_dir(d, {}, DEPLOY, hooks=job)
            s, _ = compare("r", live, {"config": {}, "manifest": DEPLOY, "hooks": [{"manifest": job}]}, set(), set())
        self.assertTrue(s["no_changes"])

    def test_new_release(self):
        with tempfile.TemporaryDirectory() as d:
            s, _ = compare("r", d, {"config": {"a": 1}, "manifest": DEPLOY}, set(), set())
        self.assertFalse(s["exists"])
        self.assertEqual(s["resources"]["added"], ["Deployment/ns/web"])

    def test_leaves_and_allow_file(self):
        self.assertEqual(leaves({"a": {"b": [1, 2], "c": {}}}), {("a", "b"): [1, 2], ("a", "c"): {}})
        self.assertNotEqual(leaves({"a": {"b": 1}}), leaves({"a.b": 1}))
        with tempfile.TemporaryDirectory() as d:
            f = Path(d, "allow")
            f.write_text("# reviewed\nvalue r a.b\nresource r ConfigMap/ns/cfg\nvalue other x\n")
            self.assertEqual(load_allow(f, "r"), ({"a.b"}, {"ConfigMap/ns/cfg"}))
            f.write_text("bogus line\n")
            with self.assertRaises(SystemExit):
                load_allow(f, "r")


FAKE_HELM = r"""#!/usr/bin/env bash
# Fake helm: release state lives in $FAKE/state.json {revision, values, manifest}; $FAKE/render.json is what the
# chart renders now.
echo "helm $*" >> "$FAKE/log"
st="$FAKE/state.json"
case "$1" in
  repo|dependency) exit 0 ;;
  status)
    [ -n "${FAKE_STATUS_ERROR:-}" ] && { echo "Error: $FAKE_STATUS_ERROR" >&2; exit 1; }
    [ -f "$st" ] || { echo "Error: release: not found" >&2; exit 1; }
    jq '{name: "agent-relay", version: .revision, info: {status: "deployed"}, chart: {metadata: {name: "agent-relay", version: "1.0.0", appVersion: "1"}}}' "$st" ;;
  get)
    case "$2" in values) jq .values "$st" ;; manifest) jq -r .manifest "$st" ;; hooks) echo "" ;; esac ;;
  upgrade)
    if [[ " $* " == *" --dry-run=server "* ]]; then jq '{config: .values, manifest: .manifest, hooks: []}' "$FAKE/render.json"; exit 0; fi
    [ "${FAKE_UPGRADE_FAIL:-0}" = 1 ] && { echo "upgrade failed"; exit 1; }
    jq --slurpfile r "$FAKE/render.json" '.revision += 1 | .values = $r[0].values | .manifest = $r[0].manifest' "$st" > "$st.new" && mv "$st.new" "$st" ;;
  rollback) jq --arg v "$3" '.revision += 1' "$st" > "$st.new" && mv "$st.new" "$st" ;;
esac
"""

FAKE_KUBECTL = r"""#!/usr/bin/env bash
echo "kubectl $*" >> "$FAKE/log"
case "$*" in
  *"get jobs"*)
    n=$(cat "$FAKE/jobs-calls" 2>/dev/null || echo 0); echo $((n + 1)) > "$FAKE/jobs-calls"
    f="$FAKE/jobs-$n.json"; [ -f "$f" ] || f="$FAKE/jobs.json"; [ -f "$f" ] && cat "$f" || echo '{"items": []}' ;;
  *"get deploy,statefulset"*) echo '{"items": [{"kind": "Deployment", "metadata": {"name": "web"}, "spec": {"template": {"spec": {"containers": [{"image": "img:1"}]}}}}]}' ;;
  *"get secret"*) echo '{"data": {"url": "cG9zdGdyZXNxbDovL3U6U0VDUkVUUFdAaC9kYg=="}}' ;;
  *) exit 0 ;;
esac
"""

FAKE_AWS = r"""#!/usr/bin/env bash
echo "aws $*" >> "$FAKE/log"
[ "$1 $2" = "s3 cp" ] && cat > /dev/null
exit 0
"""

FAKE_PG_DUMP = r"""#!/usr/bin/env bash
echo "pg_dump called" >> "$FAKE/log"
echo DUMP
"""


class ScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        self.fake, self.bundle, self.bin = t / "fake", t / "bundle", t / "bin"
        for d in (self.fake, self.bin, self.bundle / "env", self.bundle / "infra/charts/c", self.bundle / "infra/scripts"):
            d.mkdir(parents=True)
        (self.bundle / "infra/scripts/selfhost").symlink_to(SELFHOST)
        (self.bundle / "infra/charts/c/Chart.yaml").write_text("apiVersion: v2\nname: c\nversion: 1.0.0\n")
        (self.bundle / "env/values.yaml").write_text("a: 1\n")
        for name, body in (("helm", FAKE_HELM), ("kubectl", FAKE_KUBECTL), ("aws", FAKE_AWS), ("pg_dump", FAKE_PG_DUMP),
                           ("curl", "#!/bin/sh\necho \"curl $*\" >> \"$FAKE/log\"\nprintf %s \"${FAKE_HTTP:-200}\"\n")):
            p = self.bin / name
            p.write_text(body)
            p.chmod(0o755)
        self.config({"type": "none"})
        self.state({"a": 1}, DEPLOY)
        self.render({"a": 1}, DEPLOY)

    def tearDown(self):
        self.tmp.cleanup()

    def config(self, snapshot):
        (self.bundle / "env/deploy.json").write_text(json.dumps({
            "environment": "test",
            "releases": [{"name": "agent-relay", "namespace": "ns", "chart": "infra/charts/c",
                          "values": ["env/values.yaml"], "timeout": "5m"}],
            "snapshot": snapshot, "health": ["https://example.test/readyz"]}))

    def state(self, values, manifest, revision=7):
        (self.fake / "state.json").write_text(json.dumps({"revision": revision, "values": values, "manifest": manifest}))

    def render(self, values, manifest):
        (self.fake / "render.json").write_text(json.dumps({"values": values, "manifest": manifest}))

    def run_script(self, mode, **env):
        report = Path(self.tmp.name) / f"report-{mode}"
        e = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "FAKE": str(self.fake),
             "REPORT_DIR": str(report), "RUN_ID": "123-1", "POLL_SECONDS": "0", "CI_DEPLOY_BUCKET": "bkt", **env}
        p = subprocess.run(["bash", str(SELFHOST / "ci-deploy.sh"), mode, str(self.bundle)],
                           capture_output=True, text=True, env=e)
        return p, report

    def log(self):
        return (self.fake / "log").read_text()

    def test_plan_no_changes(self):
        p, report = self.run_script("plan")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((report / "revisions").read_text().strip(), "agent-relay=7")
        self.assertEqual(json.loads((report / "changes.json").read_text()), {"agent-relay": False})
        self.assertIn("| agent-relay | 7 | none |", (report / "plan.md").read_text())
        self.assertFalse(list(report.rglob("manifest.yaml")))  # live copies removed

    def test_plan_refuses_a_drop(self):
        self.state({"a": 1, "feature": {"on": True}}, DEPLOY)
        p, report = self.run_script("plan")
        self.assertEqual(p.returncode, 3, p.stderr)
        self.assertIn("feature.on", (report / "plan.md").read_text())
        (self.bundle / "env/allow-drop.txt").write_text("value agent-relay feature\n")
        p, _ = self.run_script("plan")
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_apply_noop_does_not_upgrade(self):
        p, _ = self.run_script("apply", EXPECT_REVISIONS="agent-relay=7")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("--wait", self.log())
        self.assertIn("curl", self.log())

    def test_apply_refuses_revision_drift(self):
        p, _ = self.run_script("apply", EXPECT_REVISIONS="agent-relay=6")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("changed since the plan", p.stderr)
        self.assertNotIn("--wait", self.log())

    def test_apply_snapshots_then_upgrades(self):
        self.render({"a": 2}, DEPLOY)
        self.config({"type": "pg_dump", "databases": [{"label": "control", "namespace": "ns", "secret": "db", "key": "url"}]})
        p, report = self.run_script("apply", EXPECT_REVISIONS="agent-relay=7")
        self.assertEqual(p.returncode, 0, p.stderr)
        log = self.log()
        self.assertLess(log.index("pg_dump called"), log.index("--wait"))
        self.assertNotIn("SECRETPW", p.stderr + log + (report / "log.txt").read_text())
        self.assertIn("s3://bkt/snapshots/123-1/control.dump", (report / "snapshot").read_text())
        self.assertEqual(json.loads((self.fake / "state.json").read_text())["revision"], 8)

    def test_rds_snapshot(self):
        self.render({"a": 2}, DEPLOY)
        self.config({"type": "rds", "instance": "pg"})
        p, _ = self.run_script("apply", EXPECT_REVISIONS="agent-relay=7", CI_DEPLOY_NAME="env-deploy")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("rds create-db-snapshot --db-instance-identifier pg --db-snapshot-identifier env-deploy-123-1", self.log())

    def test_failed_upgrade_names_rollback(self):
        self.render({"a": 2}, DEPLOY)
        p, _ = self.run_script("apply", EXPECT_REVISIONS="agent-relay=7", FAKE_UPGRADE_FAIL="1")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("mode=rollback", p.stderr)

    def test_rollback(self):
        p, _ = self.run_script("rollback", ROLLBACK_RELEASE="agent-relay", ROLLBACK_REVISION="6")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("helm rollback agent-relay 6 -n ns --wait", self.log())
        p, _ = self.run_script("rollback", ROLLBACK_RELEASE="agent-relay", ROLLBACK_REVISION="6; rm")
        self.assertNotEqual(p.returncode, 0)

    def job(self, state, created="2999-01-01T00:00:00Z", release="agent-relay"):
        cond = {"done": [{"type": "Complete", "status": "True"}], "failed": [{"type": "Failed", "status": "True"}], "running": []}[state]
        return {"metadata": {"name": f"migrate-{state}", "creationTimestamp": created,
                             "annotations": {"meta.helm.sh/release-name": release}}, "status": {"conditions": cond}}

    def test_apply_waits_for_release_jobs(self):
        self.render({"a": 2}, DEPLOY)
        (self.fake / "jobs-0.json").write_text(json.dumps({"items": [self.job("running")]}))
        (self.fake / "jobs.json").write_text(json.dumps({"items": [self.job("done"), self.job("failed", release="other")]}))
        p, _ = self.run_script("apply", EXPECT_REVISIONS="agent-relay=7", JOB_TIMEOUT_SECONDS="60")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertGreaterEqual(int((self.fake / "jobs-calls").read_text()), 2)

    def test_apply_fails_on_failed_release_job(self):
        self.render({"a": 2}, DEPLOY)
        (self.fake / "jobs.json").write_text(json.dumps({"items": [self.job("failed")]}))
        p, _ = self.run_script("apply", EXPECT_REVISIONS="agent-relay=7")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("migrate-failed", p.stderr)

    def test_status_error_is_not_a_missing_release(self):
        p, _ = self.run_script("plan", FAKE_STATUS_ERROR="Kubernetes cluster unreachable")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("cluster unreachable", p.stderr)

    def test_redirect_is_not_healthy(self):
        p, _ = self.run_script("rollback", ROLLBACK_RELEASE="agent-relay", ROLLBACK_REVISION="6", FAKE_HTTP="302",
                               HEALTH_TRIES="1")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("did not return 2xx", p.stderr)

    def test_live_state_never_in_report(self):
        self.state({"db": {"pw": "LIVEPW"}}, SECRET)
        self.render({"db": {"pw": "LIVEPW"}}, "{{ bad")  # render error in the comparer path
        p, report = self.run_script("plan")
        self.assertNotEqual(p.returncode, 0)
        for f in report.rglob("*"):
            if f.is_file():
                self.assertNotIn("LIVEPW", f.read_text(errors="ignore"))
                self.assertNotIn("TElWRVBX", f.read_text(errors="ignore"))

    def test_path_outside_bundle_refused(self):
        cfg = json.loads((self.bundle / "env/deploy.json").read_text())
        cfg["releases"][0]["values"] = ["../../etc/passwd"]
        (self.bundle / "env/deploy.json").write_text(json.dumps(cfg))
        p, _ = self.run_script("plan")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("escapes the bundle", p.stderr)


class BundleTest(unittest.TestCase):
    def test_bundle_is_deterministic(self):
        with tempfile.TemporaryDirectory() as d:
            infra, env = Path(d, "infra"), Path(d, "env")
            (infra / "charts/c").mkdir(parents=True)
            (infra / "scripts/selfhost").mkdir(parents=True)
            (infra / "charts/c/Chart.yaml").write_text("name: c\n")
            (infra / "scripts/selfhost/x.sh").write_text("true\n")
            env.mkdir()
            (env / "deploy.json").write_text("{}")
            run = lambda out: subprocess.run(["bash", str(SELFHOST / "ci-deploy-run.sh"), "bundle", str(infra), str(env),
                                              str(Path(d, out))], capture_output=True, text=True, check=True).stdout.strip()
            first = run("a.tgz")
            os.utime(infra / "charts/c/Chart.yaml", (1, 1))  # a fresh checkout has other mtimes
            self.assertEqual(first, run("b.tgz"))
            self.assertRegex(first, r"^[0-9a-f]{64}$")
            (env / "deploy.json").write_text('{"x": 1}')
            self.assertNotEqual(first, run("c.tgz"))


if __name__ == "__main__":
    unittest.main()
