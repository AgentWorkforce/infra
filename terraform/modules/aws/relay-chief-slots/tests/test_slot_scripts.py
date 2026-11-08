"""Offline tests for the slot host scripts. Every system command is mocked on
PATH and every path sits under a throwaway root; nothing touches a host or AWS.
"""
import json
import os
import pathlib
import re
import sqlite3
import stat
import subprocess
import tempfile
import unittest

MODULE = pathlib.Path(__file__).resolve().parents[1]
BIND = MODULE / "files" / "bind-slot.sh"
FETCH = MODULE / "files" / "fetch-credentials.sh"
SLOT = "slot-aaaa1111"
SCOPE_KEYS = ("chiefId", "organizationId", "workspaceId", "projectId", "relayCallerId")

SYSTEMCTL = r"""#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_LOG"
if [ "$1" = show ]; then echo inactive; exit 0; fi
if [ "$1" = restart ] && [ "$2" = relay-chief-credentials.service ]; then
  [ -z "${MOCK_CREDS_FAIL:-}" ] || exit 1
  mkdir -p "$RELAY_CHIEF_ROOT/run/relay-chief"
  ( umask 077; echo 'RELAY_AGENT_TOKEN="synthetic"' >"$RELAY_CHIEF_ROOT/run/relay-chief/credentials.env" )
fi
exit 0
"""


def config(chief_id="chief-one"):
    return {
        "revision": 1,
        "chiefId": chief_id,
        "organizationId": "org-1",
        "workspaceId": "workspace-1",
        "projectId": "project-1",
        "relayCallerId": "agent-chief",
        "repositories": ["example/project"],
        "workers": [],
        "policy": {},
    }


def scope(chief_id="chief-one"):
    return {key: config(chief_id)[key] for key in SCOPE_KEYS}


def executable(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
    path.chmod(0o755)


class Host(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = pathlib.Path(temp.name) / "host root"
        self.log = pathlib.Path(temp.name) / "commands.log"
        self.log.touch()
        self.bin = pathlib.Path(temp.name) / "bin"
        executable(self.bin / "systemctl", SYSTEMCTL)
        executable(self.bin / "id", '#!/usr/bin/env bash\necho 0\n')
        executable(self.bin / "chown", '#!/usr/bin/env bash\nexit 0\n')
        executable(self.bin / "mountpoint", '#!/usr/bin/env bash\nexit "${MOCK_MOUNTPOINT:-0}"\n')
        executable(self.bin / "runuser", '#!/usr/bin/env bash\nshift 3\nexec "$@"\n')
        executable(self.root / "usr/bin/node", '#!/usr/bin/env bash\nexit "${MOCK_NODE:-0}"\n')
        (self.root / "opt/relay-chief/dist").mkdir(parents=True)
        (self.root / "opt/relay-chief/dist/cli.js").touch()
        (self.root / "etc/relay-chief").mkdir(parents=True)
        (self.root / "var/lib/relay-chief").mkdir(parents=True)
        (self.root / "run").mkdir(parents=True)
        (self.root / "etc/relay-chief/slot.env").write_text(
            f"RELAY_CHIEF_SLOT_ID={SLOT}\n"
            f"RELAY_CHIEF_SECRET_ID=relay-chief/slots/{SLOT}\n"
            "RELAY_CHIEF_REGION=us-west-2\n"
        )
        self.config_file = pathlib.Path(temp.name) / "input.json"
        self.config_file.write_text(json.dumps(config()))
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "RELAY_CHIEF_ROOT": str(self.root),
            "MOCK_LOG": str(self.log),
        }

    @property
    def target(self):
        return self.root / "etc/relay-chief/config.json"

    @property
    def marker(self):
        return self.root / "var/lib/relay-chief/.slot-binding.json"

    @property
    def ledger(self):
        return self.root / "var/lib/relay-chief/chief.db"

    def commands(self):
        return self.log.read_text().splitlines()

    def bind(self, *arguments, slot=SLOT, **environment):
        return subprocess.run(
            ["bash", str(BIND), "--slot-id", slot, "--config", str(self.config_file), *arguments],
            capture_output=True, text=True, env={**self.env, **environment}, check=False,
        )

    def write_ledger(self, value):
        connection = sqlite3.connect(self.ledger)
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        if value is not None:
            connection.execute("INSERT INTO metadata VALUES ('scope', ?)", (value,))
        connection.commit()
        connection.close()

    def assert_refused(self, result, code):
        self.assertEqual(result.returncode, code, result.stderr)
        self.assertIn("refused", result.stderr)
        self.assertFalse(self.target.exists(), "a refusal must not write the configuration")
        self.assertNotIn("enable --now relay-chief.timer", self.commands())


class Refusals(Host):
    def test_malformed_slot_ids(self):
        for slot in ("", "slot-", "slot-short", "SLOT-AAAA1111", "slot-aaaa1111; reboot",
                     "slot-aaaa1111\n", "../slot-aaaa1111", "customer-name-here"):
            with self.subTest(slot=slot):
                result = self.bind(slot=slot)
                self.assert_refused(result, 2)
                self.assertEqual(self.commands(), [], "must refuse before touching systemd")

    def test_timer_without_dispatch_opt_in(self):
        self.assert_refused(self.bind("--enable-timer"), 4)
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.commands(), [])

    def test_dispatch_opt_in_without_timer(self):
        self.assert_refused(self.bind("--dispatch-opt-in"), 4)
        self.assertFalse(self.marker.exists())

    def test_wrong_host(self):
        self.assert_refused(self.bind(slot="slot-bbbb2222"), 3)

    def test_unprovisioned_host(self):
        (self.root / "etc/relay-chief/slot.env").unlink()
        self.assert_refused(self.bind(), 3)

    def test_ledger_bound_to_a_different_chief(self):
        self.write_ledger(json.dumps(scope("chief-other"), sort_keys=True, separators=(",", ":")))
        self.assert_refused(self.bind(), 3)
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.commands(), [], "a refusal must not stop a running chief")

    def test_ledger_with_a_different_scope_field(self):
        other = scope()
        other["workspaceId"] = "workspace-2"
        self.write_ledger(json.dumps(other))
        self.assert_refused(self.bind(), 3)

    def test_marker_for_a_different_chief_before_any_ledger(self):
        self.marker.write_text(json.dumps({"version": 1, "slotId": SLOT, "scope": scope("chief-other")}))
        self.assert_refused(self.bind(), 3)
        self.assertEqual(self.commands(), [])

    def test_marker_for_a_different_slot(self):
        self.marker.write_text(json.dumps({"version": 1, "slotId": "slot-bbbb2222", "scope": scope()}))
        self.assert_refused(self.bind(), 3)

    def test_unreadable_ledger_fails_closed(self):
        self.ledger.write_bytes(b"this is not a sqlite database, it is a slot ledger gone wrong")
        self.assert_refused(self.bind(), 3)

    def test_ledger_symlink_fails_closed(self):
        other = self.root / "elsewhere.db"
        other.touch()
        self.ledger.symlink_to(other)
        self.assert_refused(self.bind(), 3)

    def test_unmounted_data_volume(self):
        self.assert_refused(self.bind(MOCK_MOUNTPOINT="1"), 1)
        self.assertFalse(self.marker.exists())

    def test_missing_runtime_build(self):
        (self.root / "opt/relay-chief/dist/cli.js").unlink()
        self.assert_refused(self.bind(), 1)

    def test_runtime_schema_rejection(self):
        self.assert_refused(self.bind(MOCK_NODE="1"), 2)
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.commands(), [])

    def test_invalid_configuration_json(self):
        self.config_file.write_text("{not json")
        self.assert_refused(self.bind(), 2)

    def test_padded_identifier(self):
        self.config_file.write_text(json.dumps(config(" chief-one ")))
        self.assert_refused(self.bind(), 2)

    def test_second_chief_is_refused_after_a_first_bind(self):
        self.assertEqual(self.bind().returncode, 0)
        self.target.unlink()
        self.config_file.write_text(json.dumps(config("chief-other")))
        self.assert_refused(self.bind(), 3)


class Binding(Host):
    def test_binds_with_the_timer_left_disabled(self):
        result = self.bind()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.target.read_text())["chiefId"], "chief-one")
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o640)
        self.assertEqual(json.loads(self.marker.read_text()), {"version": 1, "slotId": SLOT, "scope": scope()})
        self.assertEqual(stat.S_IMODE(self.marker.stat().st_mode), 0o600)
        self.assertIn("restart relay-chief-credentials.service", self.commands())
        self.assertIn("disable --now relay-chief.timer", self.commands())
        self.assertNotIn("enable --now relay-chief.timer", self.commands())
        self.assertEqual(sorted(p.name for p in (self.root / "etc/relay-chief").iterdir()), ["config.json", "slot.env"])

    def test_opt_in_enables_the_timer(self):
        result = self.bind("--enable-timer", "--dispatch-opt-in")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands()[-1], "enable --now relay-chief.timer")

    def test_configuration_from_stdin(self):
        result = subprocess.run(
            ["bash", str(BIND), "--slot-id", SLOT, "--config", "-"],
            input=json.dumps(config()), capture_output=True, text=True, env=self.env, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.target.exists())

    def test_rebinding_the_same_chief_after_host_replacement(self):
        self.write_ledger(json.dumps(scope(), sort_keys=True, separators=(",", ":")))
        self.marker.write_text(json.dumps({"version": 1, "slotId": SLOT, "scope": scope()}))
        result = self.bind()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.target.exists())

    def test_ledger_created_but_never_configured_is_not_bound(self):
        self.ledger.touch()
        self.assertEqual(self.bind().returncode, 0)

    def test_ledger_without_a_scope_row_is_not_bound(self):
        self.write_ledger(None)
        self.assertEqual(self.bind().returncode, 0)

    def test_credential_failure_keeps_the_timer_off(self):
        result = self.bind("--enable-timer", "--dispatch-opt-in", MOCK_CREDS_FAIL="1")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("enable --now relay-chief.timer", self.commands())

    def test_credential_file_with_wrong_mode_keeps_the_timer_off(self):
        executable(self.bin / "stat", '#!/usr/bin/env bash\necho 644\n')
        result = self.bind("--enable-timer", "--dispatch-opt-in")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("enable --now relay-chief.timer", self.commands())


class FetchCredentials(unittest.TestCase):
    REQUIRED = {
        "RELAY_AGENT_TOKEN": "synthetic-token",
        "TYPESAFE_API_KEY": "synthetic-key",
        "CHIEF_CONTROL_PLANE_URL": "https://control.example",
        "CHIEF_CONTROL_PLANE_TOKEN": 'syn"the$tic\\',
    }

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = pathlib.Path(temp.name) / "root"
        self.bin = pathlib.Path(temp.name) / "bin"
        self.secret = pathlib.Path(temp.name) / "secret.json"
        self.arguments = pathlib.Path(temp.name) / "arguments"
        (self.root / "etc/relay-chief").mkdir(parents=True)
        (self.root / "etc/relay-chief/slot.env").write_text(
            f"RELAY_CHIEF_SECRET_ID=relay-chief/slots/{SLOT}\nRELAY_CHIEF_REGION=us-west-2\n"
        )
        executable(self.bin / "aws", '#!/usr/bin/env bash\necho "$*" >"$MOCK_ARGUMENTS"\n[ -z "${MOCK_AWS_FAIL:-}" ] || exit 254\ncat "$MOCK_SECRET"\n')
        self.target = self.root / "run/relay-chief/credentials.env"

    def fetch(self, secret, **environment):
        self.secret.write_text(json.dumps(json.dumps(secret)))
        return subprocess.run(
            ["bash", str(FETCH)], capture_output=True, text=True, check=False,
            env={**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "RELAY_CHIEF_ROOT": str(self.root),
                 "MOCK_SECRET": str(self.secret), "MOCK_ARGUMENTS": str(self.arguments), **environment},
        )

    def assert_closed(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.target.exists(), "a failure must leave no credential file")
        for value in self.REQUIRED.values():
            self.assertNotIn(value, result.stderr + result.stdout)

    def test_writes_private_environment_file(self):
        result = self.fetch(self.REQUIRED)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.target.parent.stat().st_mode), 0o700)
        text = self.target.read_text()
        self.assertIn('RELAY_AGENT_TOKEN="synthetic-token"\n', text)
        self.assertIn('CHIEF_CONTROL_PLANE_TOKEN="syn\\"the\\$tic\\\\"\n', text)
        self.assertEqual(result.stdout + result.stderr, "")
        arguments = self.arguments.read_text()
        self.assertIn(f"--secret-id relay-chief/slots/{SLOT}", arguments)
        self.assertNotIn("synthetic-token", arguments)

    def test_optional_relay_base_url(self):
        result = self.fetch({**self.REQUIRED, "RELAY_BASE_URL": "https://relay.example"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('RELAY_BASE_URL="https://relay.example"', self.target.read_text())

    def test_failures_leave_no_file(self):
        cases = {
            "missing": {k: v for k, v in self.REQUIRED.items() if k != "TYPESAFE_API_KEY"},
            "unknown": {**self.REQUIRED, "NODE_OPTIONS": "--require=/tmp/x"},
            "empty": {**self.REQUIRED, "TYPESAFE_API_KEY": "  "},
            "non-string": {**self.REQUIRED, "TYPESAFE_API_KEY": 7},
            "newline": {**self.REQUIRED, "TYPESAFE_API_KEY": "a\nb"},
            "not-an-object": ["RELAY_AGENT_TOKEN"],
        }
        for name, secret in cases.items():
            with self.subTest(case=name):
                self.assert_closed(self.fetch(secret))

    def test_aws_failure_removes_the_previous_file(self):
        self.assertEqual(self.fetch(self.REQUIRED).returncode, 0)
        self.assert_closed(self.fetch(self.REQUIRED, MOCK_AWS_FAIL="1"))

    def test_unparseable_secret(self):
        self.secret.write_text("not json")
        result = subprocess.run(
            ["bash", str(FETCH)], capture_output=True, text=True, check=False,
            env={**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "RELAY_CHIEF_ROOT": str(self.root),
                 "MOCK_SECRET": str(self.secret), "MOCK_ARGUMENTS": str(self.arguments)},
        )
        self.assert_closed(result)


class Contracts(unittest.TestCase):
    def test_slot_id_pattern_matches_terraform(self):
        bind = re.search(r"SLOT_ID_PATTERN='([^']+)'", BIND.read_text()).group(1)
        self.assertIn(f'regex("{bind}"', (MODULE / "variables.tf").read_text())

    def test_reference_units_are_unmodified(self):
        service = (MODULE / "files/relay-chief.service").read_text()
        self.assertIn("EnvironmentFile=/run/relay-chief/credentials.env", service)
        self.assertIn("run-once /etc/relay-chief/config.json /var/lib/relay-chief/chief.db --dispatch", service)
        self.assertNotIn("relay-chief-credentials", service)

    def test_drop_in_guards_the_ledger_and_credentials(self):
        drop_in = (MODULE / "files/10-slot.conf").read_text()
        self.assertIn("Requires=relay-chief-credentials.service", drop_in)
        self.assertIn("After=relay-chief-credentials.service", drop_in)
        self.assertIn("RequiresMountsFor=/var/lib/relay-chief", drop_in)

    def test_bootstrap_template(self):
        template = (MODULE / "templates/bootstrap.sh.tftpl").read_text()
        self.assertIn("RELAY_CHIEF_SLOT_ID=${slot_id}", template)
        self.assertIn("RELAY_CHIEF_SECRET_ID=${secret_name}", template)
        self.assertIn("systemctl disable relay-chief.timer", template)
        self.assertNotRegex(template, r"systemctl\s+(enable|start)\b")
        self.assertRegex(template, r'if \[ -z "\$\(wipefs [^\n]*\n\s*mkfs\.ext4', "format only a blank device")
        self.assertEqual(template.count("mkfs.ext4 -"), 1)

    def test_credentials_unit_is_ordered_before_the_service(self):
        unit = (MODULE / "files/relay-chief-credentials.service").read_text()
        self.assertIn("Before=relay-chief.service", unit)
        self.assertIn("Type=oneshot", unit)
        self.assertIn("ExecStart=/usr/local/sbin/relay-chief-fetch-credentials", unit)


if __name__ == "__main__":
    unittest.main()
