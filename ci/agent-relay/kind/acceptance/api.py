"""Four read-only API checks; no response bodies or credentials enter reports."""
import datetime
import hashlib
import http.client
import json
import re
import socket
import ssl
import time
from urllib.parse import urlencode

from report import private_json

HOST = "relay.kind.agentrelay.com"
SITE = "https://" + HOST


class Failure(Exception):
    def __init__(self, code):
        self.code = code


def require(condition, code):
    if not condition:
        raise Failure(code)


class Api:
    def __init__(self, ca, owner_state, member_state, timeout=20):
        self.context = ssl.create_default_context(cafile=str(ca))
        self.timeout = timeout
        self.cookies = {"owner": private_json(owner_state), "member": private_json(member_state)}

    def cookie(self, identity, path):
        cookies = []
        for c in self.cookies[identity].get("cookies", []):
            # Restrict both credentials and requests to the compiled Kind origin.
            domain = c.get("domain", "")
            cookie_path = c.get("path", "/")
            domain_matches = domain == HOST or (domain.startswith(".") and
                (HOST == domain[1:] or HOST.endswith(domain)))
            path_matches = path == cookie_path or (path.startswith(cookie_path) and
                (cookie_path.endswith("/") or path[len(cookie_path):].startswith("/")))
            if not domain_matches or not path_matches or (c.get("expires", -1) > 0 and c["expires"] <= time.time()):
                continue
            name, value = c.get("name", ""), c.get("value", "")
            require(bool(re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name)) and
                    isinstance(value, str) and not re.search(r"[\x00-\x20\x7f;]", value), "invalid_cookie")
            cookies.append(name + "=" + value)
        require(bool(cookies), "authentication_cookie_missing")
        return "; ".join(cookies)

    def get(self, path, identity=None, json_body=True):
        require(path.startswith("/") and not path.startswith("//"), "invalid_api_path")
        headers = {"Accept": "application/json"}
        if identity:
            headers["Cookie"] = self.cookie(identity, path.split("?", 1)[0])
        connection = http.client.HTTPSConnection(HOST, context=self.context, timeout=self.timeout)
        try:
            connection.request("GET", path, headers=headers)
            response = connection.getresponse()
            raw = response.read(4 * 1024 * 1024 + 1)
            require(len(raw) <= 4 * 1024 * 1024, "response_too_large")
            # http.client deliberately does not follow redirects carrying a cookie.
            require(not 300 <= response.status < 400, "unexpected_redirect")
            return response.status, json.loads(raw) if json_body else None
        finally:
            connection.close()

    def hostname_refused(self):
        with socket.create_connection((HOST, 443), timeout=self.timeout) as stream:
            try:
                with self.context.wrap_socket(stream, server_hostname="wrong.invalid"):
                    pass
            except ssl.SSLCertVerificationError as error:
                # A timeout, unrelated trust error or expired CA is not hostname proof.
                return error.verify_code == 62 or "hostname mismatch" in error.verify_message.lower()
        return False


def tls(api, config):
    status, _ = api.get("/", json_body=False)
    require(status == 200, "dashboard_https_not_200")
    require(api.hostname_refused(), "wrong_hostname_not_refused")
    return {"httpsStatus": status, "wrongHostnameRefused": True}


def base(config):
    return "/cloud/api/v1/workspaces/" + config["workspaceId"] + "/sessions"


def session_reads(api, config):
    root, sid, marker = base(config), config["sessionId"], config["marker"]
    status, body = api.get(root + "?" + urlencode({"q": "id:" + sid}), "owner")
    items = body.get("items", [])
    require(status == 200 and len(items) == 1 and items[0].get("sessionId") == sid, "directory_session_missing")
    status, body = api.get(root + "/search?" + urlencode({"q": marker, "since": config["historySince"]}), "owner")
    matches = [m for m in body.get("matches", []) if m.get("sessionId") == sid and marker in m.get("content", "")]
    require(status == 200 and bool(matches), "transcript_search_marker_missing")
    status, body = api.get(root + "/" + sid + "/events?source=" + config["source"], "owner")
    require(status == 200 and marker in json.dumps(body.get("events", [])), "transcript_marker_missing")
    return {"directoryStatus": 200, "searchStatus": 200, "transcriptStatus": 200,
            "matchingEvents": len(matches), "markerSha256": hashlib.sha256(marker.encode()).hexdigest()}


def summary(api, config):
    status, body = api.get(base(config) + "/" + config["sessionId"] + "/summary?source=" + config["source"], "owner")
    value = body.get("summary") or {}
    text = value.get("summary")
    require(status == 200 and value.get("status") == "ready" and isinstance(text, str) and bool(text.strip())
            and bool(value.get("model")) and bool(value.get("builtAt")), "real_summary_not_ready")
    built = datetime.datetime.fromisoformat(value["builtAt"].replace("Z", "+00:00"))
    since = datetime.datetime.fromisoformat(config["historySince"].replace("Z", "+00:00"))
    require(built.tzinfo is not None and since <= built <= datetime.datetime.now(datetime.timezone.utc),
            "summary_outside_fixture_window")
    return {"status": status, "ready": True, "modelPresent": True,
            "summarySha256": hashlib.sha256(text.encode()).hexdigest()}


def usage(api, config):
    path = "/cloud/api/v1/organizations/" + config["organizationId"] + "/usage?days=7"
    status, body = api.get(path, "owner")
    totals = body.get("totals", {})
    require(status == 200, "owner_usage_not_200")
    require(all(type(totals.get(k)) is int and totals[k] > 0 for k in
                ["activeUsers", "sessionsUploaded", "searches"]), "usage_positive_counts_missing")
    # The non-owner's credential must actually work for this workspace first.
    positive, listed = api.get(base(config) + "?" + urlencode({"q": "id:" + config["sessionId"]}), "member")
    require(positive == 200 and any(x.get("sessionId") == config["sessionId"] for x in listed.get("items", [])),
            "member_authentication_not_proven")
    denied, error = api.get(path, "member")
    require(denied == 403 and error.get("error") == "forbidden", "member_usage_not_forbidden")
    return {"ownerStatus": status, "memberSessionStatus": positive, "memberUsageStatus": denied,
            "positiveCounts": {k: totals[k] for k in ["activeUsers", "sessionsUploaded", "searches"]}}


CHECKS = [("tls_hostname", tls), ("session_reads", session_reads), ("real_summary", summary), ("usage_roles", usage)]


def load_config(path):
    config = private_json(path)
    require(config.get("site", SITE) == SITE, "kind_site_required")
    for field in ["organizationId", "workspaceId", "sessionId"]:
        require(isinstance(config.get(field), str) and bool(re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", config[field])), "invalid_fixture_id")
    require(bool(re.fullmatch(r"[A-Z][A-Z0-9_-]{7,127}", config.get("marker", ""))), "invalid_fixture_marker")
    require(config.get("source", "codex") in ("codex", "claude"), "invalid_fixture_source")
    config["source"] = config.get("source", "codex")
    since = datetime.datetime.fromisoformat(config["historySince"].replace("Z", "+00:00"))
    current = datetime.datetime.now(datetime.timezone.utc)
    require(since.tzinfo is not None and current - datetime.timedelta(days=1) <= since <= current, "invalid_search_bound")
    for field in ["ownerState", "memberState", "caFile", "kubeconfig", "selectionFile"]:
        value = config.get(field)
        require(isinstance(value, str) and bool(value), "required_path_missing")
        # Resolve relative paths against the config, not the shell's cwd.
        from pathlib import Path
        config[field] = str(Path(path).absolute().parent / value)
    return config
