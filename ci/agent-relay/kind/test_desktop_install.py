"""Artifact refusal checks run without mounting an image or installing an app."""
import hashlib
from pathlib import Path
import plistlib
import platform
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import desktop_install
from desktop_install import verify_download


class CommandErrorTests(unittest.TestCase):
    def test_failed_command_keeps_captured_diagnostics(self):
        with self.assertRaises(subprocess.CalledProcessError) as raised:
            desktop_install.run([sys.executable, "-c",
                "import sys; print('download context'); print('artifact expired', file=sys.stderr); sys.exit(2)"])
        message = desktop_install.error_message(raised.exception)
        self.assertIn("artifact expired", message)
        self.assertIn("download context", message)
        self.assertIn("exit status 2", message)

    def test_text_diagnostics_and_plain_errors_remain_readable(self):
        error = subprocess.CalledProcessError(1, ["codesign"], stderr="invalid signature\n")
        self.assertIn("\ninvalid signature", desktop_install.error_message(error))
        self.assertEqual(desktop_install.error_message(ValueError("wrong profile")), "wrong profile")


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.dmg = self.directory / "Desktop-q7m2k9-2026.11.1-beta.5-macOS-arm64.dmg"
        self.dmg.write_bytes(b"synthetic artifact fixture")
        self.sidecar = self.dmg.with_suffix(".dmg.sha256")
        self.checksum = hashlib.sha256(self.dmg.read_bytes()).hexdigest()
        self.sidecar.write_text(self.checksum + "  " + self.dmg.name + "\n")

    def test_tampering_after_sidecar_creation_refuses(self):
        verify_download(self.directory)
        self.dmg.write_bytes(b"replaced after download")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            verify_download(self.directory)

    def test_sidecar_for_another_filename_refuses_even_when_hash_matches(self):
        self.sidecar.write_text(self.checksum + "  another.dmg\n")
        with self.assertRaisesRegex(ValueError, "malformed"):
            verify_download(self.directory)

    def test_another_profile_or_architecture_is_not_accepted(self):
        self.dmg.rename(self.directory / "Desktop-m5lxqm2osk-macOS-arm64.dmg")
        with self.assertRaisesRegex(ValueError, "exactly one q7m2k9"):
            verify_download(self.directory)


class InstallRetryTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.mount = self.root / "mounted"
        self.app = self.mount / "Agent Relay Kind.app"
        self.app.mkdir(parents=True)
        self.destination = self.root / "Applications" / self.app.name
        self.fail_copy = False
        self.fail_validation = False
        self.race = False
        self.detaches = 0
        for p in (patch.object(Path, "home", return_value=self.root),
                  patch.object(desktop_install, "ROOT", self.root),
                  patch.object(desktop_install, "verify_download", return_value=(self.root / "test.dmg", "abc")),
                  patch.object(desktop_install, "run", side_effect=self.run_command),
                  patch.object(desktop_install, "inspect_app", side_effect=self.inspect),
                  patch.object(desktop_install, "publish_app", side_effect=self.publish)):
            p.start()
            self.addCleanup(p.stop)

    def run_command(self, args):
        if args[:2] == ["hdiutil", "attach"]:
            return plistlib.dumps({"system-entities": [{"mount-point": str(self.mount)}]})
        if args[:2] == ["hdiutil", "detach"]:
            self.detaches += 1
        if args[0] == "ditto":
            staged = Path(args[2])
            staged.mkdir()
            (staged / "copied").write_text("app content")
            if self.fail_copy:
                raise OSError("copy interrupted")

    def inspect(self, app):
        if app != self.app and self.fail_validation:
            raise ValueError("invalid copied signature")

    def publish(self, staged, destination):
        if self.race:
            destination.mkdir()
            (destination / "foreign").write_text("preserve")
        if destination.exists():
            raise FileExistsError(str(destination))
        staged.rename(destination)

    def assert_no_staging(self):
        self.assertEqual(list(self.destination.parent.glob(".agent-relay-kind-*")), [])

    def test_partial_copy_cleans_up_and_retry_installs(self):
        self.fail_copy = True
        with self.assertRaisesRegex(OSError, "interrupted"):
            desktop_install.install(self.root, launch=False)
        self.assertFalse(self.destination.exists())
        self.assert_no_staging()
        self.fail_copy = False
        desktop_install.install(self.root, launch=False)
        self.assertTrue((self.destination / "copied").exists())
        self.assert_no_staging()
        self.assertEqual(self.detaches, 2)

    def test_copied_signature_failure_can_be_retried(self):
        self.fail_validation = True
        with self.assertRaisesRegex(ValueError, "signature"):
            desktop_install.install(self.root, launch=False)
        self.assertFalse(self.destination.exists())
        self.assert_no_staging()
        self.fail_validation = False
        desktop_install.install(self.root, launch=False)
        self.assertTrue(self.destination.exists())

    def test_existing_app_is_preserved(self):
        self.destination.mkdir(parents=True)
        marker = self.destination / "foreign"
        marker.write_text("preserve")
        with self.assertRaisesRegex(ValueError, "already exists"):
            desktop_install.install(self.root, launch=False)
        self.assertEqual(marker.read_text(), "preserve")

    def test_app_appearing_during_copy_is_preserved(self):
        self.race = True
        with self.assertRaises(FileExistsError):
            desktop_install.install(self.root, launch=False)
        self.assertEqual((self.destination / "foreign").read_text(), "preserve")
        self.assert_no_staging()


@unittest.skipUnless(platform.system() == "Darwin", "Darwin exclusive rename API")
class ExclusivePublishTests(unittest.TestCase):
    def test_publish_is_atomic_and_never_replaces_an_existing_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            staged, destination = root / "staged.app", root / "app.app"
            staged.mkdir()
            destination.mkdir()
            with self.assertRaises(FileExistsError):
                desktop_install.publish_app(staged, destination)
            self.assertTrue(staged.is_dir())
            self.assertTrue(destination.is_dir())
            destination.rmdir()
            desktop_install.publish_app(staged, destination)
            self.assertFalse(staged.exists())
            self.assertTrue(destination.is_dir())


if __name__ == "__main__":
    unittest.main()
