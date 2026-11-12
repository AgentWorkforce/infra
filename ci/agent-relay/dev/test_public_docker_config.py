import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import dev


class PublicDockerConfig(unittest.TestCase):
    def test_credential_helpers_and_auth_material_refuse(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            for value in ({"auths": {}}, {"auths": {"ghcr.io": {"auth": "synthetic"}}},
                          {"auths": {"ghcr.io": {}}, "credsStore": "desktop"}):
                path.write_text(json.dumps(value))
                with self.assertRaisesRegex(dev.Refused, "anonymous_docker_config_required"):
                    dev.validate_public_docker_config(tmp)
            path.write_text(json.dumps({"auths": {"ghcr.io": {}, "https://index.docker.io/v1/": {}}}))
            dev.validate_public_docker_config(tmp)

    def test_public_pulls_bind_local_endpoint_without_mutating_parent_environment(self):
        cmd = dev.Commands()
        cmd.docker_context = "desktop-linux"
        cmd.public_docker_config = "/local/anonymous-config"
        cmd.docker_host = "unix:///local/docker.sock"
        original = dict(os.environ)
        with patch.object(dev.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=b"", stderr=b"")) as process:
            cmd.run(["docker", "info"])
        environment = process.call_args.kwargs["env"]
        self.assertNotIn("DOCKER_CONTEXT", environment)
        self.assertEqual(environment["DOCKER_HOST"], "unix:///local/docker.sock")
        self.assertEqual(environment["DOCKER_CONFIG"], "/local/anonymous-config")
        self.assertEqual(dict(os.environ), original)

    def test_plugin_discovery_allows_only_the_bundled_desktop_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            auths = {"ghcr.io": {}, "https://index.docker.io/v1/": {}}
            for plugins in ([], ["/tmp/plugins"], "bundled", [
                    "/Applications/Docker.app/Contents/Resources/cli-plugins", "/tmp/plugins"]):
                path.write_text(json.dumps({"auths": auths, "cliPluginsExtraDirs": plugins}))
                with self.assertRaisesRegex(dev.Refused, "anonymous_docker_config_required"):
                    dev.validate_public_docker_config(tmp)


if __name__ == "__main__":
    unittest.main()
