"""Owned local network support for an explicitly selected native History route.

No resource adoption, Secret access or readiness/proof writes. Existing manual
objects refuse until a separately reviewed handoff gives them the exact source
ownership and typed identity record this module checks. `selected_values` is pure.
"""
import copy
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
from urllib.parse import urlsplit

EDGE_NS = "kind-edge"
APP_NS = "agent-relay"
SERVICE = "kind-native-history-edge8443"
RECORD = "native-network.json"
CONTROL_EGRESS = "kind-control-native-readback-egress"
SELECTOR = {"app.kubernetes.io/instance": "kind-edge-kind-edge", "app.kubernetes.io/name": "traefik"}
OWNER = "kind.agentrelay.dev/native-network"
SHA = re.compile(r"[a-f0-9]{64}\Z")
LABEL = re.compile(r"[a-z]([-a-z0-9]*[a-z0-9])?\Z")


def fail(message):
    raise ValueError("native kind network: " + message)


def refuse_legacy_bootstrap(layers):
    """The legacy PG/bootstrap code must never operate on a native selection.

    Read enabled values in Helm overlay order, before any Docker/ready/PG call.
    The separate complete native recipe must replace this guard, not bypass it.
    """
    selected = {}
    for layer in layers:
        if not isinstance(layer, dict):
            fail("profile values must be objects")
        pipeline = layer.get("sessions-pipeline", {})
        if not isinstance(pipeline, dict):
            fail("pipeline values must be an object")
        for name in ("readApi", "ingestEdge", "nativeConsumer", "nativeRouting"):
            if name not in pipeline:
                continue
            slot = pipeline[name]
            if not isinstance(slot, dict):
                fail("native service selections must be objects")
            if "enabled" in slot:
                if type(slot["enabled"]) is not bool:
                    fail("native enabled settings must be booleans")
                selected[name] = slot["enabled"]
    if any(selected.values()):
        fail("native services require the complete native bootstrap recipe; legacy kind-up refused before Docker, readiness or PostgreSQL changes")


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def selection(values):
    if not isinstance(values, dict):
        fail("selected values must be an object")
    pipeline = values.get("sessions-pipeline", {})
    if not isinstance(pipeline, dict):
        fail("pipeline values must be an object")
    routing = pipeline.get("nativeRouting", {})
    if not isinstance(routing, dict) or type(routing.get("enabled", False)) is not bool:
        fail("nativeRouting.enabled must be a boolean")
    if not routing.get("enabled", False):
        return None
    reader, ingest = pipeline.get("readApi", {}), pipeline.get("ingestEdge", {})
    if not isinstance(reader, dict) or not isinstance(ingest, dict):
        fail("reader and ingest values must be objects")
    origin = routing.get("origin")
    if reader.get("enabled") is not True or ingest.get("enabled") is not True:
        fail("both native read and ingest services must be selected")
    if not isinstance(origin, str) or reader.get("origin") != origin or ingest.get("origin") != origin:
        fail("reader, ingest and routing origins must agree exactly")
    try:
        parsed = urlsplit(origin)
        host = parsed.hostname
        if (parsed.scheme != "https" or parsed.username or parsed.password or parsed.path or parsed.query
                or parsed.fragment or parsed.port != 8443 or not host or origin != "https://" + host + ":8443"
                or len(host) > 253 or "." not in host
                or any(not re.fullmatch(r"[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?", x) for x in host.split("."))):
            fail("local native routing requires its exact public HTTPS DNS origin on 8443")
        try:
            ipaddress.ip_address(host)
        except ValueError:
            pass
        else:
            fail("a literal IP is not a public History origin")
    except (TypeError, ValueError) as error:
        if str(error).startswith("native kind network:"):
            raise
        fail("invalid native origin")
    if not isinstance(routing.get("tls", {}), dict):
        fail("routing TLS selection must be an object")
    if routing.get("className") != "traefik" or not routing.get("tls", {}).get("existingSecret"):
        fail("the kind route requires Traefik and an existing TLS Secret")
    control = values.get("relay-control", {})
    if not isinstance(control, dict) or not isinstance(control.get("services", {}), dict):
        fail("Control service values must be an object")
    services = control.get("services", {})
    if (services.get("relayauthEnabled") is not False
            or not isinstance(reader.get("auth"), dict) or reader["auth"].get("mode") != "relaycontrol_only"
            or not isinstance(reader["auth"].get("relaycontrol", {}), dict)
            or reader["auth"].get("relaycontrol", {}).get("enabled") is not True
            or services.get("relayhistoryReadApiEvents") is not True or reader.get("loginAdvertisesSync") is not True):
        fail("Pattern A requires Control-only auth, explicit native events and grant-aware sync login")
    if services.get("relayhistoryReadApiUrl") not in (None, "", origin):
        fail("existing Control read API origin differs")
    if services.get("relayhistoryPublicUrl") != origin:
        fail("Control's existing public History audience must equal the selected origin")
    names = {"ingress": routing.get("fullnameOverride") or "agent-relay-native-history",
             "reader": reader.get("fullnameOverride") or "agent-relay-read-api",
             "ingest": ingest.get("fullnameOverride") or "agent-relay-ingest-edge",
             "tls": routing["tls"]["existingSecret"]}
    if any(not isinstance(names[k], str) or len(names[k]) > 63 or not LABEL.fullmatch(names[k]) for k in ("reader", "ingest")):
        fail("native Service names must be DNS-1035 labels")
    for k in ("ingress", "tls"):
        value = names[k]
        if (not isinstance(value, str) or len(value) > 253
                or any(not re.fullmatch(r"[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?", label) for label in value.split("."))):
            fail("native Ingress and TLS names must be DNS subdomains")
    if re.search(r"\.(localhost|local|internal|lan|invalid|test|example|home\.arpa|onion)$", host) or re.search(r"\.example\.(com|net|org)$", host):
        fail("History origin must be public DNS")
    return {"origin": origin, "host": host, **names}


def _owner(stack):
    stack.require_owned_cluster()
    try:
        record = json.loads(Path(stack.marker).read_text())
    except (OSError, ValueError):
        fail("missing versioned fixture ownership")
    uid = record.get("clusterUid")
    if (type(record.get("version")) is not int or record.get("version") != 1
            or record.get("name") != stack.name or record.get("profile") != stack.profile
            or not isinstance(record.get("dockerHost"), str) or not record["dockerHost"].startswith("unix://")
            or record.get("dockerHost") != stack.env.get("DOCKER_HOST")
            or not isinstance(uid, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", uid)):
        fail("fixture ownership does not match this profile")
    actual = stack.k("get", "namespace", "kube-system", "-o", "json", namespace=None).stdout
    if json.loads(actual)["metadata"]["uid"] != uid:
        fail("the native cluster identity changed")
    return {"name": stack.name, "profile": stack.profile, "clusterUid": uid}


def service_document(owner):
    return {"apiVersion": "v1", "kind": "Service", "metadata": {
        "name": SERVICE, "namespace": EDGE_NS,
        "labels": {OWNER: "owned", "kind.agentrelay.dev/profile": owner["profile"]},
        "annotations": {"kind.agentrelay.dev/cluster-uid": owner["clusterUid"],
                        "kind.agentrelay.dev/fixture-name": owner["name"]}},
        "spec": {"type": "ClusterIP", "selector": dict(SELECTOR),
                 "ports": [{"name": "history-https", "port": 8443, "protocol": "TCP", "targetPort": "websecure"}]}}


def _service(stack):
    raw = stack.k("get", "service", SERVICE, "-o", "json", "--ignore-not-found=true", namespace=EDGE_NS).stdout.strip()
    return json.loads(raw) if raw else None


def _validate_service(service, owner):
    desired = service_document(owner)
    meta, spec = service.get("metadata", {}), service.get("spec", {})
    if (service.get("kind") != "Service" or meta.get("name") != SERVICE or meta.get("namespace") != EDGE_NS
            or not meta.get("uid") or any(meta.get("labels", {}).get(k) != v for k, v in desired["metadata"]["labels"].items())
            or any(meta.get("annotations", {}).get(k) != v for k, v in desired["metadata"]["annotations"].items())
            or any(k in meta.get("annotations", {}) for k in ("meta.helm.sh/release-name", "meta.helm.sh/release-namespace"))
            or meta.get("ownerReferences")):
        fail("existing edge Service has no qualified source ownership; no adoption")
    allowed = {"type", "selector", "ports", "clusterIP", "clusterIPs", "ipFamilies", "ipFamilyPolicy", "internalTrafficPolicy", "sessionAffinity"}
    if (set(spec) - allowed or spec.get("type") != "ClusterIP" or spec.get("selector") != SELECTOR
            or spec.get("ports") != desired["spec"]["ports"] or spec.get("internalTrafficPolicy", "Cluster") != "Cluster"
            or spec.get("sessionAffinity", "None") != "None" or spec.get("ipFamilies", ["IPv4"]) != ["IPv4"]
            or spec.get("ipFamilyPolicy", "SingleStack") != "SingleStack"):
        fail("edge Service selector, ports or transport differs")
    try:
        ip = ipaddress.ip_address(spec.get("clusterIP", ""))
    except ValueError:
        fail("edge Service has no allocated ClusterIP")
    if ip.version != 4 or ip.is_unspecified or ip.is_loopback or ip.is_multicast or spec.get("clusterIPs", [str(ip)]) != [str(ip)]:
        fail("edge Service has an invalid allocated ClusterIP")
    return {"name": SERVICE, "namespace": EDGE_NS, "uid": meta["uid"], "clusterIP": str(ip), "specSha256": digest(spec)}


def record_for_service(stack, values, service):
    """Record construction after explicit ownership, not an import/adoption.

    A future reviewed import must establish exact ownership separately. This
    function refuses manual/foreign resources; it never annotates or adopts one.
    """
    cfg = selection(values)
    if cfg is None:
        fail("cannot qualify a disabled selection")
    _profile(stack, values)
    owner = _owner(stack)
    return {"version": 1, "type": "local-kind-native-network", **owner,
            "origin": cfg["origin"], "service": _validate_service(service, owner)}


def _record(stack, owner, cfg, service):
    path = Path(stack.state) / RECORD
    try:
        if path.is_symlink():
            fail("network ownership record must be a regular private file")
        record = json.loads(path.read_text())
    except (OSError, ValueError):
        fail("existing edge Service needs its exact qualified private ownership record")
    expected = {"version": 1, "type": "local-kind-native-network", **owner,
                "origin": cfg["origin"], "service": _validate_service(service, owner)}
    if not isinstance(record, dict) or type(record.get("version")) is not int or record != expected:
        fail("network ownership record disagrees with the live UID, origin, spec or ClusterIP")
    return record


def _ingresses(stack, cfg):
    items = json.loads(stack.k("get", "ingress", "-o", "json", namespace=APP_NS).stdout).get("items", [])
    expected_paths = {("/", "Prefix", cfg["reader"]), ("/v1/delivery/batches", "Exact", cfg["ingest"]),
                      ("/v1/turns/batches", "Exact", cfg["ingest"]), ("/v1/delivery/limits", "Exact", cfg["ingest"])}
    for item in items:
        spec, meta = item.get("spec", {}), item.get("metadata", {})
        rules = spec.get("rules", [])
        def matches(host):
            return not host or host == cfg["host"] or (isinstance(host, str) and host.startswith("*.")
                and cfg["host"].endswith(host[1:])
                and "." not in cfg["host"][:-len(host[1:])])
        if (meta.get("name") != cfg["ingress"] and not spec.get("defaultBackend")
                and not any(matches(r.get("host")) for r in rules)):
            continue
        ann = meta.get("annotations", {})
        if (meta.get("name") != cfg["ingress"] or meta.get("namespace") != APP_NS or not meta.get("uid")
                or ann.get("meta.helm.sh/release-name") != "agent-relay"
                or ann.get("meta.helm.sh/release-namespace") != APP_NS
                or meta.get("labels", {}).get("app.kubernetes.io/managed-by") != "Helm"):
            fail("manual or competing History Ingress requires a reviewed ownership handoff")
        paths = rules[0].get("http", {}).get("paths", []) if len(rules) == 1 else []
        actual = set()
        for path in paths:
            backend = path.get("backend", {}).get("service", {})
            if backend.get("port") != {"number": 80}:
                fail("native Ingress backend port differs")
            actual.add((path.get("path"), path.get("pathType"), backend.get("name")))
        if (spec.get("defaultBackend") or len(rules) != 1 or rules[0].get("host") != cfg["host"] or len(paths) != 4
                or actual != expected_paths or spec.get("ingressClassName") != "traefik"
                or spec.get("tls") != [{"hosts": [cfg["host"]], "secretName": cfg["tls"]}]):
            fail("native Ingress class, TLS or path contract differs")



def control_egress_spec(values):
    api = values.get("relay-control", {})
    name = (api.get("nameOverride") or "relay-control")[:63].rstrip("-")
    return {"podSelector": {"matchLabels": {"app.kubernetes.io/name": name,
            "app.kubernetes.io/instance": "agent-relay", "app.kubernetes.io/component": "api"}},
            "policyTypes": ["Egress"], "egress": [{"to": [{
                "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": EDGE_NS}},
                "podSelector": {"matchLabels": dict(SELECTOR)}}],
                "ports": [{"protocol": "TCP", "port": 8443}]}]}


def _control_egress(stack, values):
    items = json.loads(stack.k("get", "networkpolicy", "-o", "json", namespace=APP_NS).stdout).get("items", [])
    for policy in items:
        meta = policy.get("metadata", {})
        if meta.get("name") != CONTROL_EGRESS:
            continue
        annotations = meta.get("annotations", {})
        if (meta.get("namespace") != APP_NS or not meta.get("uid")
                or annotations.get("meta.helm.sh/release-name") != "agent-relay"
                or annotations.get("meta.helm.sh/release-namespace") != APP_NS
                or meta.get("labels", {}).get("app.kubernetes.io/managed-by") != "Helm"):
            fail("manual or foreign Control egress policy requires a reviewed ownership handoff")
        if policy.get("spec") != control_egress_spec(values):
            fail("Control egress policy differs from the exact API-to-Traefik 8443 contract")


def _profile(stack, values):
    local = values.get("localKind", {})
    if (not isinstance(local, dict) or local.get("profile") != stack.profile
            or local.get("enabled") is not True or local.get("allowLocalOnly") is not True):
        fail("selected local kind profile differs from fixture ownership")


def preflight(stack, values):
    """Read-only existing-fixture gate; invoke before invalidating readiness."""
    cfg = selection(values)
    if cfg is None:
        return None
    _profile(stack, values)
    clusters = stack.cmd(["kind", "get", "clusters"], timeout=30).stdout.splitlines()
    if stack.name not in clusters:
        if Path(stack.marker).exists() or (Path(stack.state) / RECORD).exists():
            fail("an existing ownership record cannot qualify a missing cluster")
        return {"pendingFreshCluster": True, "origin": cfg["origin"]}
    owner = _owner(stack)
    namespace_items = json.loads(stack.k("get", "namespace", "-o", "json", namespace=None).stdout).get("items", [])
    namespaces = {d.get("metadata", {}).get("name") for d in namespace_items}
    if EDGE_NS in namespaces:
        _gateway(stack, allow_absent=True, require_ready=False)
    if APP_NS in namespaces:
        _ingresses(stack, cfg)
        _control_egress(stack, values)
    service = _service(stack) if EDGE_NS in namespaces else None
    if service is None:
        if values["relay-control"]["services"].get("relayhistoryHostAliases") not in (None, []):
            fail("unallocated edge cannot qualify a preselected Control IP mapping")
        if (Path(stack.state) / RECORD).exists():
            fail("the recorded edge Service disappeared; refusing replacement")
        return {"pendingFreshService": True, **owner, "origin": cfg["origin"]}
    record = _record(stack, owner, cfg, service)
    selected_values(values, record)  # Reject a conflicting known alias before gateway changes.
    return record


def _gateway(stack, *, allow_absent=False, require_ready=True):
    all_items = json.loads(stack.k("get", "deployment", "-o", "json", namespace=EDGE_NS).stdout).get("items", [])
    items = [d for d in all_items if d.get("metadata", {}).get("annotations", {}).get("meta.helm.sh/release-name") == "kind-edge"
             or d.get("metadata", {}).get("labels", {}).get("app.kubernetes.io/name") == "traefik"
             or d.get("spec", {}).get("template", {}).get("metadata", {}).get("labels", {}).get("app.kubernetes.io/name") == "traefik"]
    if not items and allow_absent:
        return
    if len(items) != 1:
        fail("the exact Traefik gateway must exist before native edge allocation")
    gateway = items[0]
    ann, meta = gateway.get("metadata", {}).get("annotations", {}), gateway.get("metadata", {})
    labels = gateway.get("spec", {}).get("template", {}).get("metadata", {}).get("labels", {})
    if (meta.get("namespace") != EDGE_NS or ann.get("meta.helm.sh/release-name") != "kind-edge"
            or ann.get("meta.helm.sh/release-namespace") != EDGE_NS
            or any(labels.get(k) != v for k, v in SELECTOR.items())
            or (require_ready and gateway.get("status", {}).get("readyReplicas", 0) < 1)):
        fail("the Traefik gateway is foreign, unready or has a different selector")


def ensure(stack, values):
    """After gateway installation, create only absent support; otherwise no-op.

    A crash after Service creation but before receipt installation requires
    explicit source/ownership inspection. It is never adopted on the next run.
    """
    cfg = selection(values)
    if cfg is None:
        return None
    before = preflight(stack, values)
    if before.get("pendingFreshCluster"):
        fail("owned cluster and gateway must precede Service allocation")
    _gateway(stack)
    if not before.get("pendingFreshService"):
        return before
    owner = {k: before[k] for k in ("name", "profile", "clusterUid")}
    # CREATE, never apply/replace/adopt: a racing existing object must refuse.
    service = json.loads(stack.k("create", "-f", "-", "-o", "json", namespace=EDGE_NS,
                                data=json.dumps(service_document(owner))).stdout)
    record = {"version": 1, "type": "local-kind-native-network", **owner, "origin": cfg["origin"],
              "service": _validate_service(service, owner)}
    path = Path(stack.state) / RECORD
    temporary = path.with_name(".native-network-" + secrets.token_hex(8))
    created_temporary = False
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        created_temporary = True
        with os.fdopen(fd, "w") as stream:
            stream.write(json.dumps(record, indent=2) + "\n")
        # Atomic create-only receipt installation; never overwrite a raced record.
        os.link(temporary, path)
    except FileExistsError:
        fail("network receipt appeared concurrently; inspect the created Service")
    finally:
        if created_temporary:
            temporary.unlink(missing_ok=True)
    return record


def selected_values(values, observation):
    """Pure values selection; observations must come from this fixture's ensure."""
    result = copy.deepcopy(values)
    cfg = selection(result)
    if cfg is None:
        return result
    if (not isinstance(observation, dict) or observation.get("type") != "local-kind-native-network"
            or type(observation.get("version")) is not int or observation.get("version") != 1
            or observation.get("origin") != cfg["origin"]
            or observation.get("service", {}).get("name") != SERVICE
            or observation.get("service", {}).get("namespace") != EDGE_NS
            or not observation.get("service", {}).get("uid")):
        fail("qualified network observation required for managed Control values")
    address = observation["service"].get("clusterIP", "")
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        fail("network observation has no allocated ClusterIP")
    if ip.version != 4 or ip.is_unspecified or ip.is_loopback or ip.is_multicast:
        fail("network observation has an invalid allocated ClusterIP")
    services = result.setdefault("relay-control", {}).setdefault("services", {})
    aliases = [{"ip": str(ip), "hostnames": [cfg["host"]]}]
    if services.get("relayhistoryHostAliases") not in (None, [], aliases):
        fail("existing Control aliases differ from the qualified edge")
    if services.get("relayhistoryReadApiUrl") not in (None, "", cfg["origin"]):
        fail("existing Control read API origin differs")
    if type(services.get("relayhistoryReadApiEvents", False)) is not bool:
        fail("Control events selection must remain an explicit boolean")
    services["relayhistoryHostAliases"] = aliases
    services["relayhistoryReadApiUrl"] = cfg["origin"]
    return result
