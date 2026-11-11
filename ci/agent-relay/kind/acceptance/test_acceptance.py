"""End-to-end local TLS, auth and SSHSIG regressions; no remote services."""
import datetime
import http.server
import json
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

from api import HOST, Failure, load_config
from context import ROLES, collect
from report import canonical, verify
from run import PENDING, execute

SID = "11111111-1111-4111-8111-111111111111"
MARKER = "KIND_ACCEPTANCE_FIXTURE_MARKER"
SECRET = "DO_NOT_COPY_RESPONSE_OR_COOKIE_SECRET"


class Handler(http.server.BaseHTTPRequestHandler):
    mode = "ok"

    def log_message(self, *args):
        pass

    def do_GET(self):
        status, body = 200, {}
        cookie = self.headers.get("Cookie", "")
        if self.path == "/":
            body = {"dashboard": True}
        elif "/usage?" in self.path:
            if cookie.startswith("owner="):
                body = {"totals": {"activeUsers": 2, "sessionsUploaded": 1, "searches": 3}, "secret": SECRET}
            else:
                status, body = 403, {"error": "forbidden", "secret": SECRET}
        elif cookie.startswith("member=") and self.mode == "member_expired":
            status, body = 401, {"error": SECRET}
        elif "/summary?" in self.path:
            body = {"summary": {"status": "ready", "summary": "Generated fixture summary " + SECRET,
                    "model": "fixture-model", "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}}
            if self.mode == "no_summary":
                body = {"summary": {"status": "pending", "error": SECRET}}
        elif "/search?" in self.path:
            body = {"matches": [{"sessionId": SID, "content": MARKER + SECRET}]}
        elif "/events?" in self.path:
            body = {"events": [{"content": MARKER + SECRET}]}
        elif self.mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "https://unrelated.invalid/?token=" + SECRET)
            self.end_headers()
            return
        else:
            body = {"items": [{"sessionId": SID}]}
        encoded = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


@unittest.skipUnless(shutil.which("openssl") and shutil.which("ssh-keygen"), "OpenSSL and OpenSSH required")
class AcceptanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.root = Path(cls.directory.name)
        cls.ca, cls.tls_key = cls.root / "ca.pem", cls.root / "tls.key"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-keyout", str(cls.tls_key), "-out", str(cls.ca), "-subj", "/CN=" + HOST,
                        "-addext", "subjectAltName=DNS:" + HOST], check=True, capture_output=True)
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cls.ca, cls.tls_key)
        cls.server.socket = context.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.directory.cleanup()

    def setUp(self):
        self.case = tempfile.TemporaryDirectory(dir=self.root)
        self.addCleanup(self.case.cleanup)
        self.path = Path(self.case.name)
        Handler.mode = "ok"
        self.config = {"organizationId": SID, "workspaceId": SID, "sessionId": SID, "marker": MARKER,
                       "historySince": (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=1)).isoformat(),
                       "caFile": str(self.ca), "kubeconfig": "kubeconfig", "selectionFile": "selection.json",
                       "ownerState": "owner.json", "memberState": "member.json"}
        self.write("config.json", self.config)
        for identity in ["owner", "member"]:
            self.write(identity + ".json", {"cookies": [{"name": identity, "value": SECRET,
                        "domain": HOST, "path": "/", "expires": -1, "secure": True}]})
        original_connect = socket.create_connection

        def connect(address, *args, **kwargs):
            self.assertEqual(address, (HOST, 443))
            return original_connect(("127.0.0.1", self.server.server_port), *args, **kwargs)

        self.patch = patch("socket.create_connection", side_effect=connect)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def write(self, name, data):
        path = self.path / name
        path.write_text(json.dumps(data))
        path.chmod(0o600)
        return path

    def run_suite(self, suite="api"):
        snapshot = {"sourceRevision": "a" * 40, "clusterUid": SID, "pins": {"control": "ghcr.io/agentworkforce/relay-control@sha256:" + "a" * 64}}
        code, envelope = execute(self.path / "config.json", self.path / "acceptance.json", self.path / "signing_key",
                                 suite=suite, snapshotter=lambda config, root: snapshot)
        serialized = (self.path / "acceptance.json").read_text()
        self.assertNotIn(SECRET, serialized)
        self.assertNotIn(MARKER, serialized)
        self.assertEqual((self.path / "acceptance.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.path / "signing_key").stat().st_mode & 0o777, 0o600)
        return code, envelope["payload"]

    def test_four_checks_use_real_tls_and_sign_but_do_not_claim_full_qualification(self):
        code, payload = self.run_suite()
        self.assertEqual(code, 0)
        self.assertEqual(len(payload["checks"]), 5)  # pin preflight plus four API checks
        self.assertTrue(all(c["status"] == "pass" for c in payload["checks"]))
        self.assertFalse(payload["qualificationComplete"])
        checked = verify(self.path / "acceptance.json", self.path / "signing_key.pub")
        self.assertEqual(canonical(checked), canonical(payload))

    def test_default_full_suite_cannot_green_with_unimplemented_checks(self):
        code, payload = self.run_suite("full")
        self.assertEqual(code, 1)
        self.assertEqual([c["id"] for c in payload["checks"] if c.get("code") == "not_implemented"], PENDING)
        self.assertEqual(verify(self.path / "acceptance.json", self.path / "signing_key.pub")["status"], "fail")

    def test_missing_summary_fails_signed_report_and_still_checks_usage(self):
        Handler.mode = "no_summary"
        code, payload = self.run_suite()
        self.assertEqual(code, 1)
        by_id = {c["id"]: c for c in payload["checks"]}
        self.assertEqual(by_id["real_summary"]["code"], "real_summary_not_ready")
        self.assertEqual(by_id["usage_roles"]["status"], "pass")
        verify(self.path / "acceptance.json", self.path / "signing_key.pub")

    def test_expired_member_cookie_is_not_a_successful_authorization_refusal(self):
        Handler.mode = "member_expired"
        code, payload = self.run_suite()
        self.assertEqual(code, 1)
        result = next(c for c in payload["checks"] if c["id"] == "usage_roles")
        self.assertEqual(result["code"], "member_authentication_not_proven")

    def test_redirect_is_not_followed_and_response_location_is_not_reported(self):
        Handler.mode = "redirect"
        code, payload = self.run_suite()
        self.assertEqual(code, 1)
        self.assertEqual(next(c for c in payload["checks"] if c["id"] == "session_reads")["code"], "unexpected_redirect")

    def test_signature_rejects_tampered_payload_and_replaced_public_key(self):
        self.run_suite()
        receipt = self.path / "acceptance.json"
        original = json.loads(receipt.read_text())
        altered = json.loads(receipt.read_text())
        altered["payload"]["status"] = "invented"
        receipt.write_text(json.dumps(altered))
        with self.assertRaises(ValueError):
            verify(receipt, self.path / "signing_key.pub")
        receipt.write_text(json.dumps(original))
        # A self-consistent receipt signed by a different key is not trusted either.
        execute(self.path / "config.json", self.path / "other.json", self.path / "other_key",
                suite="api", snapshotter=lambda *args: {})
        with self.assertRaises(ValueError):
            verify(self.path / "other.json", self.path / "signing_key.pub")

    def test_private_file_permissions_and_symlinks_fail_preflight_without_secret_output(self):
        member = self.path / "member.json"
        member.chmod(0o644)
        code, payload = self.run_suite()
        self.assertEqual(code, 1)
        self.assertEqual(payload["checks"][0]["status"], "fail")
        member.chmod(0o600)
        link = self.path / "linked.json"
        link.symlink_to(member)
        self.config["memberState"] = "linked.json"
        self.write("config.json", self.config)
        self.assertEqual(self.run_suite()[0], 1)

    def test_foreign_site_and_unbounded_search_are_refused(self):
        self.config["site"] = "https://customer.invalid"
        self.write("config.json", self.config)
        with self.assertRaises(Failure):
            load_config(self.path / "config.json")
        self.config.pop("site")
        self.config["historySince"] = "1970-01-01T00:00:00Z"
        self.write("config.json", self.config)
        with self.assertRaises(Failure):
            load_config(self.path / "config.json")

    def test_pin_context_checks_dashboard_init_image_and_observed_generation(self):
        self.write("tenant.json", {"organizationId": SID, "workspaceId": SID})
        selected = {key: "ghcr.io/agentworkforce/" + key + "@sha256:" + "a" * 64 for _, _, key in ROLES}
        deployments = {}
        for name, container, key in ROLES:
            entry = deployments.setdefault(name, {"metadata": {"name": name, "generation": 2},
                "spec": {"replicas": 1, "template": {"spec": {"containers": [], "initContainers": []}}},
                "status": {"observedGeneration": 2, "availableReplicas": 1, "readyReplicas": 1,
                           "replicas": 1, "updatedReplicas": 1}})
            slot = "initContainers" if container == "copy-dashboard" else "containers"
            entry["spec"]["template"]["spec"][slot].append({"name": container, "image": selected[key]})
        config = dict(self.config, selectionFile=str(self.write("selection.json", selected)))

        def command(args):
            if "jsonpath={.metadata.uid}" in args:
                return SID
            if "deployments" in args:
                return json.dumps({"items": list(deployments.values())})
            return "a" * 40 if "rev-parse" in args else ""

        with patch("context.output", side_effect=command):
            self.assertEqual(len(collect(config, self.path)["deployments"]), 9)
            deployments["relay-webapp"]["spec"]["template"]["spec"]["initContainers"][0]["image"] = "stale"
            with self.assertRaises(Failure):
                collect(config, self.path)
            deployments["relay-webapp"]["spec"]["template"]["spec"]["initContainers"][0]["image"] = selected["webapp"]
            deployments["relay-control"]["status"]["observedGeneration"] = 1
            with self.assertRaises(Failure):
                collect(config, self.path)
            deployments["relay-control"]["status"]["observedGeneration"] = 2
            deployments["relay-control"]["status"]["replicas"] = 2
            with self.assertRaises(Failure):
                collect(config, self.path)
            deployments["relay-control"]["status"]["replicas"] = 1
            self.write("tenant.json", {"organizationId": SID, "workspaceId": "different-fixture"})
            with self.assertRaises(Failure):
                collect(config, self.path)


if __name__ == "__main__":
    unittest.main()
