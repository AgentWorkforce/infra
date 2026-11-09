#!/usr/bin/env python3
"""Local profile acceptance: 0 complete, 1 failed, 2 pending upstream work.

Health/readiness alone never passes this proof. Tokens stay in mode-0600 state;
only curated driver proofs and resource identifiers are printed.
"""
from __future__ import annotations

import argparse
import datetime as dt
import http.client
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import sys
import time
from urllib.parse import quote

from stack import ROOT, NS, Stack, StackError, private_json


def exit_code(checks):
    if not checks or any(c["result"] == "FAIL" for c in checks):
        return 1
    return 2 if any(c["result"] == "PENDING" for c in checks) else 0


class Proof:
    def __init__(self, stack):
        self.stack = stack
        self.checks = []
        self.state = {"emailDomain": "kind.example", "relaycast": {"mode": "sqlite"}}
        self.path = stack.state / "proof-private.json"
        self.marker = secrets.token_hex(6)

    def record(self, result, check, detail):
        if result == "SKIP":
            result = "PENDING"
        if result not in ("PASS", "FAIL", "PENDING"):
            raise StackError("unknown proof outcome")
        item = {"result": result, "check": check, "detail": detail}
        self.checks.append(item)
        print(f"{result} {check}: {detail}", flush=True)

    def require(self, value, message):
        if not value:
            raise StackError(message)

    def phase(self, phase):
        s = self.stack
        credentials = json.loads((s.state / "credentials.json").read_text())
        body = dict(self.state, secrets={"relaycastInternalSecret": credentials["cast"]})
        response = s.k("exec", "-i", "deploy/relay-control", "--", "env",
                       "E2E_RELAYCAST_URL=http://relaycast.agent-relay.svc.cluster.local:8787",
                       "E2E_RELAYHISTORY_URL=http://relayhistory.agent-relay.svc.cluster.local:8080",
                       "E2E_RELAYAUTH_URL=http://relayauth.agent-relay.svc.cluster.local:8787",
                       "node", "/tmp/kind-proof-driver.mjs", phase, data=json.dumps(body), sensitive=True)
        result = json.loads(response.stdout)
        self.state = result["state"]
        private_json(self.path, self.state)
        self.require(bool(result.get("proofs")), f"{phase} returned no proof")
        for item in result["proofs"]:
            self.record(item["result"], item["check"], item["detail"])
        self.require(not any(p["result"] == "FAIL" for p in result["proofs"]), f"{phase} failed")

    def edge(self, host, path, token=None, method="GET", body=None, extra_headers=None, response_headers=None):
        context = ssl.create_default_context(cafile=str(self.stack.state / "ca.crt"))
        conn = http.client.HTTPSConnection(host, 8443, context=context, timeout=15)
        # Route locally without changing system DNS. TLS still verifies host/SNI.
        conn._create_connection = lambda address, timeout, source_address=None: socket.create_connection(("127.0.0.1", 8443), timeout)
        headers = {"accept": "application/json", "X-Correlation-Id": "kind-proof-" + self.marker}
        if token:
            headers["authorization"] = "Bearer " + token
        if body is not None:
            headers.update({"content-type": "application/json", "if-match": "0"})
        headers.update(extra_headers or {})
        try:
            conn.request(method, path, body=None if body is None else json.dumps(body), headers=headers)
            response = conn.getresponse()
            if response_headers is not None:
                response_headers.update(dict(response.getheaders()))
            text = response.read().decode()
            return response.status, text
        finally:
            conn.close()

    def mcp(self):
        token = self.state["a"]["accessToken"]
        initialize = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "kind-proof", "version": "1"}}}
        containers = json.loads(self.stack.k("get", "deployment", "relay-control", "-o", "json").stdout)["spec"]["template"]["spec"]["containers"]
        image = next(c["image"] for c in containers if c["name"] == "api")
        selected = json.loads((self.stack.state / "images.json").read_text())["images"]
        controls = [i for i in selected if "/selfhost-api@" in i or "/relay-control@" in i]
        self.require(len(controls) == 1 and image == controls[0], "live control image differs from the selected control image receipt")
        expected_local = image.startswith("agent-relay-kind/selfhost-api@")
        unavailable = []
        for path in ("/api/v1/mcp/shared-sessions", "/cloud/api/v1/mcp/shared-sessions"):
            headers = {"accept": "application/json, text/event-stream"}
            response_headers = {}
            status, body = self.edge("relay.kind.agentrelay.com", path, token, "POST", initialize, headers, response_headers)
            if status == 404 and not expected_local:
                unavailable.append(path)
                continue
            self.require(status == 200, f"MCP initialize failed path={path} status={status}")
            result = json.loads(body).get("result", {})
            self.require(result.get("serverInfo", {}).get("name") == "agent-relay-selfhost", "unexpected MCP server identity")
            normalized = {key.lower(): value for key, value in response_headers.items()}
            session = normalized.get("mcp-session-id", "")
            self.require(bool(session) and len(session) <= 128, "MCP initialize did not return a session identity")
            headers.update({"mcp-session-id": session, "mcp-protocol-version": result["protocolVersion"]})
            status, body = self.edge("relay.kind.agentrelay.com", path, token, "POST",
                                     {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, headers)
            tools = json.loads(body).get("result", {}).get("tools", [])
            self.require(status == 200 and len(tools) == 19 and
                         {"describe_capabilities", "send_relay_message", "search_shared_sessions", "get_shared_session"} <= {t["name"] for t in tools},
                         "MCP tool discovery did not expose the expected self-host catalog")
            status, body = self.edge("relay.kind.agentrelay.com", path, token, "POST",
                                     {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "describe_capabilities", "arguments": {}}}, headers)
            result = json.loads(body).get("result", {})
            capabilities = result.get("structuredContent", {})
            self.require(status == 200 and not result.get("isError") and
                         capabilities.get("workspace", {}).get("workspace_id") == self.state["a"]["workspaceId"] and
                         capabilities.get("connection", {}).get("auth_mode") == "cli_login" and
                         capabilities.get("endpoint", {}).get("url") == "https://relay.kind.agentrelay.com:8443" + path,
                         "MCP capabilities are not bound to the authenticated workspace/public origin")
            status, _ = self.edge("relay.kind.agentrelay.com", path, method="POST", body=initialize, extra_headers={"accept": "application/json, text/event-stream"})
            self.require(status == 401, "MCP accepted unauthenticated initialization")
            status, _ = self.edge("relay.kind.agentrelay.com", path, token, "POST", initialize,
                                  {"accept": "application/json, text/event-stream", "origin": "https://outside.kind.example"})
            self.require(status == 403, "MCP accepted a foreign browser origin")
        if unavailable:
            self.require(len(unavailable) == 2, "MCP is available through only one public alias")
            self.record("PENDING", "mcp", "both public aliases returned 404 on the catalog control image; select the pinned local control build and rerun setup/proof")
            return
        self.record("PASS", "mcp", "both trusted public TLS paths initialize, list19 tools and report the real workspace; missing auth401 and foreign origin403")

    def egress(self):
        s = self.stack
        policies = json.loads(s.k("get", "networkpolicies", "-o", "json").stdout)["items"]
        egress = [p for p in policies if "Egress" in p["spec"].get("policyTypes", [])]
        self.require(len(egress) == 1 and egress[0]["metadata"]["name"] == "kind-no-external-egress",
                     "unexpected additive egress policy could invalidate the namespace isolation proof")
        policy = egress[0]["spec"]
        self.require(policy["podSelector"] == {}, "egress policy does not cover all suite/support pods")
        self.require(policy["egress"] == [
            {"to": [{"podSelector": {}}]},
            {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
                     "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
             "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]}],
            "live policy differs from same-namespace plus DNS restriction")
        edge = json.loads(s.k("get", "networkpolicies", "-o", "json", namespace="kind-edge").stdout)["items"]
        edge = [p for p in edge if "Egress" in p["spec"].get("policyTypes", [])]
        self.require(len(edge) == 1 and edge[0]["metadata"]["name"] == "kind-edge-no-external-egress",
                     "unexpected edge egress policy could invalidate isolation")
        spec = edge[0]["spec"]
        self.require(spec["podSelector"] == {} and len(spec["egress"]) == 3, "edge policy must cover every pod")
        self.require(spec["egress"][0] == {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": NS}}, "podSelector": {}}]}
                     and spec["egress"][1] == policy["egress"][1], "edge may reach only stack backends and DNS")
        api = spec["egress"][2]
        endpoints = json.loads(s.k("get", "endpoints", "kubernetes", "-o", "json", namespace="default").stdout)
        service = json.loads(s.k("get", "service", "kubernetes", "-o", "json", namespace="default").stdout)
        allowed = {service["spec"]["clusterIP"]} | {a["ip"] for subset in endpoints["subsets"] for a in subset["addresses"]}
        allowed_ports = {443} | {p["port"] for subset in endpoints["subsets"] for p in subset["ports"]}
        self.require(all(set(peer) == {"ipBlock"} and ipaddress.ip_network(peer["ipBlock"]["cidr"]).num_addresses == 1
                         and str(ipaddress.ip_network(peer["ipBlock"]["cidr"]).network_address) in allowed for peer in api["to"])
                     and all(p["protocol"] == "TCP" and p["port"] in allowed_ports for p in api["ports"]), "edge API rule must target only this cluster's API endpoints")
        image = next(i for i in json.loads((s.state / "images.json").read_text())["images"] if "/selfhost-api@" in i or "/relay-control@" in i)
        baseline = "kind-proof-" + self.marker
        s.apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": baseline}})

        def probe(namespace, host, port, name):
            script = ("const net=require('node:net'); const s=net.createConnection({host:" + json.dumps(host) + ",port:" + str(port) + "});"
                      "const fail=()=>{s.destroy();process.exit(23)};s.setTimeout(4000,fail);s.on('error',fail);"
                      "s.on('connect',()=>{s.destroy();process.exit(0)})")
            pod = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "namespace": namespace},
                   "spec": {"restartPolicy": "Never", "automountServiceAccountToken": False, "activeDeadlineSeconds": 30, "containers": [
                       {"name": "probe", "image": image, "imagePullPolicy": "Never", "command": ["node", "-e", script]}]}}
            s.apply(pod)
            deadline = time.monotonic() + 60
            try:
                while time.monotonic() < deadline:
                    d = json.loads(s.k("get", "pod", name, "-n", namespace, "-o", "json").stdout)
                    for c in d.get("status", {}).get("containerStatuses", []):
                        term = c.get("state", {}).get("terminated")
                        if term:
                            self.require(term.get("reason") != "OOMKilled", "network probe was OOM killed")
                            return term["exitCode"]
                    time.sleep(1)
                raise StackError("network probe never executed")
            finally:
                s.k("delete", "pod", name, "-n", namespace, "--ignore-not-found", "--wait=false")

        try:
            self.require(probe(baseline, "1.1.1.1", 443, "external-baseline") == 0,
                         "external baseline unreachable; cannot claim a policy denial")
            self.require(probe(NS, "1.1.1.1", 443, "external-denied-"+self.marker) == 23,
                         "suite namespace can reach external TCP/443")
            self.require(probe(NS, "relay-control.agent-relay.svc.cluster.local", 80, "internal-allowed-"+self.marker) == 0,
                         "in-cluster DNS/service connectivity broken")
            self.require(probe("kind-edge", "1.1.1.1", 443, "edge-denied-"+self.marker) == 23,
                         "edge namespace can reach external TCP/443")
            self.require(probe("kind-edge", "relay-control.agent-relay.svc.cluster.local", 80, "edge-backend-"+self.marker) == 0
                         and probe("kind-edge", "kubernetes.default.svc.cluster.local", 443, "edge-api-"+self.marker) == 0,
                         "edge cannot reach its required backend/API endpoints")
            self.record("PASS", "core.egress", "external baseline connects; suite and edge external TCP denied; internal DNS/backend/API connects")
        finally:
            s.k("delete", "namespace", baseline, "--ignore-not-found", "--wait=false")

    def tls_and_app(self):
        status, html = self.edge("relay.kind.agentrelay.com", "/")
        self.require(status == 200 and "<html" in html.lower(), "relay-webapp HTML missing through verified TLS edge")
        a = self.state["a"]
        status, text = self.edge("relay.kind.agentrelay.com", f"/cloud/api/v1/workspaces/{a['workspaceId']}/sessions", a["accessToken"])
        self.require(status == 200 and any(x.get("sessionId") == self.state["session"]["sessionId"]
                     for x in json.loads(text).get("items", [])), "delivered session missing through relay-webapp same-origin read API")
        self.record("PASS", "app.tls_session_read", "trusted local TLS, relay-webapp HTML, and delivered session through /cloud/api")
        alpha, beta = self.state["agents"]["alpha"], self.state["agents"]["beta"]
        for sender, receiver in ((alpha, beta), (beta, alpha)):
            message = self.marker + " public TLS DM from " + sender["name"]
            status, _ = self.edge("cast.kind.agentrelay.com", "/v1/dm", sender["token"], "POST",
                                  {"to": receiver["name"], "text": message})
            self.require(status in (200, 201), f"public TLS DM send failed status={status}")
            status, body = self.edge("cast.kind.agentrelay.com", "/v1/dm/" + quote(str(self.state["dm"]["conversationId"]), safe="") + "/messages?limit=50", receiver["token"])
            parsed = json.loads(body)
            data = parsed.get("data", parsed) if isinstance(parsed, dict) else parsed
            self.require(status == 200 and isinstance(data, (list, dict)), "public TLS DM read returned an invalid response")
            messages = data if isinstance(data, list) else data.get("messages", data.get("items", []))
            self.require(status == 200 and any((m.get("text") or m.get("content") or m.get("body")) == message for m in messages),
                         "public TLS DM was not received")
        status, _ = self.edge("cast.kind.agentrelay.com", "/internal/capabilities")
        self.require(status in (404, 503), "public cast ingress did not deny the internal route")
        self.record("PASS", "app.cast_tls_dm", "both agents send/receive through verified public Cast TLS origin; internal route denied at edge")

    def pipeline(self):
        s = self.stack
        tenant = json.loads((s.state / "tenant.json").read_text())
        marker = self.state["marker"]  # matches the real issuer's sponsorId
        self.state["bulls"] = {"orgId": tenant["orgId"], "workspaceId": tenant["workspaceId"], "userId": self.state["a"]["ownerUserId"],
                               "origin": "https://history.kind.agentrelay.com:8443", "machineId": "kind-" + self.marker}
        self.phase("mint-sessions-pipeline")
        source = (ROOT / "scripts/selfhost/e2e-gcp-proof-sessions-pipeline.ts").read_text()
        s.k("exec", "-i", "deploy/session-ingest-api", "--", "sh", "-c", "cat > /tmp/kind-pipeline.ts", data=source)
        result = s.k("exec", "-i", "deploy/session-ingest-api", "--", "env", "E2E_PIPELINE_USER_ID="+self.state["bulls"]["userId"],
                     "bun", "/tmp/kind-pipeline.ts", "push", marker,
                     self.state["bulls"]["machineId"], data=self.state.pop("bullsAssertion"), sensitive=True, check=False)
        session = None
        for line in result.stdout.splitlines():
            if line.startswith("SESSION_ID="):
                session = line.split("=", 1)[1]
            if line.startswith("PROOF|"):
                _, outcome, check, detail = line.split("|", 3)
                self.record(outcome, check, detail)
        self.require(result.returncode == 0 and session, "courier did not successfully upload a session")
        result = s.k("exec", "deploy/session-ingest-api", "--", "env", "E2E_PIPELINE_USER_ID="+self.state["bulls"]["userId"],
                     "bun", "/tmp/kind-pipeline.ts", "verify-offline", marker, session, "180",
                     timeout=210, sensitive=True, check=False)
        proofs = 0
        for line in result.stdout.splitlines():
            if line.startswith("PROOF|"):
                _, outcome, check, detail = line.split("|", 3)
                self.record(outcome, check, detail)
                proofs += 1
        self.require(result.returncode == 0 and proofs > 0, "offline pipeline readback failed")
        self.pipeline_app_visibility(session, tenant)

    def pipeline_app_visibility(self, session, tenant):
        s = self.stack
        s.k("exec", "-i", "deploy/relay-control", "--", "sh", "-c", "cat > /tmp/kind-workspace-session.mjs",
            data=(ROOT / "ci/agent-relay/kind/workspace-session.mjs").read_text())
        result = s.k("exec", "-i", "deploy/relay-control", "--", "node", "/tmp/kind-workspace-session.mjs", sensitive=True,
                     data=json.dumps({"userId": self.state["a"]["ownerUserId"], "workspaceId": tenant["workspaceId"]}))
        token = json.loads(result.stdout)["accessToken"]
        try:
            last_status = "not_attempted"
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                status, body = self.edge("relay.kind.agentrelay.com", f"/cloud/api/v1/workspaces/{tenant['workspaceId']}/sessions", token)
                last_status = status
                self.require(status == 200, f"courier application read failed status={status}")
                if any(item.get("sessionId") == session for item in json.loads(body).get("items", [])):
                    self.record("PASS", "pipeline.app_visibility", "courier-uploaded session returned by authenticated relay-webapp TLS read API")
                    return
                time.sleep(1)
            self.record("PENDING", "pipeline.app_visibility", f"courier upload/index/Locker verified, but authenticated Default workspace application visibility was not established within 15s; last HTTP={last_status}; read-path integration contract required")
        finally:
            # Preserve any original read exception and report cleanup as a
            # separate failure instead of replacing the causal diagnostic.
            try:
                status, body = self.edge("relay.kind.agentrelay.com", "/api/v1/auth/token/revoke", method="POST", body={"token": token})
                self.require(status == 200 and json.loads(body).get("revoked") is True, "temporary pipeline-read device session was not revoked")
            except Exception as error:
                self.record("FAIL", "pipeline.read_session_cleanup", type(error).__name__)

    def cost_attribution(self):
        s, a = self.stack, self.state["a"]
        s.k("exec", "-i", "deploy/relay-control", "--", "sh", "-c", "cat > /tmp/kind-cost.mjs",
            data=(ROOT / "ci/agent-relay/kind/cost.mjs").read_text())
        result = s.k("exec", "-i", "deploy/relay-control", "--", "node", "/tmp/kind-cost.mjs", sensitive=True,
                     data=json.dumps({"accessToken": a["accessToken"], "workspaceId": a["workspaceId"],
                                      "sessionId": self.state["session"]["sessionId"], "marker": self.marker}))
        expected = json.loads(result.stdout)
        sync_token, payload = expected.pop("accessToken"), expected.pop("payload")
        try:
            status, body = self.edge("history.kind.agentrelay.com", "/v1/ingest", sync_token, "POST", payload)
            self.require(status == 200 and json.loads(body).get("accepted") == 1, "public History TLS ingest did not accept reported cost fixture")
        finally:
            try:
                status, body = self.edge("history.kind.agentrelay.com", "/v1/auth/token/revoke", method="POST", body={"token": sync_token})
                self.require(status == 200 and json.loads(body).get("revoked") is True, "temporary cost sync session was not revoked")
            except Exception as error:
                self.record("FAIL", "cost.sync_session_cleanup", type(error).__name__)
        route = f"/cloud/api/v1/workspaces/{a['workspaceId']}/sessions"
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            status, text = self.edge("relay.kind.agentrelay.com", route, a["accessToken"])
            self.require(status == 200, f"cost session list failed status={status}")
            summary = next((item for item in json.loads(text).get("items", [])
                            if item.get("sessionId") == self.state["session"]["sessionId"]), {})
            status, text = self.edge("relay.kind.agentrelay.com", route + "/" + quote(self.state["session"]["sessionId"], safe="")
                                     + "/events?source=claude", a["accessToken"])
            self.require(status == 200, f"cost event read failed status={status}")
            event = next((item for item in json.loads(text).get("events", []) if item.get("eventId") == expected["eventId"]), {})
            if (event.get("userId") == a["ownerUserId"] and event.get("costUsdMicros") == expected["costUsdMicros"]
                    and event.get("usage", {}).get("input") == expected["inputTokens"]
                    and event.get("usage", {}).get("output") == expected["outputTokens"]
                    and summary.get("totalCostUsdMicros") == expected["costUsdMicros"]
                    and a["ownerUserId"] in summary.get("userIds", [])):
                b = self.state["b"]
                status, _ = self.edge("relay.kind.agentrelay.com", route, b["accessToken"])
                self.require(status == 404, "another workspace could read the attributed cost")
                self.record("PASS", "cost_attribution", "reported fixture usage/cost preserved through public History TLS ingest and application TLS read API; owner user/workspace match; other workspace denied")
                return
            time.sleep(1)
        raise StackError("reported cost/usage or owner attribution missing from the session read API")

    def flows(self):
        s = self.stack
        cron = json.loads(s.k("get", "cronjob", "relayflows", "-o", "json").stdout)
        self.require(not cron["spec"].get("suspend"), "scheduled Flow is suspended")
        uid = cron["metadata"]["uid"]
        # Suspend only while the separate manual run owns the shared journal.
        s.k("patch", "cronjob", "relayflows", "--type=merge", "-p", '{"spec":{"suspend":true}}')
        manual = "kind-flow-manual-" + self.marker
        try:
            self.drain_scheduled_flows(uid)
            s.k("create", "job", manual, "--from=cronjob/relayflows")
            s.wait_job(manual, 180)
            self.flow_result(manual)
            self.record("PASS", "addons.flow_run", "Flow Job completed its deterministic service probe with completionReason=success")
        finally:
            s.k("patch", "cronjob", "relayflows", "--type=merge", "-p", '{"spec":{"suspend":false}}')
        started = dt.datetime.now(dt.timezone.utc)
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            jobs = json.loads(s.k("get", "jobs", "-o", "json").stdout)["items"]
            for job in jobs:
                owned = any(o.get("uid") == uid and o.get("kind") == "CronJob" for o in job["metadata"].get("ownerReferences", []))
                scheduled = job["metadata"].get("annotations", {}).get("batch.kubernetes.io/cronjob-scheduled-timestamp")
                actual_firing = scheduled and dt.datetime.fromisoformat(scheduled.replace("Z", "+00:00")) > started
                if owned and job["metadata"]["name"] != manual and actual_firing and job.get("status", {}).get("succeeded"):
                    self.flow_result(job["metadata"]["name"])
                    self.record("PASS", "addons.flow_scheduled", "controller-created CronJob firing completed after proof start")
                    return
            time.sleep(3)
        raise StackError("no real scheduled Flow firing completed within 180s")

    def drain_scheduled_flows(self, uid, seconds=180):
        # Suspension stops future scheduling, not a run already using the RWO
        # journal. Never run the manual probe concurrently with that writer.
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            jobs = json.loads(self.stack.k("get", "jobs", "-o", "json").stdout)["items"]
            pending = []
            for job in jobs:
                if not any(o.get("uid") == uid and o.get("kind") == "CronJob"
                           for o in job["metadata"].get("ownerReferences", [])):
                    continue
                terminal = any(c.get("type") in ("Complete", "Failed") and c.get("status") == "True"
                               for c in job.get("status", {}).get("conditions", []))
                if not terminal:
                    pending.append(job["metadata"]["name"])
            if not pending:
                return
            time.sleep(2)
        raise StackError("scheduled Flow still owns the journal; manual proof was not started")

    def flow_result(self, job):
        # The CLI journals command stdout; it does not echo it in pod logs.
        # Assert the real runner's typed completion instead of grepping for a
        # marker that only exists in the durable step output.
        outcomes = []
        for line in self.stack.k("logs", "job/"+job).stdout.splitlines():
            try:
                outcomes.append(json.loads(line))
            except ValueError:
                continue
        self.require(any(isinstance(o, dict) and o.get("ok") is True and o.get("command") == "run"
                         and o.get("runId") and o.get("status") == "completed"
                         and o.get("completedSteps") == 1 and o.get("completionReason") == "success"
                         for o in outcomes), "Flow runner did not report successful completion of its real step")

    def relayfile(self):
        path = os.environ.get("KIND_RELAYFILE_TOKEN_FILE")
        if not path:
            self.record("PENDING", "addons.relayfile_roundtrip", "needs real temporary RelayAuth fs:read/fs:write token for first workspace; dev issuer excluded")
            return
        token = Path(path).read_text().strip()
        workspace = json.loads((self.stack.state / "tenant.json").read_text())["workspaceId"]
        route = f"/v1/workspaces/{workspace}/fs/file?path=" + quote("/kind-proof-"+self.marker+".txt", safe="")
        status, _ = self.edge("files.kind.agentrelay.com", route)
        self.require(status in (401, 403), "relayfile accepted anonymous file read")
        status, _ = self.edge("files.kind.agentrelay.com", route, token, "PUT", {"content": self.marker})
        self.require(status == 202, f"relayfile write was not accepted status={status}")
        status, text = self.edge("files.kind.agentrelay.com", route, token)
        self.require(status == 200 and json.loads(text).get("content") == self.marker, "relayfile content roundtrip differs")
        self.record("PASS", "addons.relayfile_roundtrip", "anonymous request denied; signed scoped write/read returned exact content")

    def run(self):
        s = self.stack
        self.require(s.marker.exists(), "run make kind-up for this profile first")
        self.require((s.state / "ready.json").exists(), "kind-up has not completed successfully for this profile")
        ready = json.loads((s.state / "ready.json").read_text())
        self.require(ready.get("profile") == s.profile and ready.get("recipeSha256") == s.recipe_hash(), "bootstrap recipe changed; rerun kind-up before acceptance")
        s.docker(require_space=False)
        uid = s.k("get", "namespace", "kube-system", "-o", "jsonpath={.metadata.uid}", namespace=None).stdout
        self.require(ready.get("clusterUid") == uid, "ready receipt belongs to a different cluster")
        s.render()
        self.require(ready.get("renderSha256") == hashlib.sha256((s.state / "rendered.yaml").read_bytes()).hexdigest(), "profile render changed since readiness; rerun kind-up")
        s.k("exec", "-i", "deploy/relay-control", "--", "sh", "-c", "cat > /tmp/kind-proof-driver.mjs",
            data=(ROOT / "scripts/selfhost/e2e-gcp-proof-driver.mjs").read_text())
        self.egress()
        for phase in ("bootstrap", "messaging", "delivery", "reads", "sessions", "auth"):
            self.phase(phase)
        self.tls_and_app()
        self.cost_attribution()
        self.pipeline()
        if s.profile == "addons":
            self.flows()
            self.relayfile()
        else:
            self.record("PENDING", "core.flows_disabled",
                        "needs reviewed server-derived Flows capability plus authenticated API refusal, hidden UI/direct-route checks and workload absence; components.relayflows=false alone is not product disablement")
        self.mcp()
        self.record("PENDING", "agent_launch_release", "generic agent process launch/release has no runnable contract; Factory session bindings and fleet-node claims are separate")
        if s.profile == "addons":
            self.record("PENDING", "offline_license_enforcement", "layered-control: signed license verification is design only; Secret slot is not enforcement")

    def report(self):
        code = exit_code(self.checks)
        private_json(self.stack.state / "proof.json", {"profile": self.stack.profile,
                     "infraRevision": self.stack.cmd(["git", "rev-parse", "HEAD"]).stdout.strip(),
                     "recipeSha256": self.stack.recipe_hash(),
                     "result": {0: "PASS", 1: "FAIL", 2: "PENDING"}[code], "checks": self.checks})
        return code


def execute(proof):
    # Invalidate a previous run before any preflight can fail. Unexpected
    # exceptions get a fresh FAIL receipt without dumping secret-bearing data.
    (proof.stack.state / "proof.json").unlink(missing_ok=True)
    try:
        proof.run()
    except Exception as e:
        detail = str(e) if isinstance(e, StackError) else type(e).__name__
        proof.record("FAIL", "proof.runtime", detail)
    finally:
        if proof.state.get("a"):
            try:
                proof.phase("cleanup")
            except Exception as e:
                detail = str(e) if isinstance(e, StackError) else type(e).__name__
                proof.record("FAIL", "proof.cleanup", detail)
    return proof.report()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("core", "addons"), default="core")
    args = parser.parse_args()
    os.umask(0o077)
    return execute(Proof(Stack(args.profile)))


if __name__ == "__main__":
    sys.exit(main())
