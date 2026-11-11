"""Tool upgrades and partially removed caches must recover without host edits."""
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import local_tools


class LocalToolsTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.tools = self.root / ".kind/tools"
        self.tools.mkdir(parents=True)
        self.requirement = self.root / "ci/agent-relay/kind/requirements.txt"
        self.requirement.parent.mkdir(parents=True)
        self.requirement.write_text("PyYAML==6.0.3\n")
        self.data = {name: (name + "-new").encode() for name in ("kind", "helm")}
        self.pins = {name: ("https://example.invalid/" + name,
                           hashlib.sha256(data).hexdigest(), None)
                     for name, data in self.data.items()}
        patches = [patch.object(local_tools, "ROOT", self.root),
                   patch.object(local_tools, "TOOLS", self.tools),
                   patch.object(local_tools, "RELEASES", {"darwin-arm64": self.pins}),
                   patch.object(local_tools.platform, "system", return_value="Darwin"),
                   patch.object(local_tools.platform, "machine", return_value="arm64"),
                   patch.dict(local_tools.os.environ),
                   patch.object(local_tools.sys, "argv", ["local_tools.py", "--prepare"])]
        for replacement in patches:
            replacement.start()
            self.addCleanup(replacement.stop)

    def test_new_source_pins_replace_a_previously_valid_cache(self):
        for name in self.pins:
            old = (name + "-old").encode()
            (self.tools / name).write_bytes(old)
            (self.tools / (name + ".sha256")).write_text(hashlib.sha256(old).hexdigest())
        with patch.object(local_tools.urllib.request, "urlopen",
                          side_effect=lambda url, **kwargs: io.BytesIO(self.data[url.rsplit("/", 1)[1]])) as download:
            local_tools.ensure_tools()
        self.assertEqual(download.call_count, 2)
        for name, data in self.data.items():
            self.assertEqual((self.tools / name).read_bytes(), data)

    def test_an_unchanged_verified_release_reuses_its_cache(self):
        url, _, _ = self.pins["helm"]
        self.pins["helm"] = (url, hashlib.sha256(b"Helm release archive").hexdigest(), "darwin-arm64/helm")
        for name, (url, checksum, _) in self.pins.items():
            (self.tools / name).write_bytes(self.data[name])
            (self.tools / (name + ".sha256")).write_text(json.dumps({
                "url": url, "release_sha256": checksum,
                "binary_sha256": hashlib.sha256(self.data[name]).hexdigest()}))
        with patch.object(local_tools.urllib.request, "urlopen") as download:
            local_tools.ensure_tools()
        download.assert_not_called()

    def prepare_current_requirements_stamp(self):
        digest = hashlib.sha256(self.requirement.read_bytes()).hexdigest()
        (self.tools / "python-requirements.sha256").write_text(digest)

    def test_a_recreated_venv_installs_packages_despite_an_old_stamp(self):
        self.prepare_current_requirements_stamp()
        with patch.object(local_tools, "ensure_tools"), patch.object(local_tools.subprocess, "run") as run:
            local_tools.main()
        commands = [call.args[0] for call in run.call_args_list]
        self.assertTrue(any("venv" in command for command in commands))
        self.assertTrue(any("pip" in command and "install" in command for command in commands))

    def test_an_existing_current_venv_keeps_warm_setup_fast(self):
        self.prepare_current_requirements_stamp()
        python = self.tools / "venv/bin/python3"
        python.parent.mkdir(parents=True)
        python.write_text("existing Python fixture")
        with patch.object(local_tools, "ensure_tools"), patch.object(local_tools.subprocess, "run") as run:
            local_tools.main()
        commands = [call.args[0] for call in run.call_args_list]
        self.assertFalse(any("venv" in command or "pip" in command for command in commands))
        self.assertEqual(len(commands), 2)


if __name__ == "__main__":
    unittest.main()
