#!/usr/bin/env python3
"""A disposable, source-free local core from published, immutable images.

This entry point owns only agent-relay-local and .kind/local in this checkout.
It does not consume qualification packets from the separate operator lifecycle.
"""
from datetime import datetime, timezone
from copy import deepcopy
import base64
import hashlib
import importlib.util
import errno
from email import policy
from email.parser import Parser
import json
import os
import secrets
import re
import shutil
import socket
import sys
import time

import yaml

from stack import Stack, StackError, ROOT, NS, NODE, POSTGRES, private_json
from native_core_values import compose
from native_recipe import SECRET_KEYS, merge_values
from local_host_setup import certificate_present, host_aliases_present, managed_cas
from local_actors import recipe as actor_recipe, build as build_actors, load as load_actors

LOCAL_VALUES = yaml.safe_load((ROOT / "ci/agent-relay/kind/local-values.yaml").read_text())
DESKTOP_RELEASE_VALUES = yaml.safe_load((ROOT / "ci/agent-relay/kind/desktop-releases-values.yaml").read_text())
AA_VALUES = yaml.safe_load((ROOT / "charts/agent-relay/values-eks.yaml").read_text())
READER_VALUES = yaml.safe_load((ROOT / "charts/session-read-api/values.yaml").read_text())
SCRUB_VALUES = yaml.safe_load((ROOT / "charts/agent-relay/values-scrub-wasm-bindgen.yaml").read_text())["global"]["scrubEngine"]


def reference(value):
    return value["repository"] + "@" + value["digest"]


def desktop_releases_enabled(environ=None):
    value = (os.environ if environ is None else environ).get("LOCAL_DESKTOP_RELEASES", "0")
    if value not in ("", "0", "1"):
        raise StackError("LOCAL_DESKTOP_RELEASES must be 0 or 1")
    return value == "1"


def candidate_profile(base, root=None, environ=None):
    """Select a checked-in release ledger before any local infrastructure changes."""
    environ = os.environ if environ is None else environ
    version = environ.get("LOCAL_RELEASE_CANDIDATE", "")
    if not version:
        return base
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise StackError("LOCAL_RELEASE_CANDIDATE must be a strict stable version")
    if desktop_releases_enabled(environ):
        raise StackError("LOCAL_RELEASE_CANDIDATE cannot be combined with LOCAL_DESKTOP_RELEASES")
    root = ROOT if root is None else root
    directory = root / "releases" / ("agent-relay-" + version)
    pins, values = directory / "pins.json", directory / "values.yaml"
    if any(path.is_symlink() for path in (root / "releases", directory, pins, values)):
        raise StackError("local candidate files must not be symlinks")
    try:
        spec = importlib.util.spec_from_file_location("local_release_candidate", ROOT / "scripts/release/update-release-candidate.py")
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        ledger = helper.validate_candidate(pins, values, version)
        if set(ledger["pins"]) != {"relay-control", "relay-webapp", "sessions-pipeline"}:
            raise ValueError("incomplete candidate")
        overlay = yaml.safe_load(values.read_text())
    except (OSError, ValueError, KeyError, TypeError):
        raise StackError("local candidate ledger/values validation failed") from None
    return merge_values(base, overlay)


def profile_images(experimental):
    values = DESKTOP_RELEASE_VALUES if experimental else AA_VALUES
    return tuple(reference(values[name]["image"]) for name in ("relay-control", "relay-webapp"))


DESKTOP_RELEASES = desktop_releases_enabled()
AA_VALUES = candidate_profile(AA_VALUES)


def cast_backend(environ=None):
    value = (os.environ if environ is None else environ).get("LOCAL_RELAYCAST_BACKEND", "durable-actors")
    if value not in {"durable-actors", "postgres", "sqlite"}:
        raise StackError("LOCAL_RELAYCAST_BACKEND must be durable-actors, postgres or sqlite")
    return value


CAST_BACKEND = cast_backend()
ACTORS = actor_recipe()
PIPELINE = reference(AA_VALUES["sessions-pipeline"]["worker"]["image"])
if PIPELINE != reference(AA_VALUES["sessions-pipeline"]["alleyoop"]["image"]):
    raise StackError("the AA profile must select one services-image generation")
CONTROL, WEBAPP = profile_images(DESKTOP_RELEASES)
CAST = ACTORS["source"]["gateway"]["reference"] if CAST_BACKEND == "durable-actors" else reference(AA_VALUES["relaycast"]["image"])
MINIO = "cgr.dev/chainguard/minio@sha256:e70b2b1e74d79457f808710483bd726ff364529ca30736eaa15a6ab547d3a5a7"
SITE = "https://relay.kind.agentrelay.com"
HISTORY = "https://history.kind.agentrelay.com:8443"
PGHOST = "postgres.agent-relay.svc.cluster.local"
COLLECTOR_URL = "https://telemetry-collector.agent-relay.svc.cluster.local:8443/v1/events"
TELEMETRY = {"control": "relaycontrol", "ingest": "session-ingest", "consumer": "session-pipeline-consumer", "reader": "session-read-api", "brief": "session-brief", "cast": "relaycast"}
HOSTS = [PGHOST, "relay.kind.agentrelay.com", "cast.kind.agentrelay.com", "history.kind.agentrelay.com", "files.kind.agentrelay.com", "telemetry-collector.agent-relay.svc.cluster.local"]


def image(ref):
    repository, digest = ref.split("@")
    return {"repository": repository, "digest": digest, "pullPolicy": "IfNotPresent"}


def public_https_egress(name, selector):
    return {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": {"name": name, "namespace": NS},
        "spec": {"podSelector": {"matchLabels": selector}, "policyTypes": ["Egress"],
            "egress": [{"to": [{"ipBlock": {"cidr": "0.0.0.0/0",
                "except": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"]}}],
                "ports": [{"protocol": "TCP", "port": 443}]}]}}


def scrub_environment():
    return [{"name": name, "value": SCRUB_VALUES[key]} for name, key in (
        ("SCRUB_ENGINE", "engine"), ("SCRUB_ENGINE_REQUIRED", "required"), ("READER_MAX_RULESET", "readerMaxRuleset"))]


def fresh_reader(reader):
    # This local store has no Neon history. Include that turns assumption with
    # Sales #50's fresh-native settings. The 0.2.9 reader accepts extraEnv;
    # 0.2.10 adds managed values and reserves the corresponding env names.
    for section, key, name in (("turns", "assumeNoLegacy", "READ_API_TURNS_ASSUME_NO_LEGACY"),
            ("timing", "assumeNoTurns", "READ_API_TIMING_ASSUME_NO_TURNS"),
            ("canonical", "pinLaggingPointer", "READ_API_CANONICAL_PIN_LAGGING_POINTER")):
        if section in READER_VALUES:
            reader.setdefault(section, {})[key] = True
        else:
            reader.setdefault("extraEnv", []).append(env(name, "true"))


def operator():
    return {"version": 1, "administrator": {"email": "owner@kind.example", "displayName": "Local owner"},
        "organizationName": "Local development", "workspaceName": "Default",
        "owner": {"name": "local-control-owner", "key": "database-migrations-url", "role": "control_owner"},
        "runtime": {"name": "local-control", "databaseKey": "database-url", "role": "control_api_runtime",
            "bootstrapKey": "bootstrap-token", "encryptionKey": "encryption-key", "encryptionKeyId": "local-1",
            "castInternalKey": "cast-secret", "internalKey": "internal-token",
            "introspectionKey": "introspect-secret", "readerIssuerKey": "reader-secret"},
        "cast": {"name": "local-cast", "internalKey": "internal-secret", "bootstrapKey": "workspace-bootstrap-secret"}}


class LocalStack(Stack):
    def identity_layout(self, profile):
        return "agent-relay-local", ROOT / ".kind" / "local"

    def owned(self):
        if not self.marker.exists():
            raise StackError("agent-relay-local already exists without this checkout's ownership file")
        record = json.loads(self.marker.read_text())
        if (record.get("version") != 1 or record.get("name") != self.name or record.get("profile") != "core" or
                record.get("clusterUid") != self.cluster_uid(self.kubeconfig) or record.get("dockerHost") != self.env["DOCKER_HOST"]):
            raise StackError("local cluster identity or Docker endpoint changed")

    def require_owned_cluster(self):
        self.owned()

    def cluster(self):
        if self.name in self.cmd(["kind", "get", "clusters"]).stdout.splitlines():
            self.owned()
            return
        if self.marker.exists():
            raise StackError("local cluster was removed; run make local-down to clear this checkout's local state")
        for port in (8080, 443, 8443):
            with socket.socket() as probe:
                try:
                    probe.bind(("127.0.0.1", port))
                except OSError as error:
                    # Docker Desktop's privileged port helper may publish443
                    # even though this unprivileged Python process cannot bind it.
                    if error.errno in (errno.EACCES, errno.EPERM):
                        continue
                    if error.errno == errno.EADDRINUSE:
                        raise StackError(f"local port {port} is occupied by another listener; stop it before make local-up (no foreign cluster is changed)") from None
                    raise
        config = {"kind": "Cluster", "apiVersion": "kind.x-k8s.io/v1alpha4",
            "networking": {"disableDefaultCNI": True, "podSubnet": "192.168.0.0/16"},
            "nodes": [{"role": "control-plane", "extraPortMappings": self.native_port_mappings()}]}
        path = self.state / "kind.yaml"
        path.write_text(yaml.safe_dump(config))
        print("Create disposable agent-relay-local cluster", flush=True)
        self.cmd(["kind", "create", "cluster", "--name", self.name, "--image", NODE,
            "--config", path, "--kubeconfig", self.kubeconfig], timeout=600)
        self.kubeconfig.chmod(0o600)
        private_json(self.marker, {"version": 1, "name": self.name, "profile": "core", "dockerHost": self.env["DOCKER_HOST"],
            "clusterUid": self.cluster_uid(self.kubeconfig)})

    def stage(self, name, fn):
        path = self.state / "phases.json"
        phases = json.loads(path.read_text()) if path.exists() else []
        if name not in phases:
            print("Local install: " + name, flush=True)
            fn()
            private_json(path, phases + [name])

    def sql(self, database, text, variables=()):
        return self.psql(database, text, variables=variables, sensitive=True)

    def source_files(self, paths):
        code = "import fs from 'node:fs';console.log(JSON.stringify(Object.fromEntries(" + json.dumps(paths) + ".map(p=>[p,fs.readFileSync('/app/'+p,'utf8')]))));"
        return json.loads(self.cmd([*self.docker_args, "run", "--rm", "--network", "none", "--entrypoint", "bun", PIPELINE, "-e", code]).stdout)

    def job(self, name, image_ref, command=None, env=None, mounts=None, volumes=None):
        old = self.k("get", "job", name, "-o", "json", "--ignore-not-found=true").stdout.strip()
        if old:
            if json.loads(old).get("status", {}).get("succeeded") == 1:
                return
            raise StackError("local Job " + name + " did not succeed; inspect it, then recreate the disposable stack with make local-down/local-up")
        environment = list(env or [])
        if image_ref == PIPELINE:
            if {e["name"] for e in environment} & {e["name"] for e in scrub_environment()}:
                raise StackError("local services Jobs must use the managed AA scrub contract")
            environment.extend(scrub_environment())
        container = {"name": "run", "image": image_ref, "env": environment, "volumeMounts": mounts or [],
            "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}}}
        if command:
            container["command"] = command
        self.apply({"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": name, "namespace": NS},
            "spec": {"backoffLimit": 0, "activeDeadlineSeconds": 900, "template": {"spec": {
                "restartPolicy": "Never", "automountServiceAccountToken": False,
                "securityContext": {"runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000},
                "containers": [container], "volumes": volumes or []}}}})
        self.wait_job(name, seconds=900)

    def postgres_local(self, credentials):
        self.secret("local-postgres", {"password": credentials["postgres"]})
        self.apply({"apiVersion": "v1", "kind": "Service", "metadata": {"name": "postgres", "namespace": NS},
            "spec": {"selector": {"app": "local-postgres"}, "ports": [{"port": 5432}]}})
        self.apply({"apiVersion": "apps/v1", "kind": "StatefulSet", "metadata": {"name": "postgres", "namespace": NS},
            "spec": {"serviceName": "postgres", "replicas": 1, "selector": {"matchLabels": {"app": "local-postgres"}},
                "template": {"metadata": {"labels": {"app": "local-postgres"}}, "spec": {
                    "securityContext": {"fsGroup": 999}, "containers": [{"name": "postgres", "image": POSTGRES,
                        "args": ["-c", "ssl=on", "-c", "ssl_cert_file=/tls/tls.crt", "-c", "ssl_key_file=/tls/tls.key"],
                        "env": [secret_env("POSTGRES_PASSWORD", "local-postgres", "password"), env("PGDATA", "/var/lib/postgresql/data/pgdata")],
                        "volumeMounts": [{"name": "data", "mountPath": "/var/lib/postgresql/data"}, {"name": "tls", "mountPath": "/tls", "readOnly": True}],
                        "readinessProbe": {"exec": {"command": ["pg_isready", "-U", "postgres"]}, "periodSeconds": 3}}],
                    "volumes": [{"name": "tls", "secret": {"secretName": "kind-tls", "defaultMode": 0o440}}]}},
                "volumeClaimTemplates": [{"metadata": {"name": "data"}, "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "4Gi"}}}}]}})
        self.k("rollout", "status", "statefulset/postgres", "--timeout=300s", timeout=330)

    def databases(self, c):
        # The isolated Postgres collector companion is available in every lane.
        roles = ("hoop", "control_owner", "control_api_runtime", "relaycast_owner", "relaycast_runtime")
        self.sql("postgres", "\n".join("CREATE ROLE " + role + " LOGIN NOINHERIT PASSWORD '" + c[role] + "';" for role in roles) +
            "\nCREATE DATABASE hoopdb OWNER hoop;\nCREATE DATABASE relaycontrol OWNER control_owner;\nCREATE DATABASE relaycast;")
        # Match the image's identity checks: the migration role owns only the
        # schema, never the database; runtime has DML, no DDL or TEMP privilege.
        self.sql("relaycast", """ALTER SCHEMA public OWNER TO relaycast_owner;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO relaycast_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO relaycast_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public
  GRANT SELECT, USAGE, UPDATE ON SEQUENCES TO relaycast_runtime;
REVOKE TEMP, CREATE ON DATABASE relaycast FROM PUBLIC;
GRANT TEMP ON DATABASE relaycast TO relaycast_owner;""")
        self.sql("hoopdb", "CREATE EXTENSION vector; CREATE EXTENSION pg_trgm; CREATE EXTENSION btree_gin;")

    def storage(self, c):
        self.secret("local-locker", {"rootUser": "locker", "rootPassword": c["locker"]})
        self.apply({"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "locker", "namespace": NS},
            "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "2Gi"}}}})
        self.apply({"apiVersion": "v1", "kind": "Service", "metadata": {"name": "locker", "namespace": NS},
            "spec": {"selector": {"app": "local-locker"}, "ports": [{"port": 9000}]}})
        self.apply({"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "session-object-storage", "namespace": NS},
            "spec": {"replicas": 1, "strategy": {"type": "Recreate"}, "selector": {"matchLabels": {"app": "local-locker"}},
                "template": {"metadata": {"labels": {"app": "local-locker"}}, "spec": {"securityContext": {"fsGroup": 1000},
                    "containers": [{"name": "minio", "image": MINIO, "args": ["server", "/data"],
                        "env": [secret_env("MINIO_ROOT_USER", "local-locker", "rootUser"), secret_env("MINIO_ROOT_PASSWORD", "local-locker", "rootPassword")],
                        "volumeMounts": [{"name": "data", "mountPath": "/data"}],
                        "readinessProbe": {"httpGet": {"path": "/minio/health/ready", "port": 9000}, "periodSeconds": 3}}],
                    "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "locker"}}]}}}})
        self.k("rollout", "status", "deployment/session-object-storage", "--timeout=300s", timeout=330)
        self.job("local-locker-init", PIPELINE, ["bun", "src/locker/init.ts"], locker_env())

    def pipeline_schema(self, c):
        names = ["session_directory_search_worker", "session_token_verifier", "session_ingest_roles", "session_read_api_roles", "session_consumer_roles", "hoopdb_runtime_role", "hoopdb_function_default_revoke", "session_consumer_credential_probe"]
        paths = ["supabase/tests/supabase_shim.sql"] + ["supabase/bootstrap/" + n + ".sql" for n in names]
        files = self.source_files(paths)
        self.sql("hoopdb", files[paths[0]])
        for name in names[:4]:
            self.sql("hoopdb", files["supabase/bootstrap/" + name + ".sql"])
        self.sql("hoopdb", "ALTER ROLE hoop CREATEROLE; SET ROLE hoop; SET createrole_self_grant=''; CREATE SCHEMA sessions; CREATE SCHEMA search_index;\n" + files["supabase/bootstrap/session_consumer_roles.sql"])
        self.sql("hoopdb", files["supabase/bootstrap/hoopdb_runtime_role.sql"], ["runtime_role=sessions_pipeline_runtime", "runtime_login=true"])
        self.sql("hoopdb", files["supabase/bootstrap/hoopdb_function_default_revoke.sql"], ["migration_owner=hoop"])
        self.secret("local-pipeline-owner", {"url": pgurl("hoop", c, "/var/run/local-ca/ca.crt"), "consumer-json": json.dumps({"hoopdb_url": pgurl("hoop", c, "/etc/native-consumer-postgres/ca.crt")})})

    def migrate_pipeline(self):
        # New migrations may name new principals; repeat the image's idempotent
        # privileged pre-migrate bootstraps before the unprivileged migrator.
        paths = ["supabase/bootstrap/" + n + ".sql" for n in (
            "session_directory_search_worker", "session_token_verifier", "session_ingest_roles", "session_read_api_roles")]
        for sql in self.source_files(paths).values():
            self.sql("hoopdb", sql)
        migrate_env = [env("SERVICE", "hoopdb-migrate"), secret_env("HOOPDB_URL", "local-pipeline-owner", "url"),
            env("HOOPDB_DB_MODE", "selfhosted"), env("HOOPDB_SUPABASE_SHIM", "false"), env("HOOPDB_ROLE_BOOTSTRAP", "false"),
            env("HOOPDB_ROLE_VERIFY", "true"), env("HOOPDB_RUNTIME_ROLE", "sessions_pipeline_runtime"),
            env("HOOPDB_RUNTIME_ROLE_LOGIN", "true"), env("HOOPDB_FUNCTION_BOUNDARY_MODE", "global-default-revoke"),
            env("SESSION_POSTGRES_TLS_PROFILE", "custom-ca"), env("SESSION_POSTGRES_CA_FILE", "/var/run/local-ca/ca.crt"),
            env("SESSION_POSTGRES_CA_SHA256", self.ca_sha)]
        volumes = [{"name": "ca", "configMap": {"name": "local-ca"}}]
        mounts = [{"name": "ca", "mountPath": "/var/run/local-ca", "readOnly": True}]
        revision = PIPELINE.rsplit(":", 1)[1][:8]
        self.job("local-pipeline-migrate-" + revision, PIPELINE, env=migrate_env, mounts=mounts, volumes=volumes)
        self.job("local-pipeline-migrate-noop-" + revision, PIPELINE, env=migrate_env, mounts=mounts, volumes=volumes)

    def helm(self, values, wait=True):
        private_json(self.overrides, values)
        self.cmd(["helm", "upgrade", "--install", "agent-relay", "charts/agent-relay", "-n", NS,
            "--force-conflicts", "-f", self.overrides, *(["--wait", "--timeout", "10m"] if wait else [])], timeout=660)

    def values(self, phase, tenant=None):
        selected = {"profile": "core", "control": {"reference": CONTROL, "independentIssuer": True},
            "reference": PIPELINE, "readerLoginAdvertisesSync": False, "siteOrigin": SITE, "historyOrigin": HISTORY,
            "postgres": {"host": PGHOST}, "postgresCa": {"configMap": "local-ca", "key": "ca.crt", "sha256": self.ca_sha},
            "secretRefs": {n: {"name": "local-" + n.lower(), "key": k, "jsonField": j} for n, (k, j) in SECRET_KEYS.items()},
            "lockerBucket": "locker", "keyRoot": "96bulls", "backendId": "local-postgres", "completeSince": self.credentials["createdAt"]}
        selected["secretRefs"]["locker"]["name"] = "local-locker"
        base = yaml.safe_load((ROOT / "charts/agent-relay/values-kind-core.yaml").read_text())
        base["relay-webapp"]["image"] = image(WEBAPP)
        result = compose(base, selected, operator(), phase, tenant)
        # Import release authority only; no EKS identity, endpoint or cloud resource
        # configuration belongs in this local fixture.
        result["global"]["scrubEngine"] = deepcopy(SCRUB_VALUES)
        result["relaycast"]["image"] = image(CAST)
        cast = result["relaycast"]
        cast.setdefault("runtime", {})["backend"] = CAST_BACKEND
        if CAST_BACKEND == "durable-actors":
            repository, tag = ACTORS["actorTag"].rsplit(":", 1)
            cast["runtime"]["durableActors"] = {
                "gateway": {"image": image(CAST)}, "fileStore": {"driver": "local"},
                "deployer": {"enabled": False},
                "devRuntime": {"enabled": True, "acknowledgeNonProduction": True,
                    "existingClaim": "local-relaycast-actors", "image": {"repository": repository, "tag": tag, "pullPolicy": "Never"}}}
            cast["credentials"] = {"format": "ar", "authority": "self"}
            cast["secretKeys"].update(credentialKeyring="credential-keyring", workspaceBootstrapSecret="workspace-bootstrap-secret")
            cast["analytics"] = {"enabled": False}
            cast["podSecurityContext"] = {"fsGroup": 10000}
            built = getattr(self, "actor_build", None)
            if built:
                cast.setdefault("podAnnotations", {})["local.agentrelay.dev/actor-image-id"] = built["actorImageId"]
        elif CAST_BACKEND == "postgres":
            cast["runtime"]["postgres"] = {"image": image(CAST)}
            cast["postgresCa"] = {"enabled": True, "configMap": "local-ca", "key": "ca.crt"}
        result["relay-webapp"]["image"] = image(WEBAPP)
        result["relay-webapp"]["runtime"]["coordinationOverlapsEnabled"] = False
        result["relay-webapp"]["customerProfile"]["desktop"]["siteUrl"] = SITE
        result["relay-control"]["image"] = image(CONTROL)
        # Usage and launch are Control APIs; they add no optional workload.
        result["relay-control"]["selectedFeatures"] = list(AA_VALUES["relay-control"]["selectedFeatures"])
        if DESKTOP_RELEASES:
            result["relay-control"].setdefault("extraEnv", []).append(env("SELFHOST_DESKTOP_RELEASES_REPO",
                DESKTOP_RELEASE_VALUES["relay-control"]["desktopReleasesRepo"]))
        result["relay-control"]["auth"] = {"emailLink": {"enabled": True}}
        result["relay-control"]["smtp"] = {"host": "local-mail.agent-relay.svc.cluster.local", "port": 1025, "security": "none", "from": "Local Relay <signin@kind.example>"}
        result["relay-control"]["services"]["publicHostAliases"] = [{"ip": self.edge_ip, "hostnames": ["relay.kind.agentrelay.com"]}]
        for slot in ("nativeConsumer", "ingestEdge", "sessionReadApi"):
            result["sessions-pipeline"][slot]["image"] = image(PIPELINE)
        result["sessions-pipeline"]["sessionReadApi"]["cors"] = {"allowedOrigins": [SITE]}
        result["sessions-pipeline"]["sessionReadApi"].setdefault("extraEnv", []).append(env("READ_API_SESSION_QUERY", "true"))
        fresh_reader(result["sessions-pipeline"]["sessionReadApi"])
        result["sessions-pipeline"]["ingestEdge"]["admission"] = {"mode": "async", "scanIntervalMs": 1000}
        if phase == "serve":
            result["components"]["telemetryCollector"] = True
            result["telemetry-collector"] = {
                "fullnameOverride": "telemetry-collector", "image": LOCAL_VALUES["telemetry-collector"]["image"],
                "tlsProxy": LOCAL_VALUES["telemetry-collector"]["tlsProxy"], "producersSecret": "local-telemetry-producers",
                "tlsSecret": "kind-tls", "rolloutRevision": "local-2-" + getattr(self, "leaf_sha", self.ca_sha),
                "persistence": {"existingClaim": "local-telemetry"},
                "networkPolicy": {"allowedFrom": [{"podSelector": {"matchLabels": {"agentworkforce.dev/analytics-producer": "true"}}}]}}
            analytics = lambda name: {"enabled": True, "deploymentId": "local-kind", "collectorUrl": COLLECTOR_URL,
                "existingSecret": "local-telemetry-" + name, "caConfigMap": "local-ca"}
            result["relay-control"]["analytics"] = {**analytics("control"), "profile": "development"}
            if CAST_BACKEND != "durable-actors":
                result["relaycast"]["analytics"] = analytics("cast")
            for slot, producer in (("ingestEdge", "ingest"), ("nativeConsumer", "consumer"), ("sessionReadApi", "reader")):
                result["sessions-pipeline"][slot]["analytics"] = analytics(producer)
            worker = result["sessions-pipeline"]["worker"]
            worker.update(image=image(PIPELINE), existingSecret="local-brief", hoopdb={"existingSecret": "local-brief", "key": "HOOPDB_URL"},
                postgresCa={"enabled": True, "configMap": "local-ca", "key": "ca.crt", "sha256": self.ca_sha},
                locker={"endpoint": "http://locker.agent-relay.svc.cluster.local:9000", "bucket": "locker", "region": "us-east-1"},
                secretKeys={"lockerAccessKeyId": "rootUser", "lockerSecretAccessKey": "rootPassword"},
                nativeBrief={"enabled": True, "image": image(PIPELINE), "workspaceIds": [tenant["workspaceId"]],
                    "keyPrefix": "96bulls", "sweepSeconds": 5, "batch": 1, "globalDailyCap": 64, "sessionDailyCap": 3,
                    "analytics": analytics("brief"),
                    "openaiSecret": {"name": "local-model", "key": "OPENAI_API_KEY"}})
            worker["components"]["session-brief"] = {"enabled": True, "fullnameOverride": "session-brief", "replicas": 1}
            worker["components"]["session-brief"]["env"] = [env("SESSION_BRIEF_IDLE_SECONDS", "0"), env("SESSION_BRIEF_MAX_WAIT_SECONDS", "0")]
            worker["podAnnotations"] = {"local.agentrelay.dev/model-key-sha256": getattr(self, "model_key_sha", "unconfigured")}
            result["sessions-pipeline"]["nativeConsumer"]["legacyRuntimesQualified"] = True
        return result

    def support_credentials(self, c):
        # This fixture has exactly one Kind node and one Recreate writer. Use
        # its local-path RWO volume; production's CSI/RWOP default is unchanged.
        self.apply({"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "local-telemetry", "namespace": NS},
            "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}}})
        producers, tokens = [], {}
        for name, component in TELEMETRY.items():
            token = c["collector"] if name == "control" else c["collector_" + name]
            self.secret("local-telemetry-" + name, {"token": token})
            tokens[name] = token
            producers.append({"name": "local-" + name, "component": component, "deployment_id": "local-kind",
                "token_file": "/var/run/secrets/telemetry-producers/" + name})
        self.secret("local-telemetry-producers", {"producers.json": json.dumps(producers), **tokens})
        self.sql("hoopdb", "ALTER ROLE sessions_pipeline_runtime PASSWORD '" + c["sessions_pipeline_runtime"] + "';")
        self.secret("local-brief", {"HOOPDB_URL": pgurl("sessions_pipeline_runtime", c, "/etc/postgres-ca/ca.crt"),
            "rootUser": "locker", "rootPassword": c["locker"], "SUMMARY_MASTER_KEYS": "local1:" + c["encryption"]})
        self.configure_model()

    def github_releases_egress(self):
        if DESKTOP_RELEASES:
            self.apply(public_https_egress("local-control-github-releases-egress", {
                "app.kubernetes.io/name": "relay-control", "app.kubernetes.io/instance": "agent-relay",
                "app.kubernetes.io/component": "api"}))

    def configure_model(self, key=None):
        # Repeating local-up without an environment override preserves a key
        # already supplied to this disposable stack through its local Secret.
        if key is None:
            key = os.environ.get("OPENAI_API_KEY")
        if key is None:
            current = self.k("get", "secret", "local-model", "-o", "json", "--ignore-not-found=true", sensitive=True).stdout.strip()
            if current:
                key = base64.b64decode(json.loads(current).get("data", {}).get("OPENAI_API_KEY", "")).decode()
            else:
                key = ""
                self.secret("local-model", {"OPENAI_API_KEY": key})
        else:
            self.secret("local-model", {"OPENAI_API_KEY": key})
        self.model_key_sha = hashlib.sha256(key.encode()).hexdigest()
        if key:
            self.apply(public_https_egress("local-brief-model-egress", {
                "app.kubernetes.io/instance": "agent-relay", "app.kubernetes.io/component": "session-brief"}))
        else:
            self.k("delete", "networkpolicy", "local-brief-model-egress", "--ignore-not-found=true")
            print("OPENAI_API_KEY is missing: brief worker will run without making model calls.", flush=True)

    def install_model_key(self):
        self.docker(require_space=False)
        self.owned()
        key = read_model_key(sys.stdin)
        self.k("get", "deployment", "sessions-session-brief", "-o", "name")
        self.configure_model(key)
        patch = {"spec": {"template": {"metadata": {"annotations": {"local.agentrelay.dev/model-key-sha256": self.model_key_sha}}}}}
        self.k("patch", "deployment", "sessions-session-brief", "--type", "merge", "--patch", json.dumps(patch))
        self.k("rollout", "status", "deployment/sessions-session-brief", "--timeout=180s", timeout=210)
        print("Local model key installed; brief worker ready. Search/summary acceptance must still be verified.")

    def control(self, c):
        self.secret("local-control-owner", {"database-migrations-url": pgurl("control_owner", c, "/etc/postgres-ca/ca.crt", "relaycontrol")})
        self.secret("local-control", {"database-url": pgurl("control_api_runtime", c, "/etc/postgres-ca/ca.crt", "relaycontrol"),
            "bootstrap-token": c["bootstrap"], "encryption-key": c["encryption"], "cast-secret": c["cast"],
            "internal-token": c["internal"], "introspect-secret": c["introspection"], "reader-secret": c["readerIssuer"]})
        cast = {"internal-secret": c["cast"], "workspace-bootstrap-secret": c["castBootstrap"]}
        if CAST_BACKEND == "durable-actors":
            cast.update({"credential-keyring": json.dumps({"current": "local", "keys": {"local": c["castKeyring"]}}),
                "file-signing-secret": c["castFiles"], "durable-actors-dev-secret": c["castActors"]})
            self.apply({"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "local-relaycast-actors", "namespace": NS},
                "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}}})
        elif CAST_BACKEND == "postgres":
            cast.update({"database-owner-url": pgurl("relaycast_owner", c, None, "relaycast"),
                "database-runtime-url": pgurl("relaycast_runtime", c, None, "relaycast")})
        self.secret("local-cast", cast)
        self.secret("local-introspection", {"introspect-secret": c["introspection"]})
        self.secret("local-readerissuer", {"internal-secret": c["readerIssuer"]})
        self.job("local-control-migrate", CONTROL, ["node", "/app/node_modules/relay-control/dist/migrate-cli.js"],
            [env("DATABASE_MIGRATIONS_URL_FILE", "/owner/database-migrations-url"), env("SELFHOST_RUNTIME_DATABASE_ROLE", "control_api_runtime"), env("NODE_EXTRA_CA_CERTS", "/etc/postgres-ca/ca.crt")],
            [{"name": "owner", "mountPath": "/owner", "readOnly": True}, {"name": "ca", "mountPath": "/etc/postgres-ca", "readOnly": True}],
            [{"name": "owner", "secret": {"secretName": "local-control-owner"}}, {"name": "ca", "configMap": {"name": "local-ca"}}])
        self.helm(self.values("control"))
        from native_control import CONTROL_OBSERVER
        pod = self.pod("relay-control")
        deadline = time.monotonic() + 60
        while True:
            try:
                output = self.k("exec", "-i", pod, "--", "node", "-e", CONTROL_OBSERVER,
                    data=json.dumps({"bootstrapKey": "bootstrap-token", "historyOrigin": HISTORY, "organizationName": "Local development", "administratorEmail": "owner@kind.example",
                        "selectedFeatures": AA_VALUES["relay-control"]["selectedFeatures"]}), sensitive=True).stdout
                break
            except StackError:
                # First-boot tenant provisioning finishes after the process's
                # generic readiness probe. Observe its supported APIs only.
                if time.monotonic() >= deadline:
                    raise
                time.sleep(2)
        tenant = json.loads(next(line.split(" ", 1)[1] for line in output.splitlines() if line.startswith("NATIVE_CONTROL_OBSERVATION ")))
        private_json(self.state / "tenant.json", tenant)

    def mail(self):
        self.apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "local-mail", "namespace": NS},
            "data": {"mail.mjs": (ROOT / "ci/agent-relay/kind/local_mail.mjs").read_text()}})
        labels = {"app.kubernetes.io/name": "local-mail"}
        self.apply({"apiVersion": "v1", "kind": "Service", "metadata": {"name": "local-mail", "namespace": NS},
            "spec": {"selector": labels, "ports": [{"port": 1025}]}})
        self.apply({"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "local-mail", "namespace": NS},
            "spec": {"replicas": 1, "selector": {"matchLabels": labels}, "template": {"metadata": {"labels": labels}, "spec": {
                "automountServiceAccountToken": False, "securityContext": {"runAsUser": 1000, "runAsGroup": 1000},
                "containers": [{"name": "mail", "image": PIPELINE, "command": ["bun", "/mail/mail.mjs"], "env": scrub_environment(),
                    "volumeMounts": [{"name": "code", "mountPath": "/mail", "readOnly": True}],
                    "readinessProbe": {"tcpSocket": {"port": 1025}, "periodSeconds": 2},
                    "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"memory": "128Mi"}}}],
                "volumes": [{"name": "code", "configMap": {"name": "local-mail"}}]}}}})
        self.k("rollout", "status", "deployment/local-mail", "--timeout=300s", timeout=330)

    def login_link(self, force=False):
        path = self.state / "admin-login.txt"
        if not force and path.exists() and time.time() - path.stat().st_mtime < 14 * 60:
            print("Last admin sign-in link (0600; make local-login generates a new link): " + str(path))
            return path.read_text().strip()
        code = """const r=await fetch('http://127.0.0.1:3000/login/email',{method:'POST',
 headers:{origin:'https://relay.kind.agentrelay.com','content-type':'application/x-www-form-urlencoded'},
 signal:AbortSignal.timeout(20000),body:new URLSearchParams({email:'owner@kind.example',next:'/'})});console.log(JSON.stringify({status:r.status}));"""
        status = json.loads(self.k("exec", self.pod("relay-control"), "--", "node", "--input-type=module", "-e", code, sensitive=True).stdout)["status"]
        if status != 200:
            raise StackError("local sign-in email request returned HTTP " + str(status) + "; Control's normal sign-in rate limits apply")
        raw = self.k("exec", self.pod("local-mail"), "--", "bun", "-e",
            "console.log(await(await fetch('http://127.0.0.1:8025/messages')).text())", sensitive=True).stdout
        for message in reversed(json.loads(raw)):
            parsed = Parser(policy=policy.default).parsestr(message)
            body = parsed.get_body(preferencelist=("plain",)) if parsed.is_multipart() else parsed
            match = re.search(r"https://relay\.kind\.agentrelay\.com/login/email/verify\?token=[A-Za-z0-9_-]+", body.get_content())
            if match:
                path.touch(mode=0o600, exist_ok=True)
                path.chmod(0o600)
                path.write_text(match[0] + "\n")
                print("Admin sign-in link (single use, 15 min; 0600): " + str(path))
                return match[0]
        raise StackError("local mailbox has no administrator sign-in email")

    def pod(self, deployment):
        pods = json.loads(self.k("get", "pods", "-l", "app.kubernetes.io/name=" + deployment, "-o", "json").stdout)["items"]
        ready = [p for p in pods if not p["metadata"].get("deletionTimestamp") and p.get("status", {}).get("phase") == "Running"
            and p.get("status", {}).get("containerStatuses") and all(c.get("ready") for c in p["status"]["containerStatuses"])]
        if not ready:
            raise StackError("no ready local Pod for " + deployment)
        return max(ready, key=lambda p: p["metadata"]["creationTimestamp"])["metadata"]["name"]

    def native_roles(self, c):
        tenant = json.loads((self.state / "tenant.json").read_text())
        value = self.values("serve", tenant)
        bootstrap = value["sessions-pipeline"]["nativeConsumer"]["bootstrap"]
        bootstrap.update(enabled=True, phase="prepare", existingSecret="local-pipeline-owner", key="consumer-json", ownerRole="hoop")
        docs = list(yaml.safe_load_all(self.cmd(["helm", "template", "agent-relay", "charts/agent-relay", "-n", NS, "-f", "-"], data=json.dumps(value)).stdout))
        files = self.source_files(["supabase/bootstrap/" + n + ".sql" for n in ("session_consumer_credential_probe", "session_ingest_role", "session_read_api_role")])
        self.ensure_credential_probe(files["supabase/bootstrap/session_consumer_credential_probe.sql"])
        for doc in docs:
            if doc and doc["kind"] == "ConfigMap":
                self.apply(doc, chart=True)
        jobs = [d for d in docs if d and d["kind"] == "Job" and d["metadata"].get("labels", {}).get("app.kubernetes.io/component") == "native-consumer-bootstrap"]
        if len(jobs) != 1:
            raise StackError("expected one official native consumer bootstrap Job")
        jobs[0]["metadata"]["name"] += "-" + PIPELINE.rsplit(":", 1)[1][:8]
        self.apply(jobs[0], chart=True)
        self.wait_job(jobs[0]["metadata"]["name"])
        for name in ("session_ingest_role", "session_read_api_role"):
            self.sql("hoopdb", files["supabase/bootstrap/" + name + ".sql"])
        self.sql("hoopdb", "ALTER ROLE hoop NOCREATEROLE;\n" + "\n".join("ALTER ROLE " + role + " PASSWORD '" + c[role] + "';" for role in ("search_consumer_runtime", "bulls96_read_api", "bulls96_session_ingest")))
        self.secret("local-consumer", {"consumer-json": json.dumps({"hoopdb_url": pgurl("search_consumer_runtime", c, "/etc/native-consumer-postgres/ca.crt")})})
        self.secret("local-reader", {"reader-json": json.dumps({"supabase_url": pgurl("bulls96_read_api", c, "/etc/session-read-postgres/ca.crt")})})
        self.secret("local-ingest", {"database-url": pgurl("bulls96_session_ingest", c, "/etc/session-ingest-postgres/ca.crt"), "introspect-secret": c["introspection"]})

    def ensure_credential_probe(self, installer):
        row = json.loads(self.k("exec", "postgres-0", "--", "psql", "-X", "-At", "-U", "postgres", "-d", "hoopdb", "-c", """SELECT row_to_json(p) FROM (
SELECT r.rolname AS owner, p.prosecdef AS definer, p.proconfig AS config, p.prosrc AS body
FROM pg_proc p JOIN pg_roles r ON r.oid=p.proowner
WHERE p.oid=to_regprocedure('session_consumer_bootstrap_private.consumer_has_password()')) p;""", sensitive=True).stdout.strip() or "null")
        if row is None:
            self.sql("hoopdb", installer)
            return
        body = installer.split("AS $credential_probe$", 1)[1].split("$credential_probe$", 1)[0]
        if row != {"owner": "postgres", "definer": True, "config": ["search_path=pg_catalog"], "body": body}:
            raise StackError("existing local credential probe differs from the selected official installer; no function is overwritten")

    def reload_leaf_consumer(self, name, target, container, path, reload, seconds=180):
        marker = self.state / (name + "-tls.sha256")
        if marker.is_file() and marker.read_text().strip() == self.leaf_sha:
            return
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise StackError(name + " TLS projection timed out; local state preserved for retry")
            args = ["exec", target, *(["-c", container] if container else []), "--", "cat", path]
            result = self.k(*args, check=False, timeout=min(15, remaining))
            if result.returncode == 0 and hashlib.sha256(result.stdout.encode()).hexdigest() == self.leaf_sha:
                break
            time.sleep(min(1, remaining))
        # The process must reopen its certificate only after the projected
        # Secret contains the current leaf. Record success after the reload.
        reload()
        marker.touch(mode=0o600, exist_ok=True)
        marker.chmod(0o600)
        marker.write_text(self.leaf_sha + "\n")

    def prepare_pipeline_generation(self, changed):
        if changed:
            self.stop_pipeline()
        self.stage("pipeline-migrations-" + PIPELINE, self.migrate_pipeline)

    def stop_pipeline(self, seconds=180):
        names = ("session-native-ingest", "session-native-consumer", "session-read-api", "sessions-session-brief")
        deadline = time.monotonic() + seconds
        def timeout():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise StackError("pipeline shutdown timed out; migrations not started and local state preserved")
            return min(15, remaining)
        def deployments():
            return json.loads(self.k("get", "deployment", *names, "-o", "json", timeout=timeout()).stdout)["items"]
        before = deployments()
        if {d["metadata"]["name"] for d in before} != set(names):
            raise StackError("pipeline shutdown requires all four owned Deployments")
        selectors, identities = {}, {}
        for deployment in before:
            metadata, selector = deployment["metadata"], deployment["spec"]["selector"]
            if metadata.get("namespace") != NS or metadata.get("annotations", {}).get("meta.helm.sh/release-name") != "agent-relay" or not selector.get("matchLabels") or selector.get("matchExpressions"):
                raise StackError("pipeline shutdown refused an unowned or unsupported Deployment")
            identities[metadata["name"]] = metadata["uid"]
            selectors[metadata["name"]] = ",".join(k + "=" + v for k, v in sorted(selector["matchLabels"].items()))
        self.k("scale", *("deployment/" + n for n in names), "--replicas=0", timeout=timeout())
        while True:
            current = deployments()
            if {d["metadata"]["name"]: d["metadata"]["uid"] for d in current} != identities:
                raise StackError("pipeline Deployment identity changed during shutdown; migrations not started")
            settled = all(d["spec"].get("replicas") == 0 and d.get("status", {}).get("observedGeneration", 0) >= d["metadata"]["generation"] for d in current)
            # Include terminating Pods: their old writers may still be draining.
            remaining_pods = sum(len(json.loads(self.k("get", "pods", "-l", selector, "-o", "json", timeout=timeout()).stdout)["items"]) for selector in selectors.values())
            if settled and remaining_pods == 0:
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise StackError("pipeline shutdown timed out; migrations not started and local state preserved")
            time.sleep(min(1, remaining))

    def up_local(self):
        self.docker()
        from local_ca import prepare
        retain_ca = prepare(self)
        selection = selected_images()
        selected = self.state / "selection.json"
        previous = json.loads(selected.read_text()) if selected.exists() else None
        pipeline_changed = check_selection(previous, selection)
        capabilities = json.loads(self.cmd([*self.docker_args, "run", "--rm", "--read-only", "--network", "none",
            "--entrypoint", "bun", PIPELINE, "-e",
            "import fs from 'node:fs';console.log(JSON.stringify({reader:fs.existsSync('/app/src/session-read-api/self-issued.ts'),consumer:fs.existsSync('/app/src/session-pipeline/consumer-service.ts')}));"]).stdout)
        if capabilities != {"reader": True, "consumer": True}:
            raise StackError("the Kind profile's pinned services image lacks the native reader/consumer; update the source pin before local-up can install a complete core")
        self.cluster()
        # Refuse a foreign/other-checkout fixture before spending time building.
        built_actors = build_actors(self, ACTORS) if CAST_BACKEND == "durable-actors" else None
        self.actor_build = built_actors
        if built_actors:
            load_actors(self, built_actors)
        self.stage("cni", self.cni)
        self.apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": NS}})
        from tls import create
        create(self, HOSTS, NS, preserve_ca=retain_ca)
        self.ca_sha = hashlib.sha256((self.state / "ca.crt").read_bytes()).hexdigest()
        self.leaf_sha = hashlib.sha256((self.state / "tls.crt").read_bytes()).hexdigest()
        self.apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "local-ca", "namespace": NS}, "data": {"ca.crt": (self.state / "ca.crt").read_text()}})
        path = self.state / "credentials.json"
        self.credentials = json.loads(path.read_text()) if path.exists() else {
            **{key: secrets.token_hex(32) for key in ("postgres", "hoop", "control_owner", "control_api_runtime", "locker", "bootstrap", "encryption", "cast", "castBootstrap", "internal", "introspection", "readerIssuer", "search_consumer_runtime", "bulls96_read_api", "bulls96_session_ingest")},
            "createdAt": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")}
        private_json(path, self.credentials)
        c = self.credentials
        for key in ("collector", "sessions_pipeline_runtime", "castKeyring", "castFiles", "castActors", "relaycast_owner", "relaycast_runtime",
                *("collector_" + name for name in TELEMETRY if name != "control")):
            c.setdefault(key, secrets.token_hex(32))
        private_json(path, c)
        self.stage("chart-dependencies", self.dependencies)
        from edge import install
        # Reconcile the edge on repeats too: the default leaf and its checksum
        # must follow TLS renewal rather than an old completed phase marker.
        install(self, "42.3.1", NS, wait_for_route=False)
        self.edge_ip = self.k("get", "service", "kind-edge-traefik", "-o", "jsonpath={.spec.clusterIP}", namespace="kind-edge").stdout
        self.stage("postgres", lambda: self.postgres_local(c))
        self.reload_leaf_consumer("postgres", "postgres-0", None, "/tls/tls.crt",
            lambda: self.sql("postgres", "SELECT pg_reload_conf();"))
        self.stage("databases", lambda: self.databases(c))
        self.stage("object-storage", lambda: self.storage(c))
        self.stage("pipeline-schema", lambda: self.pipeline_schema(c))
        self.prepare_pipeline_generation(pipeline_changed)
        self.mail()
        self.github_releases_egress()
        self.stage("control", lambda: self.control(c))
        self.sql("hoopdb", "ALTER ROLE hoop CREATEROLE;")
        try:
            self.stage("native-roles-" + PIPELINE, lambda: self.native_roles(c))
        finally:
            self.sql("hoopdb", "ALTER ROLE hoop NOCREATEROLE;")
        self.support_credentials(c)
        tenant = json.loads((self.state / "tenant.json").read_text())
        self.helm(self.values("serve", tenant))
        self.reload_leaf_consumer("collector", "deployment/telemetry-collector", "tls-proxy", "/var/run/secrets/telemetry-tls/tls.crt",
            lambda: self.k("exec", "deployment/telemetry-collector", "-c", "tls-proxy", "--", "nginx", "-s", "reload"))
        private_json(selected, selection)
        print("Dashboard: " + SITE)
        print("Local administrator: owner@kind.example (email link via local mailbox)")
        print("Local secrets (0600): " + str(path))
        self.login_link()

    def down_local(self):
        self.docker(require_space=False)
        clusters = self.cmd(["kind", "get", "clusters"]).stdout.splitlines()
        if self.name in clusters:
            self.owned()
        record = json.loads(self.marker.read_text()) if self.marker.exists() else None
        from local_ca import prepare, FILES
        retain_ca = prepare(self)
        if sys.platform == "darwin" and not retain_ca:
            certificates = managed_cas(self.state / "ca.crt")
            if any(certificate_present(ca) for ca in certificates) or host_aliases_present():
                self.cmd(["sudo", sys.executable, ROOT / "ci/agent-relay/kind/local_host_setup.py", "down"], sensitive=True)
        if self.name in clusters:
            self.cmd(["kind", "delete", "cluster", "--name", self.name], timeout=180)
        self.discard_dev_config(record)
        if retain_ca:
            for path in self.state.iterdir():
                if path.name not in FILES:
                    if path.is_dir() and not path.is_symlink():
                        shutil.rmtree(path)
                    else:
                        path.unlink()
            print("Removed local cluster, volumes and credentials; retained only CA certificate/key and existing hosts/trust.")
        else:
            shutil.rmtree(self.state)
            print("Removed this checkout's local cluster, volumes and credentials.")

    def discard_dev_config(self, record):
        path = ROOT / ".kind/dev/config.json"
        if not record or not path.is_file():
            return
        try:
            config = json.loads(path.read_text())
        except (OSError, ValueError):
            return
        expected = {"clusterUid": record.get("clusterUid"), "cluster": self.name, "context": "kind-" + self.name,
            "namespace": NS, "dockerHost": self.env["DOCKER_HOST"], "kubeconfig": str(self.kubeconfig.resolve())}
        if expected["clusterUid"] and all(config.get(key) == value for key, value in expected.items()):
            path.unlink()


def env(name, value):
    return {"name": name, "value": value}


def check_selection(previous, selected):
    if previous is None or previous == selected:
        return False
    if set(previous) != set(selected) or any(previous[k] != v for k, v in selected.items() if k != "pipeline"):
        raise StackError("local non-pipeline image selection changed; use make local-down before installing another generation")
    return True


def selected_images():
    result = {"pipeline": PIPELINE, "control": CONTROL, "webapp": WEBAPP, "postgres": POSTGRES, "minio": MINIO,
        "relaycast": CAST, "collector": reference(LOCAL_VALUES["telemetry-collector"]["image"]),
        "collectorProxy": reference(LOCAL_VALUES["telemetry-collector"]["tlsProxy"]["image"]), "relaycastBackend": CAST_BACKEND}
    if CAST_BACKEND == "durable-actors":
        result["relaycastActors"] = ACTORS["actorTag"]
    return result


def read_model_key(stream):
    if stream.isatty():
        raise StackError("pipe the model key on standard input; interactive entry would echo it")
    raw = stream.read(16387)
    key = raw.rstrip("\r\n")
    if len(raw) > 16386 or not key or len(key) > 16384 or any(c.isspace() or not c.isprintable() for c in key):
        raise StackError("standard input must contain one nonempty model key, at most 16384 printable characters")
    return key


def secret_env(name, secret, key):
    return {"name": name, "valueFrom": {"secretKeyRef": {"name": secret, "key": key}}}


def pgurl(role, credentials, ca, database="hoopdb"):
    # Relaycast accepts only sslmode in the URL; its CA is a separate chart env.
    return ("postgresql://" + role + ":" + credentials[role] + "@" + PGHOST + ":5432/" + database
            + "?sslmode=verify-full" + ("&sslrootcert=" + ca if ca else ""))


def locker_env():
    return [env("LOCKER_BUCKET", "locker"), env("LOCKER_ENDPOINT", "http://locker.agent-relay.svc.cluster.local:9000"),
        env("LOCKER_REGION", "us-east-1"), env("ALLOW_IN_CLUSTER_HTTP", "true"),
        secret_env("LOCKER_ACCESS_KEY_ID", "local-locker", "rootUser"), secret_env("LOCKER_SECRET_ACCESS_KEY", "local-locker", "rootPassword")]


def main():
    stack = LocalStack("core")
    if sys.argv[1:] not in (["up"], ["login"], ["down"], ["llm-key"], ["postgres-cast-proof"]):
        raise SystemExit("usage: local_stack.py up|login|down|llm-key|postgres-cast-proof")
    try:
        if sys.argv[1] == "up":
            stack.up_local()
            if sys.platform == "darwin":
                trusted = stack.cmd(["security", "verify-cert", "-c", stack.state / "tls.crt", "-p", "ssl", "-s", "relay.kind.agentrelay.com"], check=False)
                if trusted.returncode:
                    print("One-time macOS DNS/CA setup: run make local-trust from a terminal on this Mac.")
                    print("The cluster is ready; browser/Desktop acceptance waits for that sudo step.")
        elif sys.argv[1] == "login":
            stack.docker(require_space=False)
            stack.owned()
            stack.login_link(force=True)
        elif sys.argv[1] == "llm-key":
            stack.install_model_key()
        elif sys.argv[1] == "postgres-cast-proof":
            from local_cast_pg_proof import prove
            prove(stack)
        else:
            stack.down_local()
    except StackError as error:
        raise SystemExit(str(error)) from None


if __name__ == "__main__":
    main()
