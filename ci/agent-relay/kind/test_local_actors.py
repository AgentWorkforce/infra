import contextlib
import io
import json
import hashlib
import tarfile
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

import local_actors
from stack import StackError


class LocalActorBuildTests(unittest.TestCase):
    def fixture(self, root):
        selected = local_actors.recipe()
        state = root / "state"
        source = state / "actor-build/sources"
        for name in ("upstream", "relaycast"):
            (source / name).mkdir(parents=True)
        (source / "upstream/Dockerfile").write_text("FROM rust:1.91.0-bookworm AS builder\nRUN cargo build --locked --release\n")
        package = source / "relaycast/packages/actors-workspace/package.json"
        package.parent.mkdir(parents=True)
        package.write_text(json.dumps({"dependencies": {"durable-actors": selected["source"]["upstream"]["sdkVersion"]}}))
        calls, images = [], {}
        def command(args, **kwargs):
            args = [str(value) for value in args]
            calls.append(args)
            if args[0] == "git":
                name = Path(args[2]).name
                if args[3:] == ["rev-parse", "HEAD"]:
                    return SimpleNamespace(stdout=selected["source"][name]["revision"], returncode=0)
                if args[3:] == ["remote", "get-url", "origin"]:
                    return SimpleNamespace(stdout=selected["source"][name]["repository"], returncode=0)
                return SimpleNamespace(stdout="", returncode=0)
            if args[:2] == ["docker", "build"]:
                tag = args[args.index("-t") + 1]
                image_id = "sha256:" + ("1" if tag == selected["runtimeTag"] else "2") * 64
                Path(args[args.index("--iidfile") + 1]).write_text(image_id + "\n")
                images[tag] = image_id
                return SimpleNamespace(stdout="", returncode=0)
            if args[:3] == ["docker", "image", "inspect"]:
                value = images.get(args[3])
                return SimpleNamespace(stdout=value or "", returncode=0 if value else 1)
            return SimpleNamespace(stdout="", returncode=0)
        stack = SimpleNamespace(state=state, name="fixture", docker_args=["docker"], cmd=command)
        return selected, stack, calls, images

    def test_build_orders_pinned_source_checks_and_records_real_image_id_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            selected, stack, calls, images = self.fixture(Path(tmp))
            with contextlib.redirect_stdout(io.StringIO()) as output:
                built = local_actors.build(stack, selected)
            self.assertEqual(built["actorImageId"], images[selected["actorTag"]])
            self.assertEqual(built["upstreamRevision"], selected["source"]["upstream"]["revision"])
            self.assertIn("not published registry digests", output.getvalue())
            builds = [c for c in calls if c[:2] == ["docker", "build"]]
            self.assertEqual(len(builds), 2)
            self.assertIn("typescript", builds[0])
            self.assertIn("ARG CARGO_BUILD_JOBS=2", (stack.state / "actor-build/upstream.Dockerfile").read_text())
            self.assertIn("DURABLE_ACTORS_TYPESCRIPT_IMAGE=" + selected["runtimeTag"], builds[1])
            self.assertTrue(all(calls.index(c) < calls.index(builds[0]) for c in calls if c[0] == "git"))
            self.assertEqual((stack.state / "actor-build/images.json").stat().st_mode & 0o777, 0o600)
            before = len(builds)
            with contextlib.redirect_stdout(io.StringIO()):
                again = local_actors.build(stack, selected)
            self.assertEqual(built, again)
            self.assertEqual(len([c for c in calls if c[:2] == ["docker", "build"]]), before)

    def test_missing_or_changed_local_image_is_rebuilt_instead_of_reusing_receipt(self):
        with tempfile.TemporaryDirectory() as tmp:
            selected, stack, calls, images = self.fixture(Path(tmp))
            with contextlib.redirect_stdout(io.StringIO()):
                local_actors.build(stack, selected)
                images[selected["actorTag"]] = "sha256:" + "f" * 64
                built = local_actors.build(stack, selected)
            self.assertEqual(built["actorImageId"], "sha256:" + "2" * 64)
            self.assertEqual(len([c for c in calls if c[:2] == ["docker", "build"]]), 4)

    def test_source_drift_is_refused_before_any_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            selected, stack, calls, _ = self.fixture(Path(tmp))
            original = stack.cmd
            def drift(args, **kwargs):
                if [str(a) for a in args][-2:] == ["rev-parse", "HEAD"]:
                    return SimpleNamespace(stdout="f" * 40, returncode=0)
                return original(args, **kwargs)
            stack.cmd = drift
            with self.assertRaisesRegex(StackError, "no checkout is overwritten"):
                local_actors.build(stack, selected)
            self.assertFalse(any(c[:2] == ["docker", "build"] for c in calls))

    def test_actor_sdk_must_match_upstream_pin(self):
        with tempfile.TemporaryDirectory() as tmp:
            selected, stack, calls, _ = self.fixture(Path(tmp))
            path = stack.state / "actor-build/sources/relaycast/packages/actors-workspace/package.json"
            path.write_text(json.dumps({"dependencies": {"durable-actors": "unexpected"}}))
            with self.assertRaisesRegex(StackError, "SDK does not match"):
                local_actors.build(stack, selected)
            self.assertFalse(any(c[:2] == ["docker", "build"] for c in calls))

    def test_import_binds_cri_digest_to_built_image_and_rejects_another_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            selected, stack, calls, _ = self.fixture(Path(tmp))
            with contextlib.redirect_stdout(io.StringIO()):
                built = local_actors.build(stack, selected)
            digest = "docker.io/local/relaycast-actors-dev@sha256:" + "3" * 64
            built["actorConfigId"] = "sha256:" + "4" * 64
            status = {"id": built["actorConfigId"], "repoDigests": [digest]}
            original = stack.cmd
            def command(args, **kwargs):
                if args[:3] == ["kind", "get", "nodes"]:
                    return SimpleNamespace(stdout="owned-node\n", returncode=0)
                if args[:2] == ["docker", "exec"]:
                    return SimpleNamespace(stdout=json.dumps({"status": status}), returncode=0)
                return original(args, **kwargs)
            stack.cmd = command
            local_actors.load(stack, built)
            self.assertEqual(built["kindImages"]["owned-node"]["repoDigests"], [digest])
            status["id"] = "sha256:" + "f" * 64
            with self.assertRaisesRegex(StackError, "differs from the local build"):
                local_actors.load(stack, built)

    def test_export_binds_a_different_config_digest_and_refuses_tag_races(self):
        with tempfile.TemporaryDirectory() as tmp:
            selected, stack, calls, images = self.fixture(Path(tmp))
            with contextlib.redirect_stdout(io.StringIO()):
                built = local_actors.build(stack, selected)
            config = b'{"architecture":"arm64","config":{"Env":["FIXTURE=1"]}}'
            original = stack.cmd
            def command(args, **kwargs):
                if args[:3] == ["docker", "image", "save"]:
                    with tarfile.open(args[4], "w") as saved:
                        for name, data in (("manifest.json", b'[{"Config":"config.json"}]'), ("config.json", config)):
                            info = tarfile.TarInfo(name);info.size = len(data);saved.addfile(info, io.BytesIO(data))
                    return SimpleNamespace(stdout="", returncode=0)
                return original(args, **kwargs)
            stack.cmd = command
            observed = local_actors.config_id(stack, built)
            self.assertEqual(observed, "sha256:" + hashlib.sha256(config).hexdigest())
            self.assertNotEqual(observed, built["actorImageId"])
            self.assertFalse((stack.state / "actor-build/actor-image.tar").exists())
            del built["actorConfigId"]
            images[built["actorTag"]] = "sha256:" + "f" * 64
            with self.assertRaisesRegex(StackError, "changed during export"):
                local_actors.config_id(stack, built)


if __name__ == "__main__":
    unittest.main()
