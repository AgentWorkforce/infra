"""Pinned local ingress with backend/API/DNS-only egress."""
import ipaddress
import http.client
import json
import socket
import ssl
import time


POLICY = "kind-edge-no-external-egress"
EDGE_NAMESPACE = "kind-edge"


def egress_policy_spec(stack, namespace):
    endpoints = json.loads(stack.k("get", "endpoints", "kubernetes", "-o", "json", namespace="default").stdout)
    service = json.loads(stack.k("get", "service", "kubernetes", "-o", "json", namespace="default").stdout)
    addresses = {service["spec"]["clusterIP"]}
    ports = {443}
    for subset in endpoints["subsets"]:
        addresses.update(a["ip"] for a in subset["addresses"])
        ports.update(p["port"] for p in subset["ports"])
    targets = [{"ipBlock": {"cidr": f"{ip}/{ipaddress.ip_address(ip).max_prefixlen}"}} for ip in sorted(addresses)]
    return {"podSelector": {}, "policyTypes": ["Egress"], "egress": [
        {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": namespace}}, "podSelector": {}}]},
        {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
                 "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
         "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
        {"to": targets, "ports": [{"protocol": "TCP", "port": p} for p in sorted(ports)]}]}


def egress_policy_document(owner, spec):
    from native_network import OWNER
    return {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": {
        "name": POLICY, "namespace": EDGE_NAMESPACE,
        "labels": {OWNER: "owned", "kind.agentrelay.dev/profile": owner["profile"]},
        "annotations": {"kind.agentrelay.dev/cluster-uid": owner["clusterUid"],
                        "kind.agentrelay.dev/fixture-name": owner["name"]}}, "spec": spec}


def preflight_policy(stack, namespace):
    """Read-only admission of the exact policy install would otherwise change."""
    from native_network import _owner, fail
    owner = _owner(stack)
    desired = egress_policy_document(owner, egress_policy_spec(stack, namespace))
    namespaces = json.loads(stack.k("get", "namespace", "-o", "json", namespace=None).stdout).get("items", [])
    if EDGE_NAMESPACE not in {d.get("metadata", {}).get("name") for d in namespaces}:
        return desired, False
    items = json.loads(stack.k("get", "networkpolicy", "-o", "json", namespace=EDGE_NAMESPACE).stdout).get("items", [])
    selected = [p for p in items if p.get("metadata", {}).get("name") == POLICY]
    if not selected:
        return desired, False
    if len(selected) != 1:
        fail("edge egress policy identity is ambiguous")
    validate_policy(selected[0], desired)
    return desired, True


def validate_policy(actual, desired):
    from native_network import fail
    meta = actual.get("metadata", {})
    ann = meta.get("annotations", {})
    if (actual.get("kind") != "NetworkPolicy" or meta.get("name") != POLICY or meta.get("namespace") != EDGE_NAMESPACE
            or meta.get("deletionTimestamp")
            or not isinstance(meta.get("uid"), str) or not meta["uid"]
            or any(meta.get("labels", {}).get(k) != v for k, v in desired["metadata"]["labels"].items())
            or any(ann.get(k) != v for k, v in desired["metadata"]["annotations"].items())
            or any(k in ann for k in ("meta.helm.sh/release-name", "meta.helm.sh/release-namespace"))
            or meta.get("ownerReferences")):
        fail("manual or foreign edge egress policy requires a reviewed ownership handoff")
    if actual.get("spec") != desired["spec"]:
        fail("edge egress policy differs from the exact backend/API/DNS-only contract")


def install(stack, version, namespace, *, wait_for_route=True):
    policy, exists = preflight_policy(stack, namespace)  # before any apply or Helm action
    stack.apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": EDGE_NAMESPACE}})
    if not exists:
        # CREATE refuses a manual object that raced preflight. Existing exact
        # source-owned policy is a no-op, never an unconditional overwrite.
        created = json.loads(stack.k("create", "-f", "-", "-o", "json", namespace=EDGE_NAMESPACE, data=json.dumps(policy)).stdout)
        validate_policy(created, policy)
    values = {
        "global": {"checkNewVersion": False, "sendAnonymousUsage": False},
        "service": {"spec": {"type": "NodePort"}},
        "ports": {"web": {"nodePort": 30080}, "websecure": {"nodePort": 30443}},
        "providers": {"kubernetesIngress": {"enabled": True}, "kubernetesCRD": {"enabled": False}},
        "ingressClass": {"enabled": True, "isDefaultClass": False, "name": "traefik"}}
    path = stack.state / "edge-values.json"
    path.write_text(json.dumps(values, indent=2) + "\n")
    path.chmod(0o600)
    stack.cmd(["helm", "upgrade", "--install", "kind-edge", "traefik/traefik", "--version", version,
               "-n", "kind-edge", "-f", path, "--wait", "--timeout", "5m"], timeout=330)
    if wait_for_route:
        verify_application_route(stack)


def verify_application_route(stack):
    # A ready ingress pod can still be serving its default certificate while
    # loading providers. Require the actual trusted application route too.
    deadline = time.monotonic() + 45
    last = "route not ready"
    while time.monotonic() < deadline:
        context = ssl.create_default_context(cafile=str(stack.state / "ca.crt"))
        context.verify_flags |= ssl.VERIFY_X509_STRICT
        connection = http.client.HTTPSConnection("relay.kind.agentrelay.com", 8443, context=context, timeout=3)
        connection._create_connection = lambda address, timeout, source_address=None: socket.create_connection(("127.0.0.1", 8443), timeout)
        try:
            connection.request("GET", "/")
            response = connection.getresponse()
            response.read()
            if response.status == 200:
                return
            last = f"HTTP {response.status}"
        except (OSError, http.client.HTTPException) as error:
            # This fixed unauthenticated localhost route has no credentials
            # in its URL, headers or exception context.
            last = f"{type(error).__name__}: {error}"
        finally:
            connection.close()
        time.sleep(1)
    raise ValueError(f"local edge did not serve the application over verified TLS: {last}")
