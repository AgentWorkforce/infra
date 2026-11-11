"""Real certificate/key and state-isolation checks for opt-in CA retention."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import local_ca
from local_stack import LocalStack
from stack import StackError
import tls


class RetainedCaTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.store = self.root / "retained"
        self.state = self.root / "state"
        self.state.mkdir(mode=0o700)
        self.commands = []
        self.stack = SimpleNamespace(state=self.state, cmd=self.command, apply=lambda doc: None)
        for mock in (patch.dict(os.environ, {"LOCAL_CA_REUSE": "1", "LOCAL_CA_REUSE_DIR": str(self.store)}),
                patch.object(local_ca.sys, "platform", "linux")):
            mock.start()
            self.addCleanup(mock.stop)

    def command(self, args, **kwargs):
        self.commands.append([str(a) for a in args])
        return subprocess.run([str(a) for a in args], capture_output=True, text=True, check=kwargs.get("check", True))

    def initial_ca(self):
        tls.create(self.stack, ["relay.kind.agentrelay.com"], "agent-relay")

    def test_default_never_reads_or_imports_retained_state(self):
        with patch.dict(os.environ, {"LOCAL_CA_REUSE": "0"}):
            self.assertFalse(local_ca.prepare(self.stack))
        self.assertEqual(list(self.state.iterdir()), [])
        self.assertFalse(self.store.exists())

    def test_rebuild_imports_only_same_ca_and_mints_new_leaf(self):
        self.initial_ca()
        ca = (self.state / "ca.crt").read_bytes()
        old_leaf = (self.state / "tls.crt").read_bytes()
        (self.state / "credentials.json").write_text('{"fixture":"old data"}')
        self.assertTrue(local_ca.prepare(self.stack))
        self.assertEqual({p.name for p in self.store.iterdir()}, set(local_ca.FILES))
        self.assertEqual((self.store / "ca.key").stat().st_mode & 0o777, 0o600)
        shutil.rmtree(self.state)
        self.state.mkdir(mode=0o700)
        self.assertTrue(local_ca.prepare(self.stack))
        self.assertEqual({p.name for p in self.state.iterdir()}, set(local_ca.FILES))
        tls.create(self.stack, ["relay.kind.agentrelay.com"], "agent-relay")
        self.assertEqual((self.state / "ca.crt").read_bytes(), ca)
        self.assertNotEqual((self.state / "tls.crt").read_bytes(), old_leaf)

    def test_mismatched_import_refuses_before_copy(self):
        self.initial_ca()
        local_ca.prepare(self.stack)
        self.command(["openssl", "genrsa", "-out", self.store / "ca.key", "2048"])
        shutil.rmtree(self.state)
        self.state.mkdir(mode=0o700)
        with self.assertRaisesRegex(StackError, "mismatched"):
            local_ca.prepare(self.stack)
        self.assertEqual(list(self.state.iterdir()), [])

    def test_publicly_readable_key_refuses(self):
        self.initial_ca()
        (self.state / "ca.key").chmod(0o644)
        with self.assertRaisesRegex(StackError, "private"):
            local_ca.prepare(self.stack)
        self.assertFalse(self.store.exists())

    def test_tls_never_renews_a_retained_root(self):
        self.initial_ca()
        before = (self.state / "ca.crt").read_bytes()
        original = self.stack.cmd
        def command(args, **kwargs):
            if "-checkend" in args and self.state / "ca.crt" in args:
                return SimpleNamespace(returncode=1)
            return original(args, **kwargs)
        self.stack.cmd = command
        with self.assertRaisesRegex(StackError, "refused to change"):
            tls.create(self.stack, ["relay.kind.agentrelay.com"], "agent-relay", preserve_ca=True)
        self.assertEqual((self.state / "ca.crt").read_bytes(), before)

    def test_other_saved_ca_is_not_forgotten(self):
        self.initial_ca()
        other = self.root / "other"
        other.mkdir()
        tls.create(SimpleNamespace(state=other, cmd=self.command, apply=lambda doc: None), ["relay.kind.agentrelay.com"], "agent-relay")
        shutil.copyfile(other / "ca.crt", self.state / "ca-history/other.crt")
        with self.assertRaisesRegex(StackError, "other saved CAs"):
            local_ca.prepare(self.stack)
        self.assertFalse(self.store.exists())

    def test_existing_store_is_never_overwritten(self):
        self.initial_ca()
        local_ca.prepare(self.stack)
        saved = (self.store / "ca.crt").read_bytes()
        shutil.rmtree(self.state)
        self.state.mkdir(mode=0o700)
        self.initial_ca()
        with self.assertRaisesRegex(StackError, "store differs"):
            local_ca.prepare(self.stack)
        self.assertEqual((self.store / "ca.crt").read_bytes(), saved)

    def test_untrusted_macos_ca_refuses_without_changing_trust(self):
        self.initial_ca()
        with patch.object(local_ca.sys, "platform", "darwin"), patch.object(local_ca, "certificate_present", return_value=False):
            with self.assertRaisesRegex(StackError, "System keychain"):
                local_ca.prepare(self.stack)
        self.assertFalse(any(c[0] in ("security", "sudo") for c in self.commands))

    def test_retained_down_removes_business_state_without_sudo(self):
        self.initial_ca()
        stack = LocalStack.__new__(LocalStack)
        stack.state, stack.name = self.state, "agent-relay-local"
        stack.marker = self.state / "cluster.json"
        stack.marker.write_text(json.dumps({"clusterUid": "fixture"}))
        (self.state / "credentials.json").write_text('{"fixture":"old data"}')
        (self.state / "nested").mkdir()
        (self.state / "nested/data").write_text("fixture")
        stack.docker = lambda **kwargs: None
        stack.owned = lambda: None
        stack.discard_dev_config = lambda record: None
        def command(args, **kwargs):
            if args[0] == "kind":
                self.commands.append([str(a) for a in args])
                return SimpleNamespace(stdout=stack.name + "\n")
            return self.command(args, **kwargs)
        stack.cmd = command
        stack.down_local()
        self.assertEqual({p.name for p in self.state.iterdir()}, set(local_ca.FILES))
        self.assertTrue(any(c[:3] == ["kind", "delete", "cluster"] for c in self.commands))
        self.assertFalse(any(c[0] == "sudo" for c in self.commands))


if __name__ == "__main__":
    unittest.main()
