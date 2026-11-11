"""Artifact refusal checks run without mounting an image or installing an app."""
import hashlib
from pathlib import Path
import tempfile
import unittest

from desktop_install import verify_download


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


if __name__ == "__main__":
    unittest.main()
