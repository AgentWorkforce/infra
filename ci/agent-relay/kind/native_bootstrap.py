"""Native infrastructure/operator transport. Applying methods are never implicit.

This is still a partial adapter: the control, schema Job, consumer prepare Job,
runtime credential, final serve and add-on transports must exist before
NativeRecipe will dispatch it. Source tests must not target a live fixture.
"""
from dataclasses import dataclass, field
from contextlib import contextmanager
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tarfile
from urllib.parse import quote, urlsplit

import yaml

from native_inspect import NativeReadOnlyAdapter, sha
from native_recipe import NativeRecipeError, official_sql, require, selection


def openssl(arguments, fd_inputs=(), data=None):
    """Pass private material through inherited pipes, never argv or a file."""
    descriptors = []
    try:
        args = list(arguments)
        for index, raw in enumerate(fd_inputs):
            require(isinstance(raw, bytes) and 0 < len(raw) <= 8192, "invalid_openssl_pipe_input")
            read, write = os.pipe(); descriptors.append(read)
            try:
                require(os.write(write, raw) == len(raw), "openssl_pipe_write_incomplete")
            finally:
                os.close(write)
            args = [a.replace("@FD" + str(index), "/dev/fd/" + str(read)) for a in args]
        p = subprocess.run(["openssl", *args], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           pass_fds=descriptors, timeout=30)
        require(p.returncode == 0, "openssl_operation_failed_output_withheld")
        return p.stdout
    finally:
        for descriptor in descriptors:
            os.close(descriptor)


def require_hostname_verifier():
    p = subprocess.run(["openssl", "verify", "-help"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    require(b"-verify_hostname" in p.stdout + p.stderr, "openssl_hostname_verification_required")


def exact_pem(raw, labels, code):
    """Do not let OpenSSL's permissive first-object parser hide extra material."""
    require(isinstance(raw, bytes) and 0 < len(raw) <= 8192, code)
    matches = [label for label in labels if re.fullmatch(
        rb"-----BEGIN " + label.encode() + rb"-----\r?\n(?:[A-Za-z0-9+/=]+\r?\n)+-----END " +
        label.encode() + rb"-----(?:\r?\n)?", raw)]
    require(len(matches) == 1, code)
    encoded = b"".join(raw.splitlines()[1:-1])
    try:
        der = base64.b64decode(encoded, validate=True)
    except ValueError:
        raise NativeRecipeError(code) from None
    require(len(der) >= 2 and der[0] == 0x30, code)
    count = der[1] & 0x7f if der[1] & 0x80 else 0
    require(not (der[1] & 0x80) or (0 < count <= 4 and len(der) > 2 + count and der[2] != 0), code)
    length = int.from_bytes(der[2:2 + count], "big") if count else der[1]
    require(2 + count + length == len(der) and (not count or length >= 128), code)
    if matches == ["CERTIFICATE"]:
        # x509 accepts a first ASN.1 object too. Bind the entire decoded PEM,
        # not just that first object, before publishing the original bytes.
        require(openssl(["x509", "-outform", "DER"], data=raw) == der, code)


@dataclass(frozen=True)
class TlsMaterial:
    ca: bytes = field(repr=False)
    certificate: bytes = field(repr=False)
    private_key: bytes = field(repr=False)

    @property
    def ca_sha256(self):
        return hashlib.sha256(self.ca).hexdigest()

    def verify(self, hosts):
        exact_pem(self.ca, ("CERTIFICATE",), "public_ca_must_be_exactly_one_certificate")
        exact_pem(self.certificate, ("CERTIFICATE",), "tls_leaf_must_be_exactly_one_certificate")
        exact_pem(self.private_key, ("PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY"),
                  "tls_key_must_be_exactly_one_private_key")
        require_hostname_verifier()
        ca_extensions = openssl(["x509", "-noout", "-ext", "basicConstraints,keyUsage"], data=self.ca)
        require(b"CA:TRUE" in ca_extensions and b"Certificate Sign" in ca_extensions,
                "public_ca_constraints_required")
        openssl(["x509", "-checkend", "86400", "-noout"], data=self.ca)
        openssl(["verify", "-x509_strict", "-check_ss_sig", "-CAfile", "@FD0", "@FD1"], (self.ca, self.ca))
        leaf_extensions = openssl(["x509", "-noout", "-ext", "basicConstraints,extendedKeyUsage"], data=self.certificate)
        require(b"CA:FALSE" in leaf_extensions and b"TLS Web Server Authentication" in leaf_extensions,
                "tls_leaf_server_constraints_required")
        public = openssl(["x509", "-pubkey", "-noout"], data=self.certificate)
        paired = openssl(["pkey", "-pubout"], data=self.private_key)
        require(public == paired, "tls_leaf_key_mismatch")
        openssl(["x509", "-checkend", "86400", "-noout"], data=self.certificate)
        for host in hosts:
            openssl(["verify", "-x509_strict", "-CAfile", "@FD0", "-verify_hostname", host, "@FD1"],
                    (self.ca, self.certificate))


def fresh_tls_material(hosts):
    """Prepare a one-shot local TEST CA/leaf in memory before cluster mutation.

    The CA signing key is not returned, persisted or installed in a Pod. An
    expired leaf requires a separately reviewed renewal, never silent repeat-up
    rotation. Installing the public CA in an OS trust store is an owner action.
    """
    require(hosts and all(re.fullmatch(r"[a-z0-9.-]+", h) for h in hosts), "invalid_test_tls_host")
    require_hostname_verifier()
    ca_key = openssl(["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"])
    ca_config = ("[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=ext\n[dn]\nCN=Agent Relay kind local CA\n"
                 "[ext]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n"
                 "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n").encode()
    ca = openssl(["req", "-new", "-x509", "-key", "@FD0", "-config", "@FD1", "-days", "365"], (ca_key, ca_config))
    leaf_key = openssl(["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"])
    san = ",".join("DNS:" + h for h in hosts)
    config = ("[req]\ndistinguished_name=dn\nprompt=no\nreq_extensions=req_ext\n[dn]\nCN=" + hosts[0] + "\n[req_ext]\nsubjectAltName=" + san + "\n[ext]\n"
              "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
              "extendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\nsubjectAltName=" + san + "\n").encode()
    csr = openssl(["req", "-new", "-key", "@FD0", "-config", "@FD1"], (leaf_key, config))
    cert = openssl(["x509", "-req", "-CA", "@FD0", "-CAkey", "@FD1", "-extfile", "@FD2", "-extensions", "ext",
                    "-set_serial", "0x" + secrets.token_hex(16), "-days", "30"], (ca, ca_key, config), csr)
    result = TlsMaterial(ca, cert, leaf_key); result.verify(hosts)
    return result


def scram(password):
    require(re.fullmatch(r"[A-Za-z0-9_-]{64}", password), "invalid_generated_password")
    salt = secrets.token_bytes(16)
    salted = hashlib.pbkdf2_hmac("sha256", password.encode("ascii"), salt, 4096)
    stored = hashlib.sha256(hmac.new(salted, b"Client Key", hashlib.sha256).digest()).digest()
    server = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
    b64 = lambda x: base64.b64encode(x).decode()
    return "SCRAM-SHA-256$4096:" + b64(salt) + "$" + b64(stored) + ":" + b64(server)


class NativeBootstrapAdapter(NativeReadOnlyAdapter):
    ADMIN_SECRET = "kind-native-postgres-admin"
    SERVER_TLS_SECRET = "kind-native-server-tls"
    HBA_CONFIG = "kind-native-postgres-hba"
    MINIO_CHART_SHA256 = "25fa2740480d1ebc9e64340854a6c42d3a7bc39c2a77378da91b21f144faa9af"
    STORAGE_RENDERER_SHA256 = "c35d2c5b6b13c3e5effc3fdb8f850f0aad688ad090830fe95bd418ac60b43330"
    STORAGE_PLUGIN_SHA256 = "fd4e09ed1757e734d523b0066ec4bd751774f52eb40fbc3b416b3dcc05f151a9"
    HBA = "local all all trust\nhostnossl all all 0.0.0.0/0 reject\nhostnossl all all ::/0 reject\nhostssl all all 0.0.0.0/0 scram-sha-256\nhostssl all all ::/0 scram-sha-256\n"

    def __init__(self, stack, inputs, tls_material=None):
        super().__init__(stack, inputs)
        self._docker_transport = self._local_docker_transport()
        require(tls_material is None or isinstance(tls_material, TlsMaterial), "typed_tls_material_required")
        self.tls_material = tls_material
        self._verified = None; self._inspected = None; self._rendered = False
        self._pg_uid = None; self._owner_oid = None; self._completed = set()
        self._selected_sha = None; self._infrastructure_started = False
        self._created_cluster = None

    def _local_docker_transport(self):
        host = self.stack.env.get("DOCKER_HOST")
        require(isinstance(host, str), "fresh_local_docker_required")
        parsed = urlsplit(host)
        require(parsed.scheme == "unix" and not parsed.netloc and parsed.path.startswith("/") and
                len(parsed.path) > 1 and not parsed.query and not parsed.fragment and
                not any(ord(c) < 32 for c in host), "fresh_local_docker_required")
        # Both Docker CLI and Kind inherit this explicit endpoint. Context or
        # command-line host flags would defeat DOCKER_HOST binding.
        require(not any(self.stack.env.get(k) for k in ("DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH")),
                "native_docker_endpoint_override_refused")
        args = self.stack.docker_args
        require(isinstance(args, list) and len(args) in (1, 3) and isinstance(args[0], str) and
                Path(args[0]).name == "docker" and
                (len(args) == 1 or (args[1] == "--config" and isinstance(args[2], (str, Path)) and str(args[2]))),
                "native_docker_command_endpoint_override_refused")
        return host, tuple(str(x) for x in args)

    def _require_local_transport(self):
        require(self._local_docker_transport() == self._docker_transport, "native_docker_endpoint_changed_since_admission")

    def _transport_call(self, method, *args, **kwargs):
        self._require_local_transport()
        return getattr(self.stack, method)(*args, **kwargs)

    def _get(self, resource, namespace=True):
        self._require_local_transport()
        return super()._get(resource, namespace=namespace)

    def _docker_json(self, arguments, data=None):
        self._require_local_transport()
        return super()._docker_json(arguments, data)

    def _bind_selection(self, selected):
        self._require_local_transport()
        validated = selection(selected)
        value = hashlib.sha256(json.dumps(validated, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        require(self._selected_sha in (None, value), "native_selection_changed_since_preflight")
        self._selected_sha = value
        return validated

    def inspect(self, selected):
        self._bind_selection(selected)
        result = super().inspect(selected)
        self._inspected = result
        if result["mode"] == "repeat":
            self._pg_uid = self._get("statefulset/postgres")["metadata"]["uid"]
        return result

    def verify_artifact(self, selected):
        self._bind_selection(selected)
        result = super().verify_artifact(selected)
        self._verified = result
        return result

    def render(self, selected):
        self._bind_selection(selected)
        result = super().render(selected); self._rendered = True
        return result

    def _preflight(self, selected, fresh=False):
        self._bind_selection(selected)
        require(self._verified and self._verified["sourceRevision"] == selected["sourceRevision"] and
                self._verified["manifestDigest"] == selected["manifestDigest"] and
                self._verified["generation"] == selected["generation"] and self._rendered and self._inspected,
                "observed_native_preflight_required")
        if fresh:
            require(self._inspected["mode"] == "fresh", "fresh_operator_phase_refuses_retained_target")

    def _create(self, kind, name, body):
        self._require_local_transport()
        old = self._transport_call("k", "get", kind.lower(), name, "--ignore-not-found=true", "-o", "name", sensitive=True).stdout.strip()
        require(not old, "prior_native_resource_requires_review:" + kind.lower())
        obj = {"apiVersion": "v1", "kind": kind, "metadata": {"name": name, "namespace": "agent-relay"}, **body}
        result = json.loads(self._transport_call("k", "create", "-f", "-", "-o", "json", data=json.dumps(obj), sensitive=True).stdout)
        require(result.get("metadata", {}).get("uid"), "native_resource_creation_unconfirmed")
        return result

    def _secret(self, name, values, secret_type="Opaque"):
        require(all(isinstance(v, str) for v in values.values()), "string_secret_values_required")
        return self._create("Secret", name, {"type": secret_type, "immutable": True,
                            "data": {k: base64.b64encode(v.encode()).decode() for k, v in values.items()}})

    def _source(self, selected, name):
        source = json.loads(Path(self.inputs["sourceManifest"]).read_text())
        require(sha(self.inputs["sourceManifest"]) == self.inputs["sourceManifestSha256"] and
                source["sourceRevision"] == selected["sourceRevision"] and
                sha(self.inputs["sourceArchive"]) == source["archiveSha256"], "qualified_source_archive_changed")
        require(name in source["files"] and not name.startswith("/") and ".." not in Path(name).parts, "unqualified_sql_path")
        with tarfile.open(self.inputs["sourceArchive"]) as archive:
            member = archive.getmember(name); require(member.isfile(), "official_sql_must_be_file")
            raw = archive.extractfile(member).read()
        require(hashlib.sha256(raw).hexdigest() == source["files"][name]["sha256"], "official_source_bytes_changed")
        return raw

    def _official(self, selected, name):
        from native_recipe import BOOTSTRAP
        files = {n: self._source(selected, "supabase/bootstrap/" + n) for n in BOOTSTRAP}
        return official_sql(files, selected, name)

    def _psql(self, selected, database, text, variables=(), read_only=False):
        self._require_local_transport()
        require(database in {"postgres", "hoopdb", "relaycontrol", "relayfile", "relaycast"}, "unbound_operator_database")
        require(self._pg_uid, "owned_postgres_instance_required")
        actual = self._get("statefulset/postgres")
        pod = self._get("pod/postgres-0")
        require(actual["metadata"]["uid"] == self._pg_uid and
                any(o.get("uid") == self._pg_uid and o.get("kind") == "StatefulSet" for o in pod["metadata"].get("ownerReferences", [])),
                "operator_postgres_instance_changed")
        args = ["exec", "-i", "postgres-0", "-c", "postgres", "--", "psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
                "--host=/var/run/postgresql", "--port=5432", "-U", "postgres", "-d", database]
        for value in variables:
            require(re.fullmatch(r"(?:runtime_role|runtime_login|migration_owner)=[A-Za-z0-9_]+", value), "unbound_operator_variable")
            args += ["-v", value]
        # psql sends statements separately; log settings precede any verifier
        # assignment statement. Secret-bearing SQL is captured and never echoed.
        if read_only:
            text = "BEGIN READ ONLY;\nSET LOCAL statement_timeout='30s';\n" + text + "\nROLLBACK;\n"
        return self._transport_call("k", *args, data=text, sensitive=True).stdout

    def _fresh_absence(self):
        self._require_local_transport()
        require(not any(p.exists() or p.is_symlink() for p in
                        (self.stack.marker, self.stack.state / "ready.json", self.stack.kubeconfig)),
                "fresh_cluster_local_state_appeared")
        clusters = self._transport_call("cmd", ["kind", "get", "clusters"], timeout=30).stdout.splitlines()
        require(self.stack.name not in clusters, "fresh_cluster_name_appeared")

    @staticmethod
    def _exclusive_json(path, value):
        try:
            stream = open(path, "x", encoding="utf8")
        except FileExistsError:
            raise NativeRecipeError("fresh_creation_local_claim_or_receipt_exists") from None
        with stream:
            os.chmod(path, 0o600)
            json.dump(value, stream); stream.write("\n"); stream.flush(); os.fsync(stream.fileno())

    def _fresh_cluster(self):
        """Create only; never reuse/adopt a cluster from a stale fresh inspection.

        Kind arbitrates the cluster name. A creation nonce additionally binds
        the returned kubeconfig/UID to this attempt before any resource apply.
        Failed/partial attempts and their claim remain for explicit recovery.
        """
        from stack import NODE
        self._fresh_absence()
        nonce = secrets.token_hex(16)
        claim = self.stack.state / "native-fresh-creation.json"
        self._exclusive_json(claim, {"name": self.stack.name, "nonce": nonce})
        self._fresh_absence()  # recheck immediately before create, after exclusive claim
        candidate = self.stack.state / ("native-created-" + nonce + ".kubeconfig")
        config = {"kind": "Cluster", "apiVersion": "kind.x-k8s.io/v1alpha4",
                  "networking": {"disableDefaultCNI": True, "podSubnet": "192.168.0.0/16"},
                  "nodes": [{"role": "control-plane", "labels": {"agentrelay-kind-owner": "infra",
                            "agentrelay-native-creation": nonce}, "extraPortMappings": [
                            {"containerPort": 30080, "hostPort": 8080, "listenAddress": "127.0.0.1"},
                            {"containerPort": 30443, "hostPort": 8443, "listenAddress": "127.0.0.1"}]}]}
        self._transport_call("cmd", ["kind", "create", "cluster", "--name", self.stack.name, "--image", NODE,
                        "--config", "-", "--kubeconfig", candidate], data=yaml.safe_dump(config), timeout=300, sensitive=True)
        candidate.chmod(0o600)
        uid = self._transport_call("cluster_uid", candidate)
        nodes = json.loads(self._transport_call("cmd", ["kubectl", "--kubeconfig", candidate,
                           "--context", "kind-" + self.stack.name, "get", "nodes", "-o", "json"], sensitive=True).stdout)["items"]
        require(len(nodes) == 1 and nodes[0]["metadata"].get("labels", {}).get("agentrelay-native-creation") == nonce and
                nodes[0]["metadata"].get("labels", {}).get("agentrelay-kind-owner") == "infra",
                "fresh_cluster_creation_binding_mismatch")
        require(not any(p.exists() or p.is_symlink() for p in
                        (self.stack.marker, self.stack.state / "ready.json", self.stack.kubeconfig)),
                "fresh_cluster_state_raced_creation")
        docker_host = self.stack.env.get("DOCKER_HOST")
        require(isinstance(docker_host, str) and docker_host.startswith("unix://"), "fresh_local_docker_required")
        record = {"version": 1, "name": self.stack.name, "nodeImage": NODE, "profile": self.stack.profile,
                  "dockerHost": docker_host, "clusterUid": uid}
        self._exclusive_json(self.stack.marker, record)
        with open(self.stack.kubeconfig, "xb") as stream:
            os.chmod(self.stack.kubeconfig, 0o600); stream.write(candidate.read_bytes())
        self._created_cluster = {"uid": uid, "nonce": nonce, "record": record}
        self._require_created_cluster()

    def _require_created_cluster(self):
        self._require_local_transport()
        binding = self._created_cluster
        require(binding and json.loads(self.stack.marker.read_text()) == binding["record"] and
                self._transport_call("cluster_uid", self.stack.kubeconfig) == binding["uid"], "fresh_cluster_uid_changed")
        nodes = self._get("nodes", namespace=False)["items"]
        require(len(nodes) == 1 and nodes[0]["metadata"].get("labels", {}).get("agentrelay-native-creation") == binding["nonce"],
                "fresh_cluster_creation_binding_changed")

    def prepare_infrastructure(self, selected, facts):
        self._preflight(selected, fresh=True)
        require(not self._infrastructure_started, "fresh_infrastructure_attempt_requires_review_not_retry")
        require(facts == self._inspected and self.tls_material, "fresh_tls_material_and_observed_target_required")
        require(selected["lockerClaim"] == "locker", "fresh_pinned_storage_transform_requires_locker_claim")
        require(not {r["name"] for r in selected["secretRefs"].values()} &
                {self.ADMIN_SECRET, self.SERVER_TLS_SECRET, "kind-tls"} and selected["postgresCa"]["configMap"] != self.HBA_CONFIG,
                "reserved_infrastructure_reference_collision")
        from stack import POSTGRES, PROBE
        hosts = [selected["postgres"]["host"], "relay.kind.agentrelay.com", "cast.kind.agentrelay.com", "history.kind.agentrelay.com", "files.kind.agentrelay.com"]
        self.tls_material.verify(hosts)
        require(self.tls_material.ca_sha256 == selected["postgresCa"]["sha256"], "fresh_tls_ca_not_bound_to_selection")
        self._minio_source()
        self._fresh_absence()
        self._infrastructure_started = True
        self._require_local_transport(); self._transport_call("pull", POSTGRES)
        self._require_local_transport(); self._transport_call("pull", PROBE)
        self._fresh_cluster()
        self._require_created_cluster(); self._transport_call("cni", )
        self._require_created_cluster()
        self._transport_call("apply", {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "agent-relay"}})
        for d in self._verified_render_docs:
            if d["kind"] in {"NetworkPolicy", "ServiceAccount"}:
                self._transport_call("apply", d, chart=True)
        self._transport_call("load", POSTGRES); self._transport_call("load", PROBE)
        # No legacy credentials.json, password argv, last-applied Secret
        # annotation or source-controlled credential file is used.
        admin = secrets.token_urlsafe(48)
        self._secret(self.ADMIN_SECRET, {"password": admin}); del admin
        self._secret(self.SERVER_TLS_SECRET, {"tls.crt": self.tls_material.certificate.decode(), "tls.key": self.tls_material.private_key.decode()}, "kubernetes.io/tls")
        self._create("ConfigMap", selected["postgresCa"]["configMap"], {"immutable": True, "data": {"ca.crt": self.tls_material.ca.decode()}})
        self._create("ConfigMap", self.HBA_CONFIG, {"immutable": True, "data": {"pg_hba.conf": self.HBA}})
        # The ingress uses the leaf, never the CA signing key.
        self._secret("kind-tls", {"tls.crt": self.tls_material.certificate.decode(), "tls.key": self.tls_material.private_key.decode()}, "kubernetes.io/tls")
        labels = {"app": "kind-postgres"}
        self._transport_call("apply", {"apiVersion": "v1", "kind": "Service", "metadata": {"name": "postgres", "namespace": "agent-relay"},
                          "spec": {"selector": labels, "ports": [{"port": 5432}]}})
        pod = {"securityContext": {"fsGroup": 999}, "containers": [{"name": "postgres", "image": POSTGRES,
               "args": ["-c", "ssl=on", "-c", "ssl_min_protocol_version=TLSv1.2", "-c", "ssl_cert_file=/var/run/native-postgres-tls/tls.crt", "-c", "ssl_key_file=/var/run/native-postgres-tls/tls.key", "-c", "hba_file=/var/run/native-postgres-config/pg_hba.conf"],
               "env": [{"name": "POSTGRES_PASSWORD", "valueFrom": {"secretKeyRef": {"name": self.ADMIN_SECRET, "key": "password"}}},
                       {"name": "PGDATA", "value": "/var/lib/postgresql/data/pgdata"}],
               "ports": [{"containerPort": 5432}], "volumeMounts": [{"name": "data", "mountPath": "/var/lib/postgresql/data"},
                       {"name": "server-tls", "mountPath": "/var/run/native-postgres-tls", "readOnly": True},
                       {"name": "hba", "mountPath": "/var/run/native-postgres-config", "readOnly": True}],
               "readinessProbe": {"exec": {"command": ["pg_isready", "-U", "postgres"]}, "periodSeconds": 3}}],
               "volumes": [{"name": "server-tls", "secret": {"secretName": self.SERVER_TLS_SECRET, "defaultMode": 0o440}},
                           {"name": "hba", "configMap": {"name": self.HBA_CONFIG}}]}
        self._transport_call("apply", {"apiVersion": "apps/v1", "kind": "StatefulSet", "metadata": {"name": "postgres", "namespace": "agent-relay"},
                          "spec": {"serviceName": "postgres", "replicas": 1, "selector": {"matchLabels": labels},
                                   "template": {"metadata": {"labels": labels}, "spec": pod},
                                   "volumeClaimTemplates": [{"metadata": {"name": "data"}, "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "4Gi"}}}}]}})
        self._transport_call("k", "rollout", "status", "statefulset/postgres", "--timeout=180s", sensitive=True, timeout=210)
        self._pg_uid = self._get("statefulset/postgres")["metadata"]["uid"]
        # Fixed names only, no owner takeover and no IF NOT EXISTS adoption.
        guard = """DO $$ BEGIN
IF current_user<>'postgres' OR session_user<>current_user OR current_setting('role')<>'none'
 OR EXISTS(SELECT 1 FROM pg_database WHERE NOT datistemplate AND datname<>'postgres')
 OR EXISTS(SELECT 1 FROM pg_roles WHERE rolname!~'^pg_' AND rolname<>'postgres')
 THEN RAISE EXCEPTION 'fresh native PostgreSQL target differs'; END IF; END $$;
"""
        roles = ["hoop", "control_owner", "control_api_runtime", "relayfile", "cast_owner", "cast_runtime"]
        create = "\n".join("CREATE ROLE " + r + " NOLOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION;" for r in roles)
        databases = "\n".join("CREATE DATABASE " + d + " OWNER " + o + ";" for d, o in [("hoopdb", "hoop"), ("relaycontrol", "control_owner"), ("relayfile", "relayfile"), ("relaycast", "cast_owner")])
        self._psql(selected, "postgres", guard + create + "\n" + databases)
        self._owner_oid = self._owner_snapshot(selected)["oid"]
        self._psql(selected, "hoopdb", "CREATE EXTENSION pg_trgm; CREATE EXTENSION btree_gin; CREATE EXTENSION vector;")
        self._prepare_locker(selected)
        self._completed.add("infrastructure")
        return {"ok": True, "clusterUid": self._get("namespace/kube-system", namespace=False)["metadata"]["uid"],
                "postgresPvcUid": self._get("persistentvolumeclaim/data-postgres-0")["metadata"]["uid"],
                "objectStoragePvcUid": self._get("persistentvolumeclaim/" + selected["lockerClaim"])["metadata"]["uid"],
                "caSha256": selected["postgresCa"]["sha256"]}

    def _minio_source(self):
        root = Path(__file__).resolve().parents[3]
        chart = root / "charts/sessions-pipeline/charts/minio-5.4.0.tgz"
        renderer = root / "ci/agent-relay/kind/storage-name-renderer/postrender.py"
        lock = yaml.safe_load((root / "charts/sessions-pipeline/Chart.lock").read_text())
        require(any(d["name"] == "minio" and d["version"] == "5.4.0" for d in lock["dependencies"]) and chart.is_file() and
                sha(chart) == self.MINIO_CHART_SHA256 and sha(renderer) == self.STORAGE_RENDERER_SHA256 and
                sha(renderer.parent / "plugin.yaml") == self.STORAGE_PLUGIN_SHA256, "pinned_minio_dependency_required")
        return chart, renderer

    def _prepare_locker(self, selected):
        require(selected["lockerClaim"] == "locker", "fresh_pinned_storage_transform_requires_locker_claim")
        # Reuse the reviewed same-release transform: only the Deployment name
        # becomes session-object-storage; claim, service DNS and selectors stay.
        chart, renderer = self._minio_source()
        ref = selected["secretRefs"]["locker"]
        password = secrets.token_urlsafe(48)
        self._secret(ref["name"], {"rootUser": "locker", ref["key"]: password}); del password
        values = {"mode": "standalone", "fullnameOverride": "locker", "existingSecret": ref["name"],
                  "persistence": {"enabled": True, "size": "2Gi"}, "resources": {"requests": {"memory": "256Mi"}},
                  "buckets": [{"name": selected["lockerBucket"], "policy": "none", "purge": False}]}
        old = self._transport_call("k", "get", "persistentvolumeclaim", "locker", "--ignore-not-found=true", "-o", "name", sensitive=True).stdout.strip()
        require(not old, "prior_storage_claim_refuses_fresh_creation")
        with self._storage_renderer(renderer) as command:
            self._transport_call("cmd", ["helm", "install", "kind-locker", str(chart), "-n", "agent-relay", "-f", "-",
                            "--post-renderer", command, "--wait", "--wait-for-jobs", "--timeout", "5m"],
                           data=json.dumps(values), sensitive=True, timeout=330)

    @contextmanager
    def _storage_renderer(self, script):
        """Use the existing reviewed Helm3 executable / Helm4 plugin protocol."""
        version = self._transport_call("cmd", ["helm", "version", "--template", "{{.Version}}"], sensitive=True).stdout.strip()
        previous = self.stack.env.get("HELM_PLUGINS")
        try:
            if version.startswith("v4."):
                plugins = self.stack.state / "helm-native-plugins"
                require(not plugins.is_symlink(), "native_plugin_directory_must_not_redirect")
                plugins.mkdir(mode=0o700, exist_ok=True)
                selected = plugins / "kind-storage-names"
                require(not (selected.exists() or selected.is_symlink()) or selected.resolve() == script.parent.resolve(),
                        "native_plugin_path_belongs_to_another_source")
                if not selected.exists() and not selected.is_symlink(): selected.symlink_to(script.parent.resolve(), target_is_directory=True)
                self.stack.env["HELM_PLUGINS"] = str(plugins)
                yield "kind-storage-names"
            elif version.startswith("v3."):
                yield str(script)
            else:
                raise NativeRecipeError("unsupported_native_helm_postrenderer_protocol")
        finally:
            if previous is None: self.stack.env.pop("HELM_PLUGINS", None)
            else: self.stack.env["HELM_PLUGINS"] = previous

    def prepare_owner(self, selected):
        self._preflight(selected, fresh=True)
        require("infrastructure" in self._completed, "fresh_infrastructure_required")
        owner = self._owner_snapshot(selected)
        require(owner.get("clean") is True and owner["oid"] == self._owner_oid, "fresh_owner_role_not_unclaimed")
        password = secrets.token_urlsafe(48); verifier = scram(password)
        ref = selected["secretRefs"]["owner"]
        def url(path):
            return "postgresql://hoop:" + password + "@" + selected["postgres"]["host"] + ":5432/hoopdb?sslmode=verify-full&sslrootcert=" + quote(path, safe="")
        self._secret(ref["name"], {ref["key"]: json.dumps({"hoopdb_url": url("/etc/native-consumer-postgres/ca.crt")}),
                                  "migration-url": url("/var/run/native-pg-ca/ca.crt")})
        del password
        # The official local compatibility shim creates its own fixed roles.
        self._psql(selected, "hoopdb", self._source(selected, "supabase/tests/supabase_shim.sql").decode())
        for name in ("session_directory_search_worker.sql", "session_token_verifier.sql", "session_ingest_roles.sql", "session_read_api_roles.sql"):
            self._psql(selected, "hoopdb", self._official(selected, name))
        oid = int(self._owner_oid)
        text = """BEGIN;
SET LOCAL log_statement='none'; SET LOCAL log_min_error_statement='panic';
SET LOCAL lock_timeout='5s'; SET LOCAL statement_timeout='30s'; LOCK TABLE pg_catalog.pg_authid IN SHARE ROW EXCLUSIVE MODE;
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_authid WHERE oid=""" + str(oid) + """ AND rolname='hoop' AND NOT(rolcanlogin OR rolsuper OR rolcreaterole OR rolbypassrls OR rolcreatedb OR rolreplication OR rolinherit) AND rolpassword IS NULL AND rolvaliduntil IS NULL)
 THEN RAISE EXCEPTION 'fresh owner claim changed'; END IF; END $$;
ALTER ROLE hoop LOGIN CREATEROLE PASSWORD '""" + verifier + """';
SET LOCAL ROLE hoop; SET LOCAL createrole_self_grant='';
CREATE SCHEMA sessions; CREATE SCHEMA search_index;
""" + self._official(selected, "session_consumer_roles.sql") + "\nRESET ROLE; COMMIT;"
        self._psql(selected, "hoopdb", text); del verifier
        self._psql(selected, "hoopdb", self._official(selected, "hoopdb_runtime_role.sql"), ["runtime_role=" + selected["roles"]["runtime"], "runtime_login=true"])
        self._psql(selected, "hoopdb", self._official(selected, "hoopdb_function_default_revoke.sql"), ["migration_owner=hoop"])
        self._completed.add("owner_prepared")
        return {"ok": True, "ownerOid": oid}

    def _owner_snapshot(self, selected):
        raw = self._psql(selected, "hoopdb", "SELECT json_build_object('oid',r.oid,'clean',NOT(r.rolcanlogin OR r.rolsuper OR r.rolcreaterole OR r.rolinherit OR r.rolbypassrls OR r.rolcreatedb OR r.rolreplication) AND r.rolpassword IS NULL AND r.rolvaliduntil IS NULL AND NOT EXISTS(SELECT 1 FROM pg_db_role_setting WHERE setrole=r.oid) AND NOT EXISTS(SELECT 1 FROM pg_auth_members WHERE roleid=r.oid OR member=r.oid)) FROM pg_authid r WHERE rolname='hoop' AND r.oid=(SELECT datdba FROM pg_database WHERE datname='hoopdb');", read_only=True)
        result = json.loads(raw)
        require(type(result.get("oid")) is int and result["oid"] > 0 and type(result.get("clean")) is bool, "fresh_owner_snapshot_unreadable")
        return result

    def finalize_owner(self, selected):
        self._preflight(selected, fresh=True)
        require("infrastructure" in self._completed and self._owner_oid is not None, "fresh_operator_instance_required")
        # Idempotent only for this fresh, directly-owned role; no authority to
        # change an arbitrary pre-existing deployment's migration owner.
        self._psql(selected, "hoopdb", "BEGIN; DO $$ BEGIN IF current_user<>'postgres' OR session_user<>current_user OR current_setting('role')<>'none' OR NOT EXISTS(SELECT 1 FROM pg_database WHERE datname='hoopdb' AND datdba=" + str(int(self._owner_oid)) + " AND datdba='hoop'::regrole) THEN RAISE EXCEPTION 'wrong native operator target'; END IF; END $$; ALTER ROLE hoop NOCREATEROLE; COMMIT;")
        self._completed.add("owner_finalized")
        return {"ok": True, "ownerNoCreateRole": True}

    def verify_owner_final(self, selected):
        self._preflight(selected)
        raw = self._psql(selected, "hoopdb", "SELECT json_build_object('ownerOid',r.oid,'ownerNoCreateRole',r.rolcanlogin AND NOT(r.rolsuper OR r.rolcreaterole OR r.rolbypassrls OR r.rolcreatedb OR r.rolreplication OR r.rolinherit)) FROM pg_roles r WHERE rolname='hoop' AND r.oid=(SELECT datdba FROM pg_database WHERE datname='hoopdb');", read_only=True)
        result = json.loads(raw); require(result.get("ownerNoCreateRole") is True, "owner_privilege_not_finalized")
        if self._owner_oid is not None: require(result["ownerOid"] == self._owner_oid, "native_owner_oid_changed")
        return {"ok": True, **result}

    def verify_infrastructure(self, selected, facts):
        self._preflight(selected)
        require(facts == self._inspected and facts["mode"] == "repeat", "qualified_repeat_target_required")
        self.qualify_references(selected)
        hba = self._get("configmap/" + self.HBA_CONFIG)
        pg = self._get("statefulset/postgres")
        args = pg["spec"]["template"]["spec"]["containers"][0].get("args", [])
        require(hba.get("immutable") is True and hba.get("data") == {"pg_hba.conf": self.HBA} and
                "hba_file=/var/run/native-postgres-config/pg_hba.conf" in args and "ssl_min_protocol_version=TLSv1.2" in args,
                "native_tls_only_hba_binding_changed")
        return {"ok": True, "clusterUid": facts["clusterUid"], "caSha256": selected["postgresCa"]["sha256"]}

    def verify_claimed_roles(self, selected):
        self._preflight(selected)
        require(self._inspected["mode"] == "repeat", "claimed_repeat_verification_only")
        self.verify_owner_final(selected)
        for name in ("session_ingest_role_verify.sql", "session_read_api_role_verify.sql"):
            self._psql(selected, "hoopdb", self._official(selected, name), read_only=True)
        self._psql(selected, "hoopdb", "SET LOCAL ROLE hoop;\n" + self._official(selected, "session_consumer_role_verify.sql"), read_only=True)
        # No installer/bootstrap call, role reset, credential mutation or
        # protected-catalog permission fallback is allowed in repeat-up.
        return {"ok": True}
