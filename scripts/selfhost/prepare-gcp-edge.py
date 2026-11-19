#!/usr/bin/env python3
"""Prepare non-secret Helm overlays and Desktop inputs; never deploy or publish."""

import argparse
import base64
import json
from pathlib import Path
import re
import sys


def checked(value, pattern, label):
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise ValueError(f"invalid {label}")
    return value


def prepare(config):
    hosts = config["hosts"]
    if set(hosts) != {"root", "api", "cast", "history"}:
        raise ValueError("hosts must contain exactly root, api, cast and history")
    host_pattern = r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?"
    for name, host in hosts.items():
        checked(host, host_pattern, f"{name} hostname")
        if (host.rsplit(".", 1)[1] in {"invalid", "test", "localhost", "local", "internal", "lan", "example", "onion"}
                or host.endswith(".home.arpa") or re.search(r"\.example\.(com|net|org)$", host)):
            raise ValueError(f"{name} hostname must use public DNS")
    if len(set(hosts.values())) != 4:
        raise ValueError("the four hostnames must be distinct")
    edge_config = config.get("edge", {})
    mode = edge_config.get("mode", "google-managed")
    if mode not in {"google-managed", "cloudflare"}:
        raise ValueError("edge.mode must be google-managed or cloudflare")
    flat = edge_config.get("require_single_level_zone", False)
    gate_only = edge_config.get("gate_only", False)
    if not isinstance(flat, bool) or not isinstance(gate_only, bool):
        raise ValueError("edge flags must be booleans")
    if flat and len({host.split(".", 1)[1] for host in hosts.values()}) != 1:
        raise ValueError("all four hosts must be flat names under the same zone")
    origins = {name: f"https://{host}" for name, host in hosts.items()}
    desktop = config["desktop"]
    profile = checked(desktop["profile"], r"[a-z0-9]{1,32}", "desktop profile")
    scheme = checked(desktop["url_scheme"], r"[a-z][a-z0-9+.-]{0,63}", "URL scheme")
    if scheme in {"http", "https", "agentrelay"}:
        raise ValueError("use the customer's dedicated desktop URL scheme")
    bundle = checked(desktop["bundle_id"], r"(?=.{1,32}$)[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+", "bundle id")
    if bundle.lower() == "com.agentrelay.desktop":
        raise ValueError("use the customer's dedicated desktop bundle id")
    product = checked(desktop["product_name"], r'[^\x00-\x1f\x7f/\\":*?<>|{},]+', "product name")
    if product != product.strip():
        raise ValueError("product name must not have surrounding whitespace")
    public_key = desktop["feed_public_key"]
    try:
        decoded = base64.b64decode(public_key, validate=True)
    except (ValueError, TypeError) as exc:
        raise ValueError("feed_public_key must be base64 for 32 public bytes") from exc
    if len(decoded) != 32 or base64.b64encode(decoded).decode() != public_key:
        raise ValueError("feed_public_key must be canonical base64 for 32 public bytes")
    feed = config["feed"]
    bucket = checked(feed["bucket"], r"(?=.{3,63}$)[a-z0-9][a-z0-9._-]*[a-z0-9]", "feed bucket")
    prefix = checked(feed["prefix"], r"[a-zA-Z0-9_-]+(?:/[a-zA-Z0-9_-]+)*", "feed prefix")
    label = checked(feed["key_label"], r"[a-z0-9]{1,16}", "feed key label")
    secret = checked(feed["existing_secret"], r"(?=.{1,253}$)[a-z0-9](?:[-a-z0-9]*[a-z0-9])?(?:\.[a-z0-9](?:[-a-z0-9]*[a-z0-9])?)*", "signing Secret name")

    edge = {
        "gkeIngress": {
            "enabled": True, "mode": "external", "name": "agent-relay", "staticIpName": "agent-relay-ingress",
            "managedCertificateName": "agent-relay", "frontendConfigName": "agent-relay",
            "tlsSecretName": "", "hosts": hosts,
        },
        "relaycast": {"baseUrl": origins["cast"], "ingress": {"enabled": False},
                      "service": {"backendConfig": "agent-relay-cast"}},
        "sessions-pipeline": {
            "sessionReadApi": {"origin": origins["history"], "cors": {"allowedOrigins": [origins["root"]]}},
            "ingestEdge": {"origin": origins["history"]},
            "alleyoop": {"auth": {"historyOrigin": origins["history"]}},
        },
        "relay-control": {
            "publicUrl": origins["api"], "dashboardUrl": origins["root"] + "/",
            "auth": {"trustedProxies": 2},
            "services": {"relaycastPublicUrl": origins["cast"], "sessionReadApiPublicUrl": origins["history"]},
            "introspection": {"audiences": [origins["history"], origins["api"]]},
            "ingress": {"enabled": False},
            "service": {"backendConfig": "agent-relay-api", "annotations": {"cloud.google.com/neg": '{"ingress":true}'}},
            # Override Terraform's feed storage until its existing signer is ready.
            "extraEnv": [], "desktopFeed": {"signingKeys": {"existingSecret": "", "profiles": []}},
        },
        "relay-webapp": {
            "runtime": {"publicUrl": origins["root"]},
            "customerProfile": {"desktop": {"siteUrl": origins["root"], "urlScheme": scheme}},
            "ingress": {"enabled": False},
            "service": {"annotations": {
                "cloud.google.com/neg": '{"ingress":true}',
            }},
        },
    }
    if mode == "cloudflare":
        edge["gkeIngress"].update({"managedCertificateName": "", "tlsSecretName": "agent-relay-origin-tls",
                                   "sslPolicy": "agent-relay-tls", "securityPolicy": "agent-relay-edge"})
        edge["relay-webapp"]["service"]["annotations"]["cloud.google.com/backend-config"] = '{"default":"agent-relay-dashboard"}'
    if gate_only:
        edge["relaygate"] = {
            "proxy": {"sessionsUrl": origins["history"], "sessionsHosts": [hosts["history"]],
                      "sessionsCorsOrigins": [origins["root"]]},
            "control": {"sessionIngestAudience": origins["history"],
                        "introspectUrl": "http://relay-control.agent-relay.svc.cluster.local/internal/v1/auth/introspect"},
        }
    feed_values = {"relay-control": {
        "desktopFeed": {"signingKeys": {"existingSecret": secret, "profiles": [profile]}},
        "extraEnv": [{"name": key, "value": value} for key, value in {
            "SELFHOST_DESKTOP_FEED_STORAGE": "gcs", "SELFHOST_DESKTOP_FEED_GCS_BUCKET": bucket,
            "SELFHOST_DESKTOP_FEED_GCS_PREFIX": prefix, "SELFHOST_DESKTOP_FEED_KEY_LABEL": label,
        }.items()],
    }}
    build = {
        "repository": "AgentWorkforce/relay-app", "environment": f"desktop-{profile}",
        "workflow": "desktop-release.yml",
        "inputs": {"profile": profile, "prepare-only": True, "channel": "stable"},
        "environment_secrets": {
            "AGENT_RELAY_SITE_URL": origins["root"], "AGENT_RELAY_URL_SCHEME": scheme,
            "DESKTOP_PRODUCT_NAME": product, "DESKTOP_BUNDLE_ID": bundle,
            "RELEASE_FEED": "cloud", "DESKTOP_FEED_PUBLIC_KEY": public_key,
        },
        "required_existing_secrets": ["DESKTOP_FEED_PUBLISHER_TOKEN"],
        "required_unset_secrets": ["RELEASES_REPOSITORY"],
        "signing_secret_key_name": f"{profile}.pem",
        "feed_key_id": f"fk_{profile}_{label}",
        "mcp": {"origin": origins["api"], "url": origins["api"] + "/mcp"},
    }
    outputs = {"edge.values.json": edge, "desktop-feed.values.json": feed_values, "desktop-build.json": build}
    if mode == "cloudflare":
        outputs["origin-locked.values.json"] = {"relay-control": {"auth": {"trustedProxies": 3}}}
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    try:
        outputs = prepare(json.loads(args.config.read_text()))
        args.output_dir.mkdir(parents=True, exist_ok=True)
        if any((args.output_dir / name).exists() for name in outputs):
            raise ValueError("output files already exist; use a new output directory")
        for name, value in outputs.items():
            with (args.output_dir / name).open("x", encoding="utf-8") as handle:
                handle.write(json.dumps(value, indent=2) + "\n")
    except (ValueError, KeyError, OSError) as exc:
        print(f"Cannot prepare configuration: {exc}", file=sys.stderr)
        return 1
    print(f"Prepared {len(outputs)} non-secret configuration files. Nothing deployed or published.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
