"""Pinned local ingress with backend/API/DNS-only egress."""
import ipaddress
import json


def install(stack, version, namespace):
    endpoints = json.loads(stack.k("get", "endpoints", "kubernetes", "-o", "json", namespace="default").stdout)
    service = json.loads(stack.k("get", "service", "kubernetes", "-o", "json", namespace="default").stdout)
    addresses = {service["spec"]["clusterIP"]}
    ports = {443}
    for subset in endpoints["subsets"]:
        addresses.update(a["ip"] for a in subset["addresses"])
        ports.update(p["port"] for p in subset["ports"])
    targets = [{"ipBlock": {"cidr": f"{ip}/{ipaddress.ip_address(ip).max_prefixlen}"}} for ip in sorted(addresses)]
    stack.apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "kind-edge"}})
    stack.apply({"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
                 "metadata": {"name": "kind-edge-no-external-egress", "namespace": "kind-edge"}, "spec": {
                     "podSelector": {}, "policyTypes": ["Egress"], "egress": [
                         {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": namespace}}, "podSelector": {}}]},
                         {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
                                  "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
                          "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
                         {"to": targets, "ports": [{"protocol": "TCP", "port": p} for p in sorted(ports)]}]}})
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
