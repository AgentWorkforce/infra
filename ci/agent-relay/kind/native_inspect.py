"""Concrete local artifact/render and read-only Kubernetes native preflight.

This adapter intentionally does not implement applying operations. NativeRecipe
therefore refuses it as an incomplete deployment adapter. Its three implemented
operations execute the real OCI, Docker, Helm and Kubernetes reads below.
"""
import base64
import hashlib
import hmac
import json
from pathlib import Path
import re
import tarfile
from urllib.parse import parse_qs, unquote, urlsplit

import yaml

from native_recipe import BOOTSTRAP, NativeRecipeError, merge_values, require

INPUT_FIELDS = {"pipelineReceipt", "sourceManifest", "sourceManifestSha256", "sourceArchive", "pipelineArchive",
                "controlReceipt", "controlArchive", "controlDistManifest", "controlMigrationManifest",
                "controlMigrationManifestSha256", "controlSourceManifest"}
OPTIONAL_INPUT_FIELDS = {"bindingReceipt", "bindingReceiptSha256", "pipelineBuildMetadata", "pipelineBuildMetadataSha256",
                         "webappPacket", "webappPacketSha256", "webappArchive", "webappBuildMetadata"}


def sha(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def document(path, expected_sha):
    require(sha(path) == expected_sha, "local_evidence_bytes_changed")
    return json.loads(Path(path).read_text())


def file_sha(info):
    value = info if isinstance(info, str) else info.get("sha256") if isinstance(info, dict) else None
    require(isinstance(value, str) and re.fullmatch(r"[a-f0-9]{64}", value), "source_file_digest_required")
    return value


def same_local_reference(a, b):
    """Only Docker's documented local repository spelling is interchangeable."""
    def known(value):
        if isinstance(value, str) and value.startswith("docker.io/agent-relay-kind/"):
            return value[len("docker.io/"):]
        return value
    return known(a) == known(b)


def pipeline_coordinates(paths, selected):
    """Read the two qualified receipt schemas without rewriting either proof.

    Newer public receipts describe sourceState as text, not a clean-worktree
    attestation. Source admission remains the explicit acceptedSource binding;
    this adapter verifies the actual source/archive/image bytes independently.
    """
    receipt = document(paths["pipelineReceipt"], selected["artifactReceiptSha256"])
    if "source" in receipt:
        require(receipt["source"].get("revision") == selected["sourceRevision"] and
                receipt["source"].get("clean") is True, "pipeline_receipt_source_mismatch")
        artifact = receipt["artifact"]
        return {"sourceArchiveSha256": receipt["source"]["archiveSha256"], "sourceManifestSha256": None,
                "sourceTree": None, "nativeManifestDigest": artifact["nativeManifestDigest"],
                "configDigest": artifact["configDigest"], "archiveSha256": artifact["archiveSha256"],
                "buildIndexDigest": artifact["buildIndexDigest"], "generation": receipt["schemaGeneration"],
                "localTag": receipt["build"]["localTag"], "copied": receipt["allCopiedTrackedSourceCheck"], "flat": False}
    require(receipt.get("result") == "PASS_OFFICIAL_SOURCE_ARCHIVE_NATIVE_CHAIN" and
            receipt.get("sourceRevision") == selected["sourceRevision"] and
            receipt.get("architecture") == selected["architecture"] and receipt.get("officialDockerfileUnmodified") is True and
            re.fullmatch(r"[a-f0-9]{40}", receipt.get("sourceTree", "")), "qualified_public_pipeline_receipt_required")
    require("pipelineBuildMetadata" in paths and "pipelineBuildMetadataSha256" in paths,
            "pinned_public_pipeline_build_metadata_required")
    build = document(paths["pipelineBuildMetadata"], paths["pipelineBuildMetadataSha256"])
    index = build.get("containerimage.digest")
    require(isinstance(index, str) and re.fullmatch(r"sha256:[a-f0-9]{64}", index) and
            build.get("containerimage.descriptor", {}).get("digest") == index,
            "public_pipeline_index_descriptor_binding_required")
    return {"sourceArchiveSha256": receipt["sourceArchiveSha256"], "sourceManifestSha256": receipt["sourceManifestSha256"],
            "sourceTree": receipt["sourceTree"], "nativeManifestDigest": receipt["manifestDigest"],
            "configDigest": receipt["configDigest"], "archiveSha256": receipt["archiveSha256"],
            "buildIndexDigest": index, "generation": receipt["generation"], "localTag": receipt["localTag"],
            "copied": receipt["allCopiedSourceFiles"], "flat": True}


def native_archive(path, expected_sha, source, manifest_sha, config_sha, architecture):
    """Verify actual metadata bytes without extracting untrusted archive paths."""
    require(sha(path) == expected_sha, "native_archive_bytes_changed")
    with tarfile.open(path) as archive:
        def blob(value):
            require(re.fullmatch(r"sha256:[a-f0-9]{64}", value), "invalid_oci_digest")
            stream = archive.extractfile("blobs/sha256/" + value[7:])
            require(stream is not None, "oci_blob_missing")
            raw = stream.read()
            require("sha256:" + hashlib.sha256(raw).hexdigest() == value, "oci_blob_bytes_changed")
            return json.loads(raw)
        index = json.load(archive.extractfile("index.json"))
        require(len(index.get("manifests", [])) == 1, "native_archive_must_have_one_descriptor")
        descriptor = index["manifests"][0]
        value = blob(descriptor["digest"])
        if "manifests" in value:
            found = [d for d in value["manifests"] if d.get("platform") == {"architecture": architecture, "os": "linux"}]
            require(len(found) == 1, "unique_native_platform_required")
            descriptor = found[0]; value = blob(descriptor["digest"])
        require(descriptor["digest"] == manifest_sha and value["config"]["digest"] == config_sha, "native_manifest_config_mismatch")
        config = blob(config_sha)
        require(config.get("architecture") == architecture and config.get("os") == "linux", "native_architecture_mismatch")
        require(config.get("config", {}).get("Labels", {}).get("org.opencontainers.image.revision") == source,
                "native_source_label_mismatch")
        return config


def runtime_files(manifest):
    files = {}
    for name, info in manifest["files"].items():
        require(not name.startswith("/") and ".." not in Path(name).parts, "source_manifest_path_escape")
        if name.startswith(("packages/", "supabase/", "certs/", "src/", "stacks/")) and "/node_modules/" not in name and not name.startswith("packages/object-store/dist/"):
            files["/app/" + name] = file_sha(info)
        elif name in ("LICENSE", "NOTICE", "package.json", "bun.lock", "tsconfig.json", "scripts/sync-amp-provider.mjs", "scripts/install-amp-cli.ts"):
            files["/app/" + name] = file_sha(info)
    files["/entrypoint.sh"] = file_sha(manifest["files"]["docker/entrypoint.sh"])
    return files


class NativeReadOnlyAdapter:
    def __init__(self, stack, inputs):
        require(isinstance(inputs, dict) and INPUT_FIELDS <= set(inputs) and
                set(inputs) <= INPUT_FIELDS | OPTIONAL_INPUT_FIELDS, "unexpected_native_input_fields")
        require(("pipelineBuildMetadata" in inputs) == ("pipelineBuildMetadataSha256" in inputs),
                "public_build_metadata_path_and_digest_required_together")
        self.stack, self.inputs = stack, inputs

    def _docker_json(self, arguments, data=None):
        result = self.stack.cmd([*self.stack.docker_args, *arguments], data=data, timeout=180, sensitive=True)
        return json.loads(result.stdout)

    def _image(self, local_tag, source, architecture, index_digest, config_digest):
        images = self._docker_json(["image", "inspect", local_tag])
        require(len(images) == 1, "one_local_image_required")
        image = images[0]
        require(image.get("Architecture") == architecture and image.get("Os") == "linux", "docker_native_architecture_mismatch")
        require(image.get("Config", {}).get("Labels", {}).get("org.opencontainers.image.revision") == source,
                "docker_source_mismatch")
        # Docker29 may expose the index as Id. Never assume Id == config SHA.
        require(image.get("Descriptor", {}).get("digest") == index_digest and image.get("Id") in (index_digest, config_digest),
                "docker_immutable_transport_mismatch")
        return image

    def _probe(self, image_id, runtime, code, data):
        return self._docker_json(["run", "--pull", "never", "--rm", "-i", "--network", "none", "--read-only", "--cpus", "1",
                                  "--memory", "768m", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                                  "--entrypoint", runtime, image_id, "-e", code], data=json.dumps(data))

    def verify_artifact(self, selected):
        paths = self.inputs
        artifact = pipeline_coordinates(paths, selected)
        require(artifact["nativeManifestDigest"] == selected["manifestDigest"] and artifact["configDigest"] == selected["configDigest"] and
                artifact["generation"] == selected["generation"], "pipeline_receipt_chain_mismatch")
        source = document(paths["sourceManifest"], paths["sourceManifestSha256"])
        require(source["sourceRevision"] == selected["sourceRevision"] and
                source["archiveSha256"] == artifact["sourceArchiveSha256"], "source_manifest_binding_mismatch")
        if artifact["flat"]:
            require(source.get("sourceTree") == artifact["sourceTree"] and
                    paths["sourceManifestSha256"] == artifact["sourceManifestSha256"], "public_source_tree_manifest_binding_mismatch")
        else:
            require(source.get("sourceClean") is True, "source_manifest_binding_mismatch")
        require(sha(paths["sourceArchive"]) == source["archiveSha256"], "tracked_source_archive_changed")
        with tarfile.open(paths["sourceArchive"]) as original:
            members = {m.name: m for m in original if not m.isdir()}
            require(set(members) == set(source["files"]), "tracked_source_manifest_incomplete")
            for name, info in source["files"].items():
                member = members[name]
                require(member.isfile() or member.issym(), "unsupported_source_member")
                raw = member.linkname.encode() if member.issym() else original.extractfile(member).read()
                require(hashlib.sha256(raw).hexdigest() == file_sha(info), "tracked_source_file_changed")
        expected = runtime_files(source)
        require(artifact["copied"] == {"checked": len(expected), "mismatched": []}, "accepted_source_copy_manifest_mismatch")
        for name in BOOTSTRAP:
            require(expected.get("/app/supabase/bootstrap/" + name) == selected["officialBootstrapSha256"][name],
                    "image_bootstrap_acceptance_mismatch")
        native = native_archive(paths["pipelineArchive"], artifact["archiveSha256"], selected["sourceRevision"],
                                selected["manifestDigest"], selected["configDigest"], selected["architecture"])
        image = self._image(artifact["localTag"], selected["sourceRevision"], selected["architecture"], artifact["buildIndexDigest"], selected["configDigest"])
        if artifact["flat"]:
            diff_ids = native.get("rootfs", {}).get("diff_ids")
            require(native.get("rootfs", {}).get("type") == "layers" and isinstance(diff_ids, list) and
                    all(isinstance(d, str) and re.fullmatch(r"sha256:[a-f0-9]{64}", d) for d in diff_ids) and
                    image.get("RootFS", {}).get("Layers") == diff_ids and
                    all(image.get("Config", {}).get(k) == v for k, v in native["config"].items()),
                    "public_pipeline_native_runtime_config_changed")
        code = """const fs=require('fs'),crypto=require('crypto');const x=await Bun.stdin.json();let count=0;
for(const [p,h] of Object.entries(x)){if(crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex')!==h)process.exit(2);count++}
const {generation}=await import('/app/src/hoopdb/migrate.ts');console.log(JSON.stringify({checked:count,generation:await generation()}));"""
        checked = self._probe(image["Id"], "bun", code, expected)
        require(checked == {"checked": len(expected), "generation": selected["generation"]}, "actual_image_module_generation_mismatch")

        control = selected["control"]
        cr = document(paths["controlReceipt"], control["artifactReceiptSha256"])
        require(all(cr.get(k) == control[k] for k in ("sourceRevision", "manifestDigest", "configDigest")) and
                same_local_reference(cr.get("reference"), control["reference"]), "control_receipt_chain_mismatch")
        native_archive(paths["controlArchive"], cr["nativeArchiveSha256"], control["sourceRevision"], control["manifestDigest"], control["configDigest"], selected["architecture"])
        dist = document(paths["controlDistManifest"], cr["imageDistManifestSha256"])
        migration = document(paths["controlMigrationManifest"], paths["controlMigrationManifestSha256"])
        require(migration["source"] == control["sourceRevision"] and migration["migrationCount"] == len(migration["sql"]), "control_schema_manifest_mismatch")
        control_source = document(paths["controlSourceManifest"], cr["sourceFileManifestSha256"])
        require(all(control_source.get("migrations/" + n) == h for n, h in migration["sql"].items()), "control_source_schema_binding_mismatch")
        ci = self._image(cr["tag"], control["sourceRevision"], selected["architecture"], cr["dockerIndexDigest"], control["configDigest"])
        require(not any(e.startswith("SESSION_READ_API_") for e in ci["Config"].get("Env", [])), "independent_control_issuer_must_be_dormant")
        files = {"/app/node_modules/relay-control/" + n: h for n, h in dist.items()}
        files.update({"/app/node_modules/relay-control/migrations/" + n: h for n, h in migration["sql"].items()})
        js = """const fs=require('fs'),crypto=require('crypto');let raw='';process.stdin.on('data',b=>raw+=b);process.stdin.on('end',()=>{const x=JSON.parse(raw);for(const [p,h] of Object.entries(x)){if(crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex')!==h)process.exit(2)}console.log(JSON.stringify({checked:Object.keys(x).length}))});"""
        result = self._probe(ci["Id"], "node", js, files)
        require(result == {"checked": len(files)}, "actual_control_modules_schema_mismatch")
        return {k: selected[k] for k in ("sourceRevision", "manifestDigest", "configDigest", "generation", "officialBootstrapSha256", "control")}

    def _get(self, resources, namespace=True):
        args = ["get", resources, "-o", "json"]
        if not namespace:
            return json.loads(self.stack.k(*args, namespace=None, sensitive=True).stdout)
        return json.loads(self.stack.k(*args, sensitive=True).stdout)

    def _selected_secret_names(self, selected):
        return {r["name"] for r in selected["secretRefs"].values()}

    def inspect(self, selected):
        clusters = self.stack.cmd(["kind", "get", "clusters"], timeout=30).stdout.splitlines()
        if self.stack.name not in clusters:
            require(not self.stack.marker.exists() and not (self.stack.state / "ready.json").exists(), "missing_owned_cluster_is_not_fresh")
            return {"owned": True, "mode": "fresh", "clusterUid": None, "foreignWriters": []}
        uid = self._owned_uid(selected)
        # An already-populated target is repeat only with a bound native receipt.
        binding = document(self.inputs["bindingReceipt"], self.inputs["bindingReceiptSha256"])
        require(binding["clusterUid"] == uid and binding["profile"] == selected["profile"], "native_fixture_binding_mismatch")
        require(binding.get("roles") == selected["roles"] and binding.get("generation") == selected["generation"] and
                binding.get("officialBootstrapSha256") == selected["officialBootstrapSha256"], "native_role_generation_binding_mismatch")
        objects = self._get("deployments,statefulsets,persistentvolumeclaims,configmaps")["items"]
        # Read only the selected credential resources, never every Secret in
        # the namespace. Values remain process-local and are never returned.
        for name in sorted(self._selected_secret_names(selected)):
            objects.append(self._get("secret/" + name))
        by_id = {(o["kind"], o["metadata"]["name"]): o for o in objects}
        required_resources = {("StatefulSet", "postgres"), ("PersistentVolumeClaim", "data-postgres-0"),
                              ("PersistentVolumeClaim", selected["lockerClaim"]),
                              ("ConfigMap", selected["postgresCa"]["configMap"]),
                              ("Deployment", "relay-control"), ("Deployment", "relay-webapp"),
                              ("Deployment", "session-native-consumer"), ("Deployment", "session-native-ingest"),
                              ("Deployment", "session-read-api")}
        required_resources.update(("Secret", ref["name"]) for ref in selected["secretRefs"].values())
        require(required_resources <= {(r["kind"], r["name"]) for r in binding["resources"]}, "native_resource_binding_incomplete")
        for item in binding["resources"]:
            actual = by_id.get((item["kind"], item["name"]))
            require(actual and actual["metadata"]["uid"] == item["uid"], "native_resource_uid_changed")
        self._check_references(selected, by_id)
        writers = []
        native_names = {"session-native-consumer", "session-native-ingest", "session-read-api"}
        for o in objects:
            if o["kind"] != "Deployment" or not o["spec"].get("replicas", 1):
                continue
            for c in o["spec"]["template"]["spec"].get("containers", []):
                env = {e["name"]: e.get("value") for e in c.get("env", [])}
                if env.get("SERVICE") in {"ingest", "session-ingest", "session-pipeline-consumer", "alleyoop", "bob-costas", "referee"} and o["metadata"]["name"] not in native_names:
                    writers.append(o["metadata"]["name"])
        require(not writers, "legacy_or_foreign_pipeline_writer_active")
        return {"owned": True, "mode": "repeat", "clusterUid": uid, "foreignWriters": [],
                "boundResourceCount": len(binding["resources"])}

    def _owned_uid(self, selected):
        # Stack.require_owned_cluster exports/replaces kubeconfig. This path
        # must remain GET-only and preserve every existing local receipt.
        from stack import NODE
        record = json.loads(self.stack.marker.read_text())
        require(record.get("version") == 1 and record.get("name") == self.stack.name and
                record.get("profile") == selected["profile"] and record.get("nodeImage") == NODE and
                record.get("dockerHost") == self.stack.env.get("DOCKER_HOST"), "owned_cluster_receipt_mismatch")
        uid = self._get("namespace/kube-system", namespace=False)["metadata"]["uid"]
        require(record.get("clusterUid") == uid, "owned_cluster_uid_changed")
        nodes = self._get("nodes", namespace=False)["items"]
        local_nodes = self.stack.cmd(["kind", "get", "nodes", "--name", self.stack.name], timeout=30).stdout.splitlines()
        require(nodes and {n["metadata"]["name"] for n in nodes} == set(local_nodes) and
                all(n["metadata"].get("labels", {}).get("agentrelay-kind-owner") == "infra" for n in nodes),
                "owned_cluster_node_identity_changed")
        return uid

    def _check_references(self, selected, by_id):
        ca = by_id.get(("ConfigMap", selected["postgresCa"]["configMap"]), {})
        require(ca.get("immutable") is True and set(ca.get("data", {})) == {"ca.crt"} and
                hashlib.sha256(ca["data"]["ca.crt"].encode()).hexdigest() == selected["postgresCa"]["sha256"], "native_public_ca_changed")
        passwords = []
        for name, ref in selected["secretRefs"].items():
            actual = by_id.get(("Secret", ref["name"]), {})
            require(ref["key"] in actual.get("data", {}) and actual["data"][ref["key"]], "native_secret_ref_missing")
            if name in ("consumer", "reader", "ingest"):
                require(actual.get("immutable") is True, "runtime_secret_must_be_immutable")
            if name in ("owner", "consumer", "reader", "ingest"):
                try:
                    raw = base64.b64decode(actual["data"][ref["key"]], validate=True).decode()
                    if ref["jsonField"]:
                        payload = json.loads(raw)
                        require(set(payload) == {ref["jsonField"]}, "managed_database_payload_keys_changed")
                        raw = payload[ref["jsonField"]]
                    url = urlsplit(raw)
                    ca_path = {"owner": "/etc/native-consumer-postgres/ca.crt", "consumer": "/etc/native-consumer-postgres/ca.crt",
                               "reader": "/etc/session-read-postgres/ca.crt", "ingest": "/etc/session-ingest-postgres/ca.crt"}[name]
                    require(url.scheme in {"postgres", "postgresql"} and unquote(url.username or "") == selected["roles"][name] and
                            bool(url.password) and url.hostname == selected["postgres"]["host"] and url.port in (None, 5432) and
                            url.path == "/hoopdb" and not url.fragment and
                            parse_qs(url.query) == {"sslmode": ["verify-full"], "sslrootcert": [ca_path]}, "native_database_url_identity_or_tls_changed")
                    passwords.append(unquote(url.password))
                except (ValueError, TypeError, KeyError):
                    raise NativeRecipeError("native_database_secret_payload_invalid") from None
        require(len(passwords) == 4 and len(set(passwords)) == 4, "database_credentials_must_not_share_owner_or_runtime_passwords")
        passwords.clear()
        ir = selected["secretRefs"]["introspection"]
        ingest = by_id[("Secret", selected["secretRefs"]["ingest"]["name"])]
        require("introspect-secret" in ingest.get("data", {}) and
                hmac.compare_digest(ingest["data"]["introspect-secret"], by_id[("Secret", ir["name"])]["data"][ir["key"]]),
                "ingest_introspection_credential_differs")
        pg = by_id.get(("StatefulSet", "postgres"), {})
        containers = pg.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        require(len(containers) == 1 and containers[0].get("args", []).count("ssl=on") == 1 and
                not any(x.startswith("ssl=") and x != "ssl=on" for x in containers[0].get("args", [])), "postgres_tls_not_enabled")
        return {"caSha256": selected["postgresCa"]["sha256"], "postgresTlsConfigured": True,
                "secretReferences": {n: {"name": r["name"], "key": r["key"], "jsonField": r["jsonField"],
                    "uid": by_id[("Secret", r["name"])]["metadata"]["uid"]} for n, r in selected["secretRefs"].items()},
                "scope": "Reference/URL/CA/TLS-configuration equality only; no role-bootstrap, repeat-up, handshake or whole-core acceptance"}

    def qualify_references(self, selected):
        """Scoped diagnostic; never upgrades historical evidence into admission."""
        self._owned_uid(selected)
        objects = [self._get("statefulset/postgres"), self._get("configmap/" + selected["postgresCa"]["configMap"])]
        for name in sorted(self._selected_secret_names(selected)):
            objects.append(self._get("secret/" + name))
        return self._check_references(selected, {(o["kind"], o["metadata"]["name"]): o for o in objects})

    def render(self, selected):
        values = []
        args = self.stack.values_args()
        for i in range(0, len(args), 2):
            require(args[i] == "-f", "unrecognized_values_argument")
            values.append(yaml.safe_load(Path(args[i + 1]).read_text()) or {})
        merged = merge_values(*values)
        pipeline = merged.get("sessions-pipeline", {})
        require(pipeline.get("nativeRouting", {}).get("enabled") is True and
                pipeline.get("sessionReadApi", {}).get("login", {}).get("advertisesSync") is selected["readerLoginAdvertisesSync"],
                "managed_native_routing_sync_required")
        require(not any(e.get("name") == "RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC" for e in pipeline["sessionReadApi"].get("extraEnv", [])),
                "sync_discovery_must_not_use_extra_env")
        # Unlike legacy Stack.render, retain output only in memory. Invalid
        # values must not write a raw Secret-bearing manifest to evidence.
        result = self.stack.cmd(["helm", "template", "agent-relay", "charts/agent-relay", "-n", "agent-relay", *args],
                                timeout=60, sensitive=True)
        docs = [d for d in yaml.safe_load_all(result.stdout) if d]
        require(not any(d.get("kind") == "Secret" for d in docs), "native_serve_must_reference_managed_secrets")
        return self._validate_render_docs(selected, docs)

    def _validate_render_docs(self, selected, docs):
        deployed = {d["metadata"]["name"]: d for d in docs if d["kind"] == "Deployment"}
        expected = {
            "session-native-consumer": ("session-pipeline-consumer", "RELAYHISTORY_PIPELINE_CONSUMER_SECRET", "consumer"),
            "session-read-api": ("session-read-api", "RELAYHISTORY_READ_API_SECRET", "reader"),
            "session-native-ingest": ("session-ingest", "RELAYHISTORY_INGEST_DATABASE_URL", "ingest"),
        }
        for name, (service, variable, kind) in expected.items():
            d = deployed.get(name, {}); pod = d.get("spec", {}).get("template", {}).get("spec", {})
            containers = pod.get("containers", [])
            require(len(containers) == 1 and containers[0]["image"] == selected["reference"], "native_rendered_image_mismatch")
            require(all(c.get("image") == selected["reference"] for c in pod.get("initContainers", [])), "native_init_image_mismatch")
            require(any(p.get("containerPort") == (8080 if kind == "reader" else 8081) for p in containers[0].get("ports", [])), "native_service_port_mismatch")
            envlist = containers[0].get("env", []); env = {e["name"]: e for e in envlist}
            require(len(env) == len(envlist) and env.get("SERVICE", {}).get("value") == service, "native_service_env_mismatch")
            require(env.get("LOCKER_BUCKET", {}).get("value") == selected["lockerBucket"], "native_locker_bucket_mismatch")
            ref = selected["secretRefs"][kind]
            require(env.get(variable, {}).get("valueFrom", {}).get("secretKeyRef") == {"name": ref["name"], "key": ref["key"]}, "native_rendered_secret_ref_mismatch")
            require(env.get("SESSION_POSTGRES_TLS_PROFILE", {}).get("value") == "custom-ca" and
                    env.get("SESSION_POSTGRES_CA_SHA256", {}).get("value") == selected["postgresCa"]["sha256"], "native_rendered_ca_mismatch")
            require(not any("OWNER_BUFFERED" in n or n.startswith(("INGEST_PUBLISH", "INGEST_PUBLICATION")) or
                            n in {"INGEST_ACCEPTANCE_MODE", "INGEST_CUSTODY_SOURCE", "INGEST_PRIVACY_AUTHORITY", "INGEST_REPLICA_MODE", "INGEST_SIGNING_KEY"}
                            for n in env), "unsupported_publication_or_custody_env")
            if kind == "ingest":
                require(env.get("INGEST_KEY_ROOT", {}).get("value") == selected["keyRoot"] and
                        env.get("RELAYHISTORY_INGEST_ORIGIN", {}).get("value") == selected["historyOrigin"], "native_ingest_layout_audience_mismatch")
                require(env.get("RELAYCONTROL_INTROSPECT_SECRET", {}).get("valueFrom", {}).get("secretKeyRef") ==
                        {"name": ref["name"], "key": "introspect-secret"}, "ingest_introspection_ref_mismatch")
            else:
                require(env.get("PIPELINE_KEY_PREFIX", {}).get("value") == selected["keyRoot"] and
                        env.get("PIPELINE_ORG_FROM_PREFIX", {}).get("value") == "true" and
                        env.get("SEARCH_INDEX_BACKEND", {}).get("value") == "postgres" and
                        env.get("SEARCH_INDEX_POSTGRES_BACKEND_ID", {}).get("value") == selected["backendId"] and
                        env.get("READ_API_COMPLETE_SINCE", {}).get("value") == selected["completeSince"], "native_reader_consumer_layout_mismatch")
            if kind == "reader":
                ir = selected["secretRefs"]["introspection"]
                independent = selected["control"]["independentIssuer"]
                require(env.get("READ_API_AUTH_MODE", {}).get("value") == ("self_issued" if independent else "relaycontrol_only") and
                        env.get("READ_API_ORIGIN", {}).get("value") == selected["historyOrigin"] and
                        not ({"RELAYAUTH_JWKS_URL", "RELAYAUTH_ISSUER"} & set(env)), "reader_auth_discovery_mismatch")
                if independent:
                    issuer = selected["secretRefs"]["readerIssuer"]
                    require(not ({"RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC", "RELAYCONTROL_INTROSPECT_URL", "RELAYCONTROL_INTROSPECT_SECRET"} & set(env)) and
                            env.get("READ_API_INTERNAL_SECRET", {}).get("valueFrom", {}).get("secretKeyRef") ==
                            {"name": issuer["name"], "key": issuer["key"]} and
                            env.get("READ_API_EVENT_MESSAGE_IDS", {}).get("value") == "true", "reader_independent_issuer_binding_mismatch")
                else:
                    require(env.get("RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC", {}).get("value") == "true" and
                            env.get("RELAYCONTROL_INTROSPECT_SECRET", {}).get("valueFrom", {}).get("secretKeyRef") ==
                            {"name": ir["name"], "key": ir["key"]}, "reader_introspection_ref_mismatch")
            locker = selected["secretRefs"]["locker"]
            require(env.get("LOCKER_SECRET_ACCESS_KEY", {}).get("valueFrom", {}).get("secretKeyRef") ==
                    {"name": locker["name"], "key": locker["key"]}, "locker_secret_ref_mismatch")
            require(any(v.get("configMap", {}).get("name") == selected["postgresCa"]["configMap"] for v in pod.get("volumes", [])), "native_rendered_ca_volume_missing")
            encoded = json.dumps(pod)
            require(selected["secretRefs"]["owner"]["name"] not in encoded, "owner_secret_in_runtime_pod")
        for d in docs:
            if d["kind"] == "Job":
                component = d["metadata"].get("labels", {}).get("app.kubernetes.io/component", "")
                require(component not in {"native-consumer-bootstrap", "hoopdb-migrate", "locker-init"}, "privileged_or_legacy_job_in_final_serve")
        control = deployed.get("relay-control", {}).get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        require(len(control) == 1 and same_local_reference(control[0]["image"], selected["control"]["reference"]), "control_rendered_image_mismatch")
        ce = {e["name"]: e.get("value") for e in control[0].get("env", [])}
        if selected["control"]["independentIssuer"]:
            require(ce.get("RELAYHISTORY_BACKEND") == "native" and
                    ce.get("SESSION_READ_API_URL") == "http://session-read-api.agent-relay.svc.cluster.local" and
                    ce.get("SESSION_READ_API_PUBLIC_URL") == selected["historyOrigin"] and
                    bool(ce.get("SESSION_READ_API_SECRET_FILE")) and
                    not ({"RELAYHISTORY_URL", "RELAYHISTORY_PUBLIC_URL", "RELAYHISTORY_READ_API_URL", "RELAYHISTORY_READ_API_EVENTS", "RELAYAUTH_URL"} & set(ce)),
                    "control_independent_reader_handoff_mismatch")
        else:
            require(ce.get("RELAYHISTORY_READ_API_URL") == selected["historyOrigin"] and ce.get("RELAYHISTORY_READ_API_EVENTS") == "true" and
                    not any(n.startswith("SESSION_READ_API_") for n in ce), "control_native_readback_or_independent_issuer_mismatch")
        for name in ("session-ingest-api", "session-summary-worker", "session-status-worker", "session-metadata-indexer"):
            require(not deployed.get(name, {}).get("spec", {}).get("replicas", 0), "legacy_writer_rendered_active")
        self._verified_render_docs = docs
        return {"legacyWriterCount": 0, "managedNative": True, "ownerBuffered": False, "publication": False,
                "readerLoginAdvertisesSync": selected["readerLoginAdvertisesSync"]}
