"""Native control image admission tests; no Docker or cluster contacted."""
import hashlib
import io
import json
import subprocess
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
import yaml
from contextlib import redirect_stdout
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import control
from stack import tenant_values


class ControlArchive(unittest.TestCase):
    def test_custom_entrypoints_are_not_silently_replaced(self):
        for section, override in (("server", {"command": ["sh"]}),
                                  ("server", {"args": ["custom.js"]}),
                                  ("migrations", {"args": ["custom-migrate.js"]})):
            with self.subTest(section=section, override=override), tempfile.TemporaryDirectory() as directory:
                state = Path(directory)
                original = {"relay-control": {section: override}}
                (state / "values.json").write_text(json.dumps(original))
                stack = SimpleNamespace(env={}, overrides=state / "values.json", check_space=Mock())
                with self.assertRaisesRegex(ValueError, "translate the custom"), patch.object(control, "checkout") as checkout:
                    control.build(stack)
                stack.check_space.assert_not_called()
                checkout.assert_not_called()
                self.assertEqual(json.loads(stack.overrides.read_text()), original)

    def test_selected_entrypoints_reach_the_rendered_api_and_migration_job(self):
        root = Path(__file__).resolve().parents[3]
        image = "agent-relay-kind/selfhost-api@sha256:" + "a" * 64
        for revision, package in ((control.REVISION, "relay-control"),
                                  (control.HISTORICAL_REVISION, "@cloud/selfhost-api")):
            with self.subTest(revision=revision), tempfile.TemporaryDirectory() as directory:
                values = {"relay-control": {"image": {
                    "repository": control.REPOSITORY, "digest": "sha256:" + "a" * 64, "pullPolicy": "Never"}}}
                control.select_local_entrypoints(values, revision)
                path = Path(directory) / "values.json"
                path.write_text(json.dumps(values))
                rendered = subprocess.run(["helm", "template", "agent-relay", "charts/agent-relay", "-n", "agent-relay",
                                           "-f", "charts/agent-relay/values-kind-core.yaml", "-f", str(path)],
                                          cwd=root, capture_output=True, text=True)
                self.assertEqual(rendered.returncode, 0, rendered.stderr)
                containers = [container for doc in yaml.safe_load_all(rendered.stdout)
                              if doc and doc.get("kind") in ("Deployment", "Job")
                              for container in doc["spec"]["template"]["spec"]["containers"]
                              if container["image"] == image]
                self.assertEqual(len(containers), 2)
                self.assertEqual({tuple(c["args"]) for c in containers}, {
                    (f"node_modules/{package}/dist/server.js",),
                    (f"node_modules/{package}/dist/migrate-cli.js",)})
                self.assertTrue(all(c["command"] == ["node"] for c in containers))

    def test_only_the_builders_legacy_image_override_is_removed(self):
        image = {"repository": control.REPOSITORY, "digest": "sha256:" + "a" * 64, "pullPolicy": "Never"}
        values = {"relay-cloud-api": {"image": image}, "relay-control": {"existingSecret": "runtime"},
                  "other": {"keep": True}}
        control.translate_local_image_override(values)
        self.assertNotIn("relay-cloud-api", values)
        self.assertEqual(values["relay-control"], {"existingSecret": "runtime"})
        self.assertEqual(values["other"], {"keep": True})
        for legacy in [{"image": image, "existingSecret": "keep"},
                       {"image": {**image, "repository": "another/image"}}, {}, False]:
            with self.subTest(legacy=legacy):
                original = {"relay-cloud-api": legacy}
                with self.assertRaises(ValueError):
                    control.translate_local_image_override(original)
                self.assertEqual(original, {"relay-cloud-api": legacy})

    def archive(self, path, *, arch="arm64", revision=control.REVISION, corrupt=False,
                include_platform=True, descriptor_arch=None, image_os="linux"):
        config = json.dumps({"architecture": arch, "os": image_os, "config": {"Labels": {
            "org.opencontainers.image.revision": revision}}}).encode()
        config_hash = hashlib.sha256(config).hexdigest()
        manifest = json.dumps({"config": {"digest": "sha256:" + config_hash}}).encode()
        digest = hashlib.sha256(manifest).hexdigest()
        descriptor = {"digest": "sha256:" + digest}
        if include_platform:
            descriptor["platform"] = {"architecture": descriptor_arch or arch, "os": "linux"}
        index = json.dumps({"manifests": [descriptor]}).encode()
        with tarfile.open(path, "w") as archive:
            for name, data in [("index.json", index), ("blobs/sha256/" + digest, manifest),
                               ("blobs/sha256/" + config_hash, config + (b" " if corrupt else b""))]:
                item = tarfile.TarInfo(name); item.size = len(data)
                archive.addfile(item, io.BytesIO(data))
        return "sha256:" + digest

    def test_bootstrap_preserves_selected_image_and_other_profile_settings(self):
        image = {"repository": control.REPOSITORY, "digest": "sha256:" + "a" * 64, "pullPolicy": "Never"}
        values = {"relay-control": {"image": image}, "global": {"otel": {"endpoint": ""}},
                  "sessions-pipeline": {"worker": {"tenant": {"orgId": "keep"}, "podAnnotations": {"keep": "yes"}}},
                  "relayflows": {"nodeSelector": {"keep": "yes"}}}
        result = tenant_values(values, {"orgId": "real-org", "workspaceId": "real-workspace"}, "addons", "arm64", "recipe")
        self.assertEqual(result["relay-control"]["image"], image)
        self.assertEqual(result["global"]["otel"], {"endpoint": ""})
        self.assertEqual(result["global"]["tenant"]["orgId"], "real-org")
        self.assertEqual(result["sessions-pipeline"]["worker"]["tenant"], {"orgId": "real-org", "workspaceId": "real-workspace"})
        self.assertEqual(result["sessions-pipeline"]["worker"]["podAnnotations"]["keep"], "yes")
        self.assertEqual(result["sessions-pipeline"]["alleyoop"]["tenant"]["orgId"], "real-org")
        self.assertEqual(result["relayflows"]["nodeSelector"], {"keep": "yes", "kubernetes.io/arch": "arm64"})

    def test_valid_native_manifest_is_pinned_by_content_not_config_or_tag(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.tar"
            digest = self.archive(path)
            receipt = control.inspect_archive(path, "arm64")
            self.assertEqual(receipt["reference"], control.REPOSITORY + "@" + digest)
            self.assertNotEqual(receipt["manifestDigest"], receipt["configDigest"])

    def test_corrupt_metadata_wrong_architecture_or_source_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.tar"
            for options in ({"corrupt": True}, {"arch": "amd64"}, {"revision": "other"}):
                with self.subTest(options=options):
                    self.archive(path, **options)
                    with self.assertRaises(ValueError):
                        control.inspect_archive(path, "arm64")

    def test_native_config_is_required_when_optional_descriptor_platform_is_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.tar"
            digest = self.archive(path, include_platform=False)
            receipt = control.inspect_archive(path, "arm64")
            self.assertEqual(receipt["manifestDigest"], digest)
            self.assertEqual(receipt["architecture"], "arm64")
            self.assertEqual(receipt["sourceRevision"], control.REVISION)
            for options in ({"arch": "amd64"}, {"image_os": "windows"},
                            {"revision": "other"}, {"corrupt": True}):
                with self.subTest(options=options):
                    self.archive(path, include_platform=False, **options)
                    with self.assertRaises(ValueError):
                        control.inspect_archive(path, "arm64")

    def test_conflicting_present_platform_is_refused_despite_native_config(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.tar"
            self.archive(path, arch="arm64", descriptor_arch="amd64")
            with self.assertRaises(ValueError):
                control.inspect_archive(path, "arm64")

    def test_current_and_historical_archive_receipts_keep_distinct_sources_and_tags(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            stack = SimpleNamespace(state=state, arch="arm64")
            for revision, repository in ((control.REVISION, "relay-control"),
                                         (control.HISTORICAL_REVISION, "relay-control-internal")):
                with self.subTest(revision=revision):
                    path = state / "image.tar"
                    self.archive(path, revision=revision)
                    receipt = control.inspect_archive(path, "arm64")
                    self.assertEqual(receipt["sourceRepository"], repository)
                    self.assertEqual(receipt["tag"], control.REPOSITORY + ":" + revision[:7])
                    (state / "control-build.json").write_text(json.dumps(receipt))
                    self.assertEqual(control.resolve(stack, receipt["reference"]), receipt["tag"])
                    del receipt["sourceRepository"]
                    (state / "control-build.json").write_text(json.dumps(receipt))
                    if revision == control.HISTORICAL_REVISION:
                        self.assertEqual(control.resolve(stack, receipt["reference"]), receipt["tag"])
                    else:
                        with self.assertRaises(ValueError):
                            control.resolve(stack, receipt["reference"])

    def test_mismatched_receipt_cannot_select_another_source_or_tag(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            self.archive(state / "image.tar")
            receipt = control.inspect_archive(state / "image.tar", "arm64")
            stack = SimpleNamespace(state=state, arch="arm64")
            for change in ({"sourceRepository": "relay-control-internal"}, {"sourceRevision": "other"},
                           {"sourceRevision": []}, {"tag": "another-tag"}, {"architecture": "amd64"},
                           {"reference": "another-image"}):
                with self.subTest(change=change):
                    (state / "control-build.json").write_text(json.dumps({**receipt, **change}))
                    with self.assertRaises(ValueError):
                        control.resolve(stack, receipt["reference"])

    def test_build_source_selection_preserves_historical_cache(self):
        for mode, revision, repository in ((None, control.REVISION, "relay-control"),
                                           ("historical", control.HISTORICAL_REVISION, "relay-control-internal")):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                state = Path(directory)
                historical = state / "control-source"
                historical.mkdir()
                (historical / "keep").write_text("existing checkout")
                def cmd(args, **kwargs):
                    if args[:3] == ["docker", "image", "save"]:
                        self.archive(Path(args[args.index("-o") + 1]), revision=revision)
                    return SimpleNamespace(returncode=0, stdout="")
                stack = SimpleNamespace(state=state, arch="arm64", env={} if mode is None else {"KIND_CONTROL_SOURCE": mode},
                                        overrides=state / "values.json", docker_args=["docker"],
                                        check_space=Mock(), cmd=Mock(side_effect=cmd))
                with patch.object(control, "checkout") as checkout, redirect_stdout(io.StringIO()):
                    control.build(stack)
                expected = historical if mode else state / ("control-source-public-" + revision[:7])
                checkout.assert_called_once_with(stack, repository, revision, expected)
                self.assertEqual((historical / "keep").read_text(), "existing checkout")
                receipt = json.loads((state / "control-build.json").read_text())
                self.assertEqual(receipt["sourceRevision"], revision)
                self.assertEqual(control.resolve(stack, receipt["reference"]), receipt["tag"])
                selected = json.loads(stack.overrides.read_text())["relay-control"]
                package = "@cloud/selfhost-api" if mode == "historical" else "relay-control"
                for section, entry in (("server", "server.js"), ("migrations", "migrate-cli.js")):
                    self.assertEqual(selected.get(section), {
                        "command": ["node"], "args": [f"node_modules/{package}/dist/{entry}"]})
                build_args = next(c.args[0] for c in stack.cmd.call_args_list if c.args[0][1:3] == ["buildx", "build"])
                self.assertIn("IMAGE_REVISION=" + revision, build_args)
                self.assertIn(control.REPOSITORY + ":" + revision[:7], build_args)

    def test_unknown_source_mode_refuses_before_any_preparation(self):
        stack = SimpleNamespace(env={"KIND_CONTROL_SOURCE": "arbitrary"})
        with self.assertRaisesRegex(ValueError, "current or historical"):
            control.build(stack)

    def test_current_build_cannot_select_a_historical_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            stack = SimpleNamespace(state=state, arch="arm64", env={}, overrides=state / "values.json",
                                    docker_args=["docker"], check_space=Mock(),
                                    cmd=Mock(return_value=SimpleNamespace(returncode=0, stdout="")))
            with patch.object(control, "checkout"), patch.object(control, "inspect_archive",
                    return_value={"sourceRevision": control.HISTORICAL_REVISION}), redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(ValueError, "differs from the selected source"):
                    control.build(stack)
            self.assertFalse(stack.overrides.exists())
            self.assertFalse((state / "control-build.json").exists())

    def test_historical_node_alias_uses_its_receipt_tag(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            self.archive(state / "image.tar", revision=control.HISTORICAL_REVISION)
            metadata = control.inspect_archive(state / "image.tar", "arm64")
            tag = "docker.io/" + metadata["tag"]
            reference = "docker.io/" + metadata["reference"]
            def cmd(args):
                if args[:3] == ["kind", "get", "nodes"]:
                    output = "test-node\n"
                elif "ls" in args:
                    self.assertEqual(args[-1], "name==" + tag)
                    output = "REF TYPE DIGEST\n" + tag + " oci " + metadata["manifestDigest"]
                elif "inspecti" in args:
                    output = json.dumps({"status": {"id": metadata["configDigest"], "repoDigests": [reference]},
                                         "info": {"imageSpec": {"architecture": "arm64"}}})
                else:
                    self.assertEqual(args[-2:], [tag, reference])
                    output = ""
                return SimpleNamespace(stdout=output)
            stack = SimpleNamespace(name="fixture", arch="arm64", docker_args=["docker"], cmd=cmd)
            control.alias(stack, metadata["reference"], metadata)


if __name__ == "__main__":
    unittest.main()
