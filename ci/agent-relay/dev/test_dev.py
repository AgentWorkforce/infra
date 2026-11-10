import copy
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import dev


def deployment(name="app", uid="owned-app"):
    return {"metadata": {"name": name, "uid": uid, "resourceVersion": "7"},
            "spec": {"replicas": 1, "selector": {"matchLabels": {"app": name}},
                     "template": {"metadata": {"labels": {"app": name}}, "spec": {
                         "containers": [{"name": "server", "image": "example/app@sha256:" + "a" * 64,
                                         "env": [{"name": "DATABASE_URL", "valueFrom": {"secretKeyRef": {
                                             "name": "runtime", "key": "url"}}}],
                                         "securityContext": {"readOnlyRootFilesystem": True},
                                         "volumeMounts": [{"name": "html", "mountPath": "/usr/share/nginx/html"}]}],
                         "volumes": [{"name": "html", "emptyDir": {"sizeLimit": "32Mi"}}]}}},
            "status": {"availableReplicas": 1}}


class MemoryCluster:
    def __init__(self, docs):
        self.docs = docs
        self.patched = []
        self.ready_calls = []
        self.target_calls = 0

    def target(self): self.target_calls += 1
    def inventory(self): return self.docs
    def get(self, kind, name): return copy.deepcopy(self.docs[name])
    def ready(self, name): self.ready_calls.append(name)
    def patch(self, doc, spec):
        current = self.docs[doc["metadata"]["name"]]
        if current["metadata"] != doc["metadata"] or current["spec"] != doc["spec"]:
            raise dev.Refused("cas_conflict")
        self.patched.append((doc["metadata"]["name"], copy.deepcopy(spec)))
        current["spec"] = copy.deepcopy(spec)


class FakeCommands:
    def __init__(self): self.calls = []
    def json(self, argv):
        self.calls.append(argv)
        return {"ID": "engine"}


class DevTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.cmd = FakeCommands()

    def tearDown(self): self.tmp.cleanup()

    def session(self, docs):
        plan = {"engineId": "engine", "targets": {n: dev.identity(d) for n, d in docs.items()}, "protected": {}}
        session = dev.Session({"docker": "docker"}, plan, self.cmd, self.root / "journal")
        session.k = MemoryCluster(copy.deepcopy(docs))
        return session

    def test_backend_apply_changes_only_named_container_image_and_pull_policy(self):
        original = deployment()
        s = self.session({"app": original})
        group = {"mode": "rebuild", "targets": [{"deployment": "app", "container": "server", "role": "control"}]}
        s.apply(group, "agent-relay-dev/control:nonce")
        expected = copy.deepcopy(original["spec"])
        expected["template"]["spec"]["containers"][0].update(image="agent-relay-dev/control:nonce", imagePullPolicy="Never")
        self.assertEqual(s.k.docs["app"]["spec"], expected)
        self.assertEqual(s.k.ready_calls, ["app"])
        # Receipt contains hashes/images, not the original environment/Secret refs.
        raw = next((self.root / "journal").glob("*.json")).read_text()
        self.assertNotIn("DATABASE_URL", raw)
        self.assertNotIn("runtime", raw)
        self.assertTrue(s.restore())
        self.assertEqual(s.k.docs["app"]["spec"], original["spec"])

    def backend_group(self):
        return {"name": "control", "mode": "rebuild", "targets": [{"deployment": "app", "container": "server", "role": "control"}]}

    def test_failed_second_patch_preserves_last_confirmed_ownership_and_restores(self):
        s = self.session({"app": deployment()})
        s.apply(self.backend_group(), "dev:first")
        confirmed = copy.deepcopy(s.applied["app"])
        original_patch = s.k.patch
        s.k.patch = lambda *_: (_ for _ in ()).throw(dev.Refused("transport_failed_before_patch"))
        with self.assertRaisesRegex(dev.Refused, "transport_failed"):
            s.apply(self.backend_group(), "dev:second")
        self.assertEqual(s.applied["app"], confirmed)
        s.k.patch = original_patch
        self.assertTrue(s.restore())
        self.assertEqual(s.k.docs["app"]["spec"], deployment()["spec"])

    def test_stop_after_second_journal_preserves_last_confirmed_spec(self):
        s = self.session({"app": deployment()})
        s.apply(self.backend_group(), "dev:first")
        confirmed = copy.deepcopy(s.applied["app"])
        def stop_before_patch(*_): s.stopping = True
        with patch.object(dev, "save", side_effect=stop_before_patch):
            s.apply(self.backend_group(), "dev:second")
        self.assertEqual(s.applied["app"], confirmed)
        self.assertNotIn("app", s.pending)
        self.assertTrue(s.restore())
        self.assertEqual(s.k.docs["app"]["spec"], deployment()["spec"])

    def test_unknown_patch_response_accepts_only_exact_inflight_or_confirmed_spec(self):
        for foreign_drift in (False, True):
            s = self.session({"app": deployment()})
            s.apply(self.backend_group(), "dev:first")
            original_patch = s.k.patch
            def applied_but_response_lost(doc, spec):
                original_patch(doc, spec)
                if foreign_drift: s.k.docs["app"]["spec"]["replicas"] = 0
                raise dev.Refused("patch_response_lost")
            s.k.patch = applied_but_response_lost
            with self.assertRaisesRegex(dev.Refused, "patch_response_lost"):
                s.apply(self.backend_group(), "dev:second")
            self.assertEqual(s.applied["app"]["template"]["spec"]["containers"][0]["image"], "dev:first")
            s.k.patch = original_patch
            self.assertEqual(s.restore(), not foreign_drift)
            if not foreign_drift: self.assertEqual(s.k.docs["app"]["spec"], deployment()["spec"])
            else: self.assertEqual(s.k.docs["app"]["spec"]["replicas"], 0)

    def test_foreign_uid_refuses_before_patch(self):
        s = self.session({"app": deployment()})
        s.k.docs["app"]["metadata"]["uid"] = "replacement"
        with self.assertRaisesRegex(dev.Refused, "workload_drift"):
            s.apply({"mode": "rebuild", "targets": [{"deployment": "app"}]}, "dev:1")
        self.assertEqual(s.k.patched, [])

    def test_unrelated_spec_drift_refuses_before_patch(self):
        s = self.session({"app": deployment()})
        s.k.docs["app"]["spec"]["replicas"] = 0
        with self.assertRaisesRegex(dev.Refused, "workload_drift"): s.guard()
        self.assertEqual(s.k.patched, [])

    def test_engine_drift_refuses(self):
        s = self.session({"app": deployment()})
        self.cmd.json = lambda _: {"ID": "other-engine"}
        with self.assertRaisesRegex(dev.Refused, "engine_changed"): s.guard()

    def test_restore_continues_after_other_target_drift(self):
        s = self.session({"a": deployment("a", "uid-a"), "b": deployment("b", "uid-b")})
        for n in ("a", "b"):
            before = copy.deepcopy(s.k.docs[n]["spec"])
            after = copy.deepcopy(before); after["template"]["spec"]["containers"][0]["image"] = "dev:1"
            s.original[n] = before; s.applied[n] = after; s.k.docs[n]["spec"] = copy.deepcopy(after)
        s.k.docs["b"]["spec"]["replicas"] = 0
        self.assertFalse(s.restore())
        self.assertEqual([n for n, _ in s.k.patched], ["a"])
        self.assertEqual(s.k.docs["b"]["spec"]["replicas"], 0)

    def test_no_effect_patch_failure_needs_no_restore_change(self):
        s = self.session({"app": deployment()})
        s.original["app"] = copy.deepcopy(s.k.docs["app"]["spec"])
        s.applied["app"] = {"changed": True}
        self.assertTrue(s.restore())
        self.assertEqual(s.k.patched, [])

    def test_cluster_patch_tests_uid_resource_version_and_full_spec(self):
        calls = []
        class C:
            def run(self, argv, data, timeout): calls.append((argv, json.loads(data))); return b""
        k = dev.Cluster({"kubectl": "kubectl", "kubeconfig": "owned", "context": "kind-dev", "namespace": "dev"}, C())
        d = deployment(); after = copy.deepcopy(d["spec"]); after["replicas"] = 0
        k.patch(d, after)
        argv, p = calls[0]
        self.assertIn("--patch-file=/dev/stdin", argv)
        self.assertEqual([x["path"] for x in p[:3]], ["/metadata/uid", "/metadata/resourceVersion", "/spec"])
        self.assertEqual(p[2]["value"], d["spec"])

    def test_frontend_overlay_preserves_auth_tls_storage_and_init(self):
        d = deployment(); spec = copy.deepcopy(d["spec"])
        spec["template"]["spec"]["initContainers"] = [{"name": "seed", "image": "approved:old"}]
        baseline = copy.deepcopy(spec)
        changed = dev.frontend_spec(spec, {"container": "server"}, "dev:hmr")
        pod = changed["template"]["spec"]; c = pod["containers"][0]
        self.assertEqual(pod["initContainers"], baseline["template"]["spec"]["initContainers"])
        self.assertEqual(c["env"], baseline["template"]["spec"]["containers"][0]["env"])
        self.assertTrue(c["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(pod["volumes"][-1], {"name": "kind-dev-source", "emptyDir": {"sizeLimit": "256Mi"}})
        self.assertNotIn("args", c)
        self.assertEqual(c["resources"]["limits"]["memory"], "1Gi")

    def test_frontend_api_omits_empty_args_and_restore_still_succeeds(self):
        s = self.session({"app": deployment()})
        original_patch = s.k.patch
        def omit_arrays(doc, spec):
            original_patch(doc, spec)
            for c in s.k.docs["app"]["spec"]["template"]["spec"]["containers"]:
                if c.get("args") == []: c.pop("args")
        s.k.patch = omit_arrays
        s.apply({"mode": "frontend-hmr", "targets": [{"deployment": "app", "container": "server", "role": "webapp"}]}, "dev:hmr")
        self.assertTrue(s.restore())
        self.assertEqual(s.k.docs["app"]["spec"], deployment()["spec"])

    def test_compiler_metadata_never_echoes_messages_source_or_values(self):
        raw = b'src/app.ts(12,3): error TS2322: token "SECRET_EXAMPLE" not assignable\npassword=PRIVATE\nhttps://secret/path\n'
        self.assertEqual(dev.compiler_diagnostics(raw), [{"file": "src/app.ts", "line": 12, "column": 3, "code": "TS2322"}])

    def test_admission_binds_exact_plan_config_and_containment(self):
        c = {"admissionFile": str(self.root / "admission.json")}; p = {"originalUid": "owned"}
        dev.admission({}, p)  # Explicit ordinary development needs no external approval file.
        with self.assertRaisesRegex(dev.Refused, "external_dev_admission_required"): dev.admission(c, p)
        a = {"result": "APPROVED_LOCAL_KIND_DEV_SESSION", "containmentCleared": True,
             "configSha256": dev.digest(c), "planSha256": dev.digest(p), "approvedAt": int(dev.time.time())}
        (self.root / "admission.json").write_text(json.dumps(a))
        dev.admission(c, p)
        with self.assertRaisesRegex(dev.Refused, "admission_binding_changed"): dev.admission(c, {"originalUid": "other"})
        a["containmentCleared"] = False
        (self.root / "admission.json").write_text(json.dumps(a))
        with self.assertRaisesRegex(dev.Refused, "containment_not_cleared"): dev.admission(c, p)

    def test_frontend_refuses_preexisting_dev_volume(self):
        spec = deployment()["spec"]; spec["template"]["spec"]["volumes"].append({"name": "kind-dev-source", "hostPath": {"path": "/"}})
        with self.assertRaisesRegex(dev.Refused, "dev_volume_already_present"):
            dev.frontend_spec(spec, {"container": "server"}, "dev:hmr")

    def test_schema_scrubber_lock_changes_are_not_hot_reloaded(self):
        base = {"src/server.ts": b"v1", "supabase/migrations/001.sql": b"v1", "package-lock.json": b"v1",
                "src/shared/scrub.ts": b"v1", "docker/40-runtime-config.sh": b"v1"}
        initial = dev.digest(dev.protected_source(base))
        code = dict(base, **{"src/server.ts": b"v2"})
        self.assertEqual(initial, dev.digest(dev.protected_source(code)))
        for key in set(base) - {"src/server.ts"}:
            changed = dict(base); changed[key] = b"v2"
            self.assertNotEqual(initial, dev.digest(dev.protected_source(changed)), key)

    def test_context_contains_only_supplied_source_and_preserves_executable(self):
        (self.root / "run.sh").write_text("#!/bin/sh\n")
        (self.root / "run.sh").chmod(0o755)
        archive = dev.context_archive({"run.sh": b"#!/bin/sh\n", "src/main.ts": b"ok"}, repo=self.root)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            self.assertEqual(tar.getnames(), ["run.sh", "src/main.ts"])
            self.assertEqual(tar.getmember("run.sh").mode, 0o755)

    def test_actual_git_ignored_credentials_are_not_archived(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / ".gitignore").write_text(".env\n")
        (self.root / ".env").write_text("PRIVATE_SYNTHETIC_DO_NOT_SEND=1")
        (self.root / "main.ts").write_text("ok")
        files = dev.source_files(self.root.resolve(), dev.Commands())
        self.assertNotIn(".env", files)
        self.assertIn("main.ts", files)

    def test_actual_git_tracked_credential_file_refuses(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / ".env").write_text("SYNTHETIC=1")
        subprocess.run(["git", "-C", str(self.root), "add", ".env"], check=True)
        with self.assertRaisesRegex(dev.Refused, "credential_file_in_context"):
            dev.source_files(self.root.resolve(), dev.Commands())

    def test_source_symlink_refuses_instead_of_copying_host_file(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / "outside").symlink_to("/etc/hosts")
        with self.assertRaisesRegex(dev.Refused, "source_symlink_refused"):
            dev.source_files(self.root.resolve(), dev.Commands())

    def test_source_digest_requires_exact_repo_root(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        sub = self.root / "sub"; sub.mkdir()
        with self.assertRaisesRegex(dev.Refused, "source_is_not_git_root"):
            dev.source_files(sub, dev.Commands())

    def commit_fixture(self):
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.root), "-c", "user.name=Dev Test", "-c", "user.email=dev@example.invalid",
                        "commit", "-qm", "synthetic public fixtures"], check=True)

    def test_committed_public_key_fixture_and_code_header_literal_are_supported(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        fixture = self.root / "test/fixtures/test-only.key"; fixture.parent.mkdir(parents=True)
        fixture.write_text("-----BEGIN PRIVATE KEY-----\nsynthetic-not-a-key\n")
        (self.root / "crypto.ts").write_text('const header = "-----BEGIN PRIVATE KEY-----";')
        self.commit_fixture()
        files = dev.source_files(self.root.resolve(), dev.Commands())
        self.assertIn("test/fixtures/test-only.key", files)
        self.assertIn("crypto.ts", files)
        fixture.write_text("-----BEGIN PRIVATE KEY-----\nnew-local-credential\n")
        with self.assertRaisesRegex(dev.Refused, "credential_file_in_context"):
            dev.source_files(self.root.resolve(), dev.Commands())

    def test_gitlinks_are_excluded_but_explicit_docker_submodule_dependency_refuses(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "update-index", "--add", "--cacheinfo", "160000," + "a" * 40 + ",vendor/example"], check=True)
        (self.root / "Dockerfile").write_text("FROM pinned\nCOPY src src\n")
        files = dev.source_files(self.root.resolve(), dev.Commands())
        self.assertNotIn("vendor/example", files)
        self.assertEqual(files.gitlinks, ["vendor/example"])
        dev.validate_dockerfile(files, "Dockerfile")
        files["Dockerfile"] = b"FROM pinned\nCOPY vendor/example /app/vendor\n"
        with self.assertRaisesRegex(dev.Refused, "submodule_context_unsupported"):
            dev.validate_dockerfile(files, "Dockerfile")

    def test_frontend_one_file_edit_syncs_only_that_file_and_readme_is_noop(self):
        s = self.session({"app": deployment()})
        calls = []
        s.guard = lambda: {}
        def get(kind, name=None):
            if kind == "deployment": return deployment()
            if kind == "replicasets": return {"items": [{"metadata": {"uid": "rs", "ownerReferences": [{"uid": "owned-app"}]}}]}
            if kind == "pods": return {"items": [{"metadata": {"name": "pod", "uid": "pod-uid", "ownerReferences": [{"uid": "rs"}]},
                                                   "spec": {"containers": deployment()["spec"]["template"]["spec"]["containers"]},
                                                   "status": {"containerStatuses": [{"name": "server", "ready": True, "containerID": "containerd://owned", "restartCount": 0}]}}]}
            self.fail(kind)
        s.k.get = get
        s.k.k = lambda *args, data: calls.append(json.loads(data))
        group = {"name": "webapp", "targets": [{"deployment": "app", "container": "server"}]}
        before = {"src/App.tsx": b"old", "src/other.ts": b"same", "README.md": b"old"}
        after = dict(before, **{"src/App.tsx": b"new"})
        s.sync(group, before, after)
        self.assertEqual(set(calls[0]["files"]), {"src/App.tsx"})
        s.sync(group, after, dict(after, **{"README.md": b"new"}))
        self.assertEqual(len(calls), 1)

    def test_frontend_restart_replays_latest_files_and_deletions_without_new_edit(self):
        for replacement in (False, True):
            s = self.session({"app": deployment()}); s.guard = lambda: {}
            group = {"name": "webapp", "targets": [{"deployment": "app", "container": "server"}]}
            seed = {"src/App.tsx": b"image-old", "src/deleted-from-seed.ts": b"seed"}
            previous = {"src/App.tsx": b"host-new", "src/removed-after-add.ts": b"previous"}
            current = {"src/App.tsx": b"host-new", "src/new.ts": b"new"}
            old_identity = {"podUid": "old-pod", "containerId": "containerd://old", "restartCount": 0}
            new_identity = {"podUid": "new-pod" if replacement else "old-pod", "containerId": "containerd://new", "restartCount": 0 if replacement else 1}
            s.frontend_seeds["webapp"] = seed; s.frontend_instances["webapp"] = old_identity
            s.frontend_pod = lambda _: ("running-pod", new_identity)
            sent = []; s.k.k = lambda *args, data: sent.append(json.loads(data))
            self.assertTrue(s.frontend_replay(group, previous, current))
            self.assertEqual(set(sent[0]["files"]), {"src/App.tsx", "src/new.ts"})
            self.assertEqual(set(sent[0]["removed"]), {"src/deleted-from-seed.ts", "src/removed-after-add.ts"})
            self.assertEqual(s.frontend_instances["webapp"], new_identity)
            self.assertFalse(s.frontend_replay(group, current, current))
            self.assertEqual(len(sent), 1)

    def test_frontend_replay_does_not_sync_after_stop(self):
        s = self.session({"app": deployment()}); s.stopping = True
        s.frontend_pod = lambda _: ("pod", {"podUid": "new"})
        s.k.k = lambda *args, **kwargs: self.fail("exec after stop")
        self.assertFalse(s.frontend_replay({"name": "webapp"}, {}, {"src/a.ts": b"new"}))

    def frontend_pod_get(self, ready_after=1, foreign_owner=False):
        queries = []
        def get(kind, name=None):
            if kind == "deployment": return deployment()
            if kind == "replicasets": return {"items": [{"metadata": {"uid": "rs", "ownerReferences": [{"uid": "owned-app"}]}}]}
            if kind == "pods":
                queries.append(1)
                return {"items": [{"metadata": {"name": "pod", "uid": "pod-uid", "ownerReferences": [{"uid": "other" if foreign_owner else "rs"}]},
                                   "spec": {"containers": deployment()["spec"]["template"]["spec"]["containers"]},
                                   "status": {"containerStatuses": [{"name": "server", "ready": len(queries) >= ready_after,
                                                                      "containerID": "containerd://new", "restartCount": 1}]}}]}
            self.fail(kind)
        return get, queries

    def test_frontend_pod_waits_for_actual_container_ready_before_replay(self):
        s = self.session({"app": deployment()})
        s.k.get, queries = self.frontend_pod_get(ready_after=2)
        with patch.object(dev.time, "sleep") as sleep:
            running = s.frontend_pod({"targets": [{"deployment": "app", "container": "server"}]})
        self.assertEqual(len(queries), 2)
        sleep.assert_called_once_with(1)
        self.assertEqual(running, ("pod", {"podUid": "pod-uid", "containerId": "containerd://new", "restartCount": 1}))

    def test_frontend_ready_wait_is_bounded_and_never_accepts_foreign_owner(self):
        s = self.session({"app": deployment()})
        s.k.get, queries = self.frontend_pod_get(foreign_owner=True)
        with patch.object(dev.time, "monotonic", side_effect=[0, 181]), self.assertRaisesRegex(dev.Refused, "frontend_owned_pod_required"):
            s.frontend_pod({"targets": [{"deployment": "app", "container": "server"}]})
        self.assertEqual(len(queries), 1)

    def test_stop_requested_during_build_prevents_new_apply_effects(self):
        s = self.session({"app": deployment()})
        # Model the return boundary after a long successful build, where SIGTERM
        # has set the flag. apply must not inspect/patch any new target.
        s.stopping = True
        s.apply({"mode": "rebuild", "targets": [{"deployment": "app", "container": "server", "role": "control"}]}, "dev:built")
        self.assertEqual(s.k.patched, [])

    def test_subset_selection_protects_every_nonselected_target(self):
        c = {"protectedDeployments": ["database"], "groups": [
            {"name": "webapp", "targets": [{"role": "webapp", "deployment": "dashboard"}]},
            {"name": "pipeline", "sourceUnavailable": True, "targets": [{"role": "consumer", "deployment": "contained-consumer"}]},
            {"name": "control", "targets": [{"role": "control", "deployment": "api"}, {"role": "collector", "deployment": "telemetry"}]}]}
        s = dev.select_components(c, "webapp")
        self.assertEqual([g["name"] for g in s["groups"]], ["webapp"])
        self.assertEqual(s["protectedDeployments"], ["api", "contained-consumer", "database", "telemetry"])
        self.assertEqual(len(dev.select_components(c, "control")["groups"][0]["targets"]), 2)
        self.assertEqual(dev.select_components(c, "collector")["groups"][0]["targets"], [{"role": "collector", "deployment": "telemetry"}])
        with self.assertRaisesRegex(dev.Refused, "unknown_component_selection"): dev.select_components(c, "unknown")

    def test_run_without_explicit_plan_creates_a_new_plan_each_launch(self):
        config = {"dockerContext": "owned"}
        plans, runs = [], []
        def prepare(*_):
            plan = {"configSha256": dev.digest(config), "targets": {}, "preparedAt": len(plans)}
            plans.append(plan); return plan
        class Session:
            def __init__(self, c, p, cmd, state): self.plan = p
            def run(self): runs.append(self.plan)
        argv = ["dev.py", "run", "--state", str(self.root / "runs")]
        with patch.object(dev.sys, "argv", argv), patch.object(dev, "load_config", return_value=config), \
             patch.object(dev, "select_components", return_value=config), patch.object(dev, "prepare", side_effect=prepare), \
             patch.object(dev, "Session", Session):
            dev.main(); dev.main()
        self.assertEqual(len(plans), 2)
        self.assertEqual(len(list((self.root / "runs").glob("*/plan.json"))), 2)
        self.assertEqual(runs, plans)

    def test_stop_between_group_targets_does_not_roll_out_second_target(self):
        s = self.session({"a": deployment("a", "uid-a"), "b": deployment("b", "uid-b")})
        old_ready = s.k.ready
        def ready_and_stop(name): old_ready(name); s.stopping = True
        s.k.ready = ready_and_stop
        group = {"mode": "rebuild", "targets": [{"deployment": n, "container": "server", "role": n} for n in ("a", "b")]}
        s.apply(group, "dev:built")
        self.assertEqual([n for n, _ in s.k.patched], ["a"])

    def test_immutable_private_plan_never_overwrites(self):
        path = self.root / "plan.json"
        dev.save(path, {"a": 1})
        with self.assertRaises(FileExistsError): dev.save(path, {"a": 2})
        self.assertEqual(json.loads(path.read_text()), {"a": 1})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def git_prepare_fixture(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        for name, data in {"src/main.ts": "initial code", "Dockerfile": "FROM pinned",
                           "supabase/migrations/001.sql": "initial sql", "package-lock.json": "initial lock",
                           "src/shared/scrub.ts": "initial scrub"}.items():
            path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(data)
        self.commit_fixture()
        command = dev.Commands()
        baseline = command.run(["git", "-C", self.root, "rev-parse", "HEAD"]).decode().strip()
        config = {"groups": [{"name": "control", "repo": str(self.root.resolve()), "baselineRevision": baseline,
                              "mode": "rebuild", "protectedSourceSha256": dev.digest(dev.protected_source(dev.source_files(self.root.resolve(), command))),
                              "targets": [{"deployment": "app", "container": "server", "uid": "owned-app",
                                           "image": deployment()["spec"]["template"]["spec"]["containers"][0]["image"],
                                           "reviewedInitSha256": dev.digest([])}]}],
                  "protectedDeployments": ["database"], "docker": "docker", "architecture": "arm64", "cluster": "owned"}
        effects = []
        class Commands(dev.Commands):
            def run(self, argv, *args, **kwargs):
                if argv[0] != "git": raise AssertionError("non-Git command attempted")
                return super().run(argv, *args, **kwargs)
            def json(self, argv):
                if argv[1] == "info": return {"ID": "engine", "OSType": "linux", "Architecture": "aarch64"}
                return [{"Id": "node-full-id", "State": {"Running": True},
                         "Config": {"Labels": {"io.x-k8s.kind.cluster": "owned"}}}]
        class Cluster(MemoryCluster):
            def __init__(self, *args):
                super().__init__({"app": deployment(), "database": deployment("database", "db-owned")})
            def get(self, kind, name=None):
                if kind == "nodes": return {"items": [{"metadata": {"name": "owned-control-plane", "uid": "node-uid"}}]}
                return super().get(kind, name)
            def patch(self, *args): effects.append("patch"); return super().patch(*args)
        return config, Commands(), Cluster, effects

    def test_real_source_only_commit_allows_fresh_prepare_and_records_actual_head(self):
        config, cmd, cluster, _ = self.git_prepare_fixture()
        with patch.object(dev, "Cluster", cluster):
            initial = dev.prepare(config, cmd)
            (self.root / "src/main.ts").write_text("new source-only code")
            self.commit_fixture()
            fresh = dev.prepare(config, cmd)
        current = cmd.run(["git", "-C", self.root, "rev-parse", "HEAD"]).decode().strip()
        self.assertNotEqual(initial["sourceHeads"]["control"], current)
        self.assertEqual(fresh["sourceHeads"]["control"], current)
        self.assertEqual(config["groups"][0]["baselineRevision"], initial["sourceHeads"]["control"])
        self.assertEqual(initial["configSha256"], fresh["configSha256"])

    def test_real_protected_sql_dependency_and_scrub_commits_still_refuse(self):
        config, cmd, cluster, _ = self.git_prepare_fixture()
        for name in ("supabase/migrations/001.sql", "package-lock.json", "src/shared/scrub.ts"):
            path = self.root / name; original = path.read_text(); path.write_text("changed protected content")
            self.commit_fixture()
            with patch.object(dev, "Cluster", cluster), self.assertRaisesRegex(dev.Refused, "source_admission_required"):
                dev.prepare(config, cmd)
            path.write_text(original); self.commit_fixture()

    def test_explicit_frozen_plan_refuses_a_later_source_commit_before_effects(self):
        config, cmd, cluster, effects = self.git_prepare_fixture()
        with patch.object(dev, "Cluster", cluster):
            plan = dev.prepare(config, cmd)
            (self.root / "src/main.ts").write_text("new source-only code")
            self.commit_fixture()
            session = dev.Session(config, plan, cmd, self.root / "journal")
            with self.assertRaisesRegex(dev.Refused, "plan_changed"):
                session.run()
        self.assertEqual(effects, [])


if __name__ == "__main__": unittest.main()
