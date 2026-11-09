"""Explicit local reconciliation of a completed, data-preserving naming cutover.

This imports proof, never performs the cutover, adopts a release, or creates a
replacement claim. Ordinary up remains closed for an unqualified old fixture.
"""
from __future__ import annotations
import base64
import hashlib
import json
from pathlib import Path
import re
import secrets

import yaml

NAME = "session-object-storage"
RELEASE = "kind-locker"
RECORD = "named-layout.json"
SHA = re.compile(r"[a-f0-9]{64}\Z")
OLD = {"relaycontrol", "relay-app", "alleyoop-ingest", "sessions-bob-costas", "sessions-hoopdb-indexer", "sessions-referee", "locker"}
REQUIRED_BASE = {"relay-control", "relay-webapp"}


def fail(message):
    # Import lazily: stack imports this module only for the explicit path.
    from stack import StackError
    raise StackError("named-layout reconciliation: " + message)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def read(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        fail("missing or malformed private receipt")


def write(path, value):
    from stack import private_json
    private_json(path, value)


def sha_file(path):
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        fail("qualified private artifact is missing or unreadable")


def normal_inventory(rows):
    if not isinstance(rows, list) or not rows:
        fail("seeded inventory must contain objects")
    out = []
    for row in rows:
        if (not isinstance(row, dict) or set(row) != {"key", "size", "etag", "versionId"}
                or not isinstance(row["key"], str) or not row["key"]
                or type(row["size"]) is not int or row["size"] < 0
                or not (row["etag"] is None or isinstance(row["etag"], str))
                or not (row["versionId"] is None or isinstance(row["versionId"], str))):
            fail("invalid seeded object inventory")
        out.append(row)
    if len({r["key"] for r in out}) != len(out):
        fail("duplicate seeded object keys")
    return sorted(out, key=lambda row: row["key"])


def inventory_summary(rows):
    return {"objects": len(rows), "bytes": sum(r["size"] for r in rows), "sha256": digest(rows)}


def completed_proof(proof, before, after):
    """Typed artifact admission; neither a PASS string nor the live UID suffices."""
    before, after = normal_inventory(before), normal_inventory(after)
    if (not isinstance(proof, dict) or proof.get("result") != "PASS"
            or proof.get("phase") != "CLIENT_WRITERS_RESUMED"
            or proof.get("oneStoragePodVerified") is not True
            or proof.get("pvcPreserved") is not True or proof.get("imageUnchanged") is not True
            or proof.get("postRendererRequiredForFutureUpgrade") is not True
            or proof.get("rollback") is not None
            or proof.get("servicesRetained") != ["locker", "locker-console"]
            or before != after or proof.get("seededInventory") != inventory_summary(before)
            or proof.get("afterInventory") != inventory_summary(after)):
        fail("cutover has no completed equal seeded before/after proof")
    for field in ("pvcUid", "oldDeploymentUid", "newDeploymentUid"):
        if not isinstance(proof.get(field), str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", proof[field]):
            fail("cutover identity is missing")
    if proof["oldDeploymentUid"] == proof["newDeploymentUid"]:
        fail("cutover did not record distinct Deployment identities")
    if (not isinstance(proof.get("sentinelSha256"), str) or not SHA.fullmatch(proof["sentinelSha256"])
            or not isinstance(proof.get("sentinelKey"), str)
            or not re.fullmatch(r"__kind_naming_proof__/storage-[a-f0-9]{32}\.txt", proof["sentinelKey"])
            or proof["sentinelKey"] not in {r["key"] for r in before}):
        fail("cutover has no bound synthetic sentinel")
    return before


def obj_identity(obj):
    meta = obj["metadata"]
    return {"uid": meta["uid"], "spec": obj.get("spec", {}),
            "release": meta.get("annotations", {}).get("meta.helm.sh/release-name"),
            "namespace": meta.get("annotations", {}).get("meta.helm.sh/release-namespace")}


def live_objects(stack):
    result = json.loads(stack.k("get", "deploy,pvc,svc,statefulset", "-o", "json").stdout)
    return {(d["kind"], d["metadata"]["name"]): d for d in result.get("items", [])}


def reject_legacy_workloads(objects):
    if any(kind == "Deployment" and name in OLD for kind, name in objects):
        fail("a legacy Deployment is still present")


def live_release(stack, release):
    rows = json.loads(stack.cmd(["helm", "list", "-n", "agent-relay", "-o", "json"]).stdout)
    matches = [r for r in rows if r.get("name") == release]
    if len(matches) != 1 or matches[0].get("namespace") != "agent-relay" or matches[0].get("status") != "deployed":
        fail("expected an already-deployed owned Helm release")
    values = json.loads(stack.cmd(["helm", "get", "values", release, "-n", "agent-relay", "-o", "json"], sensitive=True).stdout)
    manifest = stack.cmd(["helm", "get", "manifest", release, "-n", "agent-relay"], sensitive=True).stdout
    documents = [d for d in yaml.safe_load_all(manifest) if d]
    return matches[0], values, sorted(documents, key=lambda d: (d["kind"], d["metadata"]["name"]))


def storage_snapshot(stack, objects):
    wanted = [("Deployment", NAME), ("PersistentVolumeClaim", "locker"), ("Service", "locker"), ("Service", "locker-console")]
    if any(k not in objects for k in wanted) or ("Deployment", "locker") in objects:
        fail("renamed storage and the original claim/services must exist without the old Deployment")
    out = {}
    for kind, name in wanted:
        obj = objects[(kind, name)]
        ident = obj_identity(obj)
        if ident["release"] != RELEASE or ident["namespace"] != "agent-relay":
            fail("storage resource belongs to another release")
        out[kind + "/" + name] = ident
    deploy = objects[("Deployment", NAME)]
    spec = deploy["spec"]
    if (spec.get("replicas") != 1 or deploy.get("status", {}).get("readyReplicas") != 1
            or spec["selector"].get("matchLabels") != {"app": "minio", "release": RELEASE}
            or objects[("PersistentVolumeClaim", "locker")].get("status", {}).get("phase") != "Bound"
            or not any(v.get("persistentVolumeClaim", {}).get("claimName") == "locker"
                       for v in spec["template"]["spec"].get("volumes", []))):
        fail("storage is not one ready writer on the original Bound claim")
    pods = json.loads(stack.k("get", "pods", "-l", "app=minio,release=kind-locker", "-o", "json").stdout).get("items", [])
    if len(pods) != 1 or pods[0].get("metadata", {}).get("deletionTimestamp"):
        fail("exactly one non-terminating storage Pod is required")
    return out


def postgres_snapshot(objects):
    keys = [("StatefulSet", "postgres"), ("PersistentVolumeClaim", "data-postgres-0"), ("Service", "postgres")]
    if any(k not in objects for k in keys):
        fail("existing Postgres StatefulSet, Service and claim are required")
    return {kind + "/" + name: obj_identity(objects[(kind, name)]) for kind, name in keys}


def private_state(stack):
    result = {"credentials.json": digest(read(stack.state / "credentials.json"))}
    for name in ("auth-signing.pem", "ca.crt", "ca.key", "tls.crt", "tls.key"):
        result[name] = sha_file(stack.state / name)
    return result


def postgres_secret_snapshot(stack, objects):
    spec = objects[("StatefulSet", "postgres")]["spec"]["template"]["spec"]
    names = {v["secret"]["secretName"] for v in spec.get("volumes", []) if "secret" in v}
    names.update(e["valueFrom"]["secretKeyRef"]["name"] for c in spec.get("containers", [])
                 for e in c.get("env", []) if "secretKeyRef" in e.get("valueFrom", {}))
    result = {}
    for name in sorted(names):
        secret = json.loads(stack.k("get", "secret", name, "-o", "json", sensitive=True).stdout)
        result[name] = {"uid": secret["metadata"]["uid"], "dataSha256": digest(secret.get("data", {}))}
    return result


def mc(stack, args):
    # The process-only alias never stores the credential in mc's config file.
    command = ('export MC_HOST_naming="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@127.0.0.1:9000"; '
               'exec /usr/bin/mc --config-dir /tmp/kind-naming-proof-mc --json "$@"')
    return stack.k("exec", "-i", "deploy/" + NAME, "--", "/bin/sh", "-c", command,
                   "kind-naming-probe", *args, sensitive=True).stdout


def verify_seeded_readback(stack, record):
    rows = []
    for line in mc(stack, ["ls", "--recursive", "naming/locker"]).splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            fail("object inventory response is invalid")
        if row.get("status") != "success":
            fail("object inventory was refused")
        if row.get("type") == "file":
            rows.append({k: row.get(k) for k in ("key", "size", "etag", "versionId")})
    actual = {r["key"]: r for r in normal_inventory(rows)}
    for row in normal_inventory(record["seedObjects"]):
        if actual.get(row["key"]) != row:
            fail("seeded object inventory changed or disappeared")
    payload = mc(stack, ["cat", "naming/locker/" + record["sentinelKey"]])
    if hashlib.sha256(payload.encode()).hexdigest() != record["sentinelSha256"]:
        fail("synthetic sentinel content changed")


def values_validate(values, profile):
    if not isinstance(values, dict) or any(k in values for k in ("relay-cloud-api", "relay-dashboard")):
        fail("installed values still use the old public chart keys")
    if not isinstance(values.get("localKind"), dict) or values["localKind"].get("profile") != profile:
        fail("installed values belong to another profile")
    components = values.get("components", {})
    if not isinstance(components, dict):
        fail("installed component selection must be an object")
    if any(k in components for k in ("cloudApi", "dashboard")):
        fail("installed component keys have not been translated")
    for name in ("relayflows", "relayfile"):
        if type(components.get(name, False)) is not bool or components.get(name, False) != (profile == "addons"):
            fail("installed add-on selection does not match this profile")
    pipeline = values.get("sessions-pipeline", {})
    if (not isinstance(pipeline, dict) or not isinstance(pipeline.get("session-object-storage"), dict)
            or pipeline["session-object-storage"].get("enabled") is not False):
        fail("the umbrella must not create a second storage claim")
    for child in ("worker", "alleyoop"):
        if (not isinstance(pipeline.get(child), dict) or not isinstance(pipeline[child].get("locker"), dict)
                or pipeline[child]["locker"].get("endpoint") != "http://locker:9000"):
            fail("existing storage DNS must remain explicit")


def check_anchor(stack, record):
    ownership = read(stack.marker)
    if (not isinstance(record, dict) or not isinstance(ownership, dict)
            or record.get("version") != 1 or type(record.get("version")) is not int
            or record.get("type") != "local-kind-named-layout"
            or record.get("profile") != stack.profile or record.get("name") != stack.name
            or record.get("clusterUid") != ownership.get("clusterUid")
            or record.get("dockerHost") != stack.env.get("DOCKER_HOST")
            or ownership.get("profile") != stack.profile):
        fail("typed naming receipt does not match this owned profile")
    history = record.get("history")
    if not isinstance(history, str) or not re.fullmatch(r"named-history-[a-f0-9]{16}", history):
        fail("missing original readiness archive")
    path = stack.state / history / "ready.json"
    if ((stack.state / history).is_symlink() or not path.is_file() or path.is_symlink()
            or sha_file(path) != record.get("readyAnchorSha256")):
        fail("original readiness archive changed or disappeared")
    ready = read(path)
    if not isinstance(ready, dict) or ready.get("clusterUid") != record["clusterUid"] or ready.get("profile") != stack.profile:
        fail("original readiness does not bind this profile and cluster")
    for key in ("storageValuesSha256", "storageChartSha256", "storageManifestSha256", "activeValuesSha256", "sentinelSha256"):
        if not isinstance(record.get(key), str) or not SHA.fullmatch(record[key]):
            fail("typed naming receipt is missing a content digest")
    previous = record.get("previousActiveValuesSha256")
    if previous is not None and (not isinstance(previous, str) or not SHA.fullmatch(previous)):
        fail("typed naming receipt has invalid interrupted-selection metadata")
    if (not isinstance(record.get("storageValues"), dict)
            or digest(record["storageValues"]) != record["storageValuesSha256"]
            or not isinstance(record.get("sentinelKey"), str)
            or not re.fullmatch(r"__kind_naming_proof__/storage-[a-f0-9]{32}\.txt", record["sentinelKey"])):
        fail("typed naming receipt has invalid storage values or sentinel")
    normal_inventory(record.get("seedObjects"))


def verify_credentials(stack):
    try:
        values = stack.credential_values(read(stack.state / "credentials.json"),
                                        (stack.state / "auth-signing.pem").read_text())
    except (OSError, KeyError, TypeError):
        fail("existing private credential state is incomplete")
    for name, selected in values.items():
        preserve_secret(stack, name, selected)


def validate(stack, *, check_values=True):
    record = read(stack.state / RECORD)
    check_anchor(stack, record)
    objects = live_objects(stack)
    reject_legacy_workloads(objects)
    if storage_snapshot(stack, objects) != record.get("storage") or postgres_snapshot(objects) != record.get("postgres"):
        fail("recorded storage/Postgres identity or specification changed")
    if private_state(stack) != record.get("privateState") or postgres_secret_snapshot(stack, objects) != record.get("postgresSecrets"):
        fail("private credential/PKI state or a Postgres Secret changed")
    if sha_file(stack.root / "ci/agent-relay/kind/storage-name-renderer/postrender.py") != record.get("storageRendererSha256"):
        fail("reviewed storage postrenderer changed")
    release, values, manifest = live_release(stack, RELEASE)
    if (release.get("chart") != "minio-5.4.0" or digest(values) != record.get("storageValuesSha256")
            or digest(manifest) != record.get("storageManifestSha256")):
        fail("storage release configuration changed")
    if check_values:
        values = read(stack.overrides)
        values_validate(values, stack.profile)
        if digest(values) not in {record.get("activeValuesSha256"), record.get("previousActiveValuesSha256")}:
            fail("active profile selection changed; explicitly reconcile before reuse")
        if record.get("controlBuildSha256") is not None:
            if sha_file(stack.state / "control-build.json") != record["controlBuildSha256"]:
                fail("selected Control build metadata changed")
    verify_seeded_readback(stack, record)
    verify_credentials(stack)
    verify_tls(stack)
    return record


def preserve_secret(stack, name, values):
    """A naming-only reuse may not rotate a key or remove another service's key."""
    obj = json.loads(stack.k("get", "secret", name, "-o", "json", sensitive=True).stdout)
    data = obj.get("data", {})
    for key, value in values.items():
        if data.get(key) != base64.b64encode(value.encode()).decode():
            fail("existing credential does not match the local private state; no Secret was changed")


def verify_tls(stack):
    from stack import HOSTS
    preserve_secret(stack, "kind-tls", {name: (stack.state / name).read_text() for name in ("tls.crt", "tls.key")})
    for host in HOSTS:
        stack.cmd(["openssl", "verify", "-x509_strict", "-verify_hostname", host,
                   "-CAfile", stack.state / "ca.crt", stack.state / "tls.crt"])


def install_storage(stack):
    """Upgrade the original release with its original claim rendered in place."""
    record = stack.named_layout
    values = record["storageValues"]
    if digest(values) != record["storageValuesSha256"]:
        fail("saved storage values changed")
    chart = stack.root / "charts/sessions-pipeline/charts/minio-5.4.0.tgz"
    if sha_file(chart) != record["storageChartSha256"]:
        fail("storage chart bytes differ from the qualified cutover")
    path = stack.state / "named-storage-values.json"
    write(path, values)
    plugin = stack.root / "ci/agent-relay/kind/storage-name-renderer"
    version = stack.cmd(["helm", "version", "--template", "{{.Version}}"]).stdout.strip()
    previous = stack.env.get("HELM_PLUGINS")
    try:
        if version.startswith("v4."):
            plugins = stack.state / "helm-named-plugins"
            if plugins.is_symlink():
                fail("private postrenderer directory must not redirect to another Helm configuration")
            plugins.mkdir(mode=0o700, exist_ok=True)
            selected = plugins / "kind-storage-names"
            if (selected.exists() or selected.is_symlink()) and selected.resolve() != plugin.resolve():
                fail("private postrenderer path belongs to another plugin")
            if not selected.exists() and not selected.is_symlink():
                selected.symlink_to(plugin.resolve(), target_is_directory=True)
            stack.env["HELM_PLUGINS"] = str(plugins)
            renderer = "kind-storage-names"
        elif version.startswith("v3."):
            renderer = str(plugin / "postrender.py")
        else:
            fail("unsupported Helm postrenderer protocol")
        args = ["helm", "upgrade", RELEASE, chart, "-n", "agent-relay", "-f", path,
                "--post-renderer", renderer, "--no-hooks", "--wait", "--timeout", "5m"]
        if version.startswith("v4."):
            args += ["--server-side=false"]
        stack.cmd(args, timeout=330, sensitive=True)
    finally:
        if previous is None:
            stack.env.pop("HELM_PLUGINS", None)
        else:
            stack.env["HELM_PLUGINS"] = previous


def refresh_after_up(stack):
    # Never manufacture a new acceptance result. Only refresh the active
    # selection after up has completed; the old proof/anchor stays historical.
    record = validate(stack, check_values=False)
    values = read(stack.overrides)
    values_validate(values, stack.profile)
    record["activeValuesSha256"] = digest(values)
    record.pop("previousActiveValuesSha256", None)
    record["controlBuildSha256"] = sha_file(stack.state / "control-build.json") if (stack.state / "control-build.json").exists() else None
    write(stack.state / RECORD, record)
    stack.named_layout = record


def stage_selection(stack, values):
    """Keep an interrupted tenant annotation update retryable, without readiness.

    Write both allowed local hashes before replacing values.json. Either side
    of that one-file replacement is then a known selection; no proof is minted.
    """
    record = read(stack.state / RECORD)
    check_anchor(stack, record)
    old_values = read(stack.overrides)
    current = digest(old_values)
    if current not in {record.get("activeValuesSha256"), record.get("previousActiveValuesSha256")}:
        fail("active selection changed during up")
    paths = [("global", "tenant", "orgId"),
             ("sessions-pipeline", "worker", "tenant", "orgId"),
             ("sessions-pipeline", "worker", "tenant", "workspaceId"),
             ("sessions-pipeline", "alleyoop", "tenant", "orgId"),
             ("sessions-pipeline", "alleyoop", "tenant", "workspaceId"),
             ("sessions-pipeline", "worker", "podAnnotations", "kind.agentrelay.dev/bootstrap-source")]
    if stack.profile == "addons":
        paths.append(("relayflows", "nodeSelector", "kubernetes.io/arch"))
    def unmanaged(value):
        value = json.loads(json.dumps(value))
        for path in paths:
            parent = value
            for part in path[:-1]:
                parent = parent.get(part, {}) if isinstance(parent, dict) else {}
            if isinstance(parent, dict):
                parent.pop(path[-1], None)
        def prune(item):
            return {k: prune(v) for k, v in item.items() if v != {}} if isinstance(item, dict) else item
        # Remove newly-created empty ancestor maps as well.
        while True:
            next_value = prune(value)
            if next_value == value:
                return value
            value = next_value
    if unmanaged(old_values) != unmanaged(values):
        fail("up attempted to change more than discovered tenant metadata")
    record["previousActiveValuesSha256"] = current
    record["activeValuesSha256"] = digest(values)
    write(stack.state / RECORD, record)
    stack.named_layout = record


def subset(expected, actual):
    """Compare rendered intent while tolerating only API-added default fields."""
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return False
        for key, value in expected.items():
            # The API drops empty env.value. No other missing field is admitted.
            if key == "value" and value == "" and key not in actual:
                continue
            if key not in actual or not subset(value, actual[key]):
                return False
        return True
    if isinstance(expected, list):
        return isinstance(actual, list) and len(expected) == len(actual) and all(subset(a, b) for a, b in zip(expected, actual))
    return expected == actual


def render_selected(stack, values):
    temporary = stack.state / ("naming-render-" + secrets.token_hex(8) + ".json")
    try:
        write(temporary, values)
        args = ["helm", "template", "agent-relay", "charts/agent-relay", "-n", "agent-relay",
                "-f", stack.root / "charts/agent-relay/values-kind-core.yaml"]
        if stack.profile == "addons":
            args += ["-f", stack.root / "charts/agent-relay/values-kind-addons.yaml"]
        raw = stack.cmd([*args, "-f", temporary], sensitive=True).stdout
        return [d for d in yaml.safe_load_all(raw) if d]
    finally:
        temporary.unlink(missing_ok=True)


def current_search_writer(doc, selected):
    """Admit the current searchIndexer chart, not #123's separate init contract.

    The qualified SERVICE itself pins the authenticated search_consumer_runtime
    login and schema/RLS admission before becoming ready. NATIVE_CONSUMER_*
    belongs to the future nativeConsumer init and is not a runtime requirement
    of this chart. Credentials stay behind its selected runtime Secret ref.
    """
    from stack import pod_spec
    labels = doc.get("metadata", {}).get("labels", {})
    spec = doc.get("spec", {})
    if (doc.get("kind") != "Deployment" or labels.get("app.kubernetes.io/name") != "session-search-indexer"
            or labels.get("app.kubernetes.io/component") != "search-indexer"
            or spec.get("replicas") != 1 or spec.get("strategy", {}).get("type") != "Recreate"):
        return False
    config = selected.get("config", {})
    runtime = {"name": config.get("existingSecret"), "key": config.get("key", "RELAYHISTORY_PIPELINE_CONSUMER_SECRET")}
    bootstrap = selected.get("bootstrap", {})
    owner = {"name": bootstrap.get("existingSecret"), "key": bootstrap.get("key", "RELAYHISTORY_PIPELINE_CONSUMER_SECRET")}
    tls = selected.get("postgres", {})
    search = selected.get("search", {})
    locker = selected.get("locker", {})
    if (not all(isinstance(v, str) and v for v in runtime.values()) or runtime == owner
            or tls.get("tlsProfile", "custom-ca") != "custom-ca"
            or not isinstance(tls.get("caConfigMap"), str) or not tls["caConfigMap"]
            or not isinstance(tls.get("caSha256"), str) or not SHA.fullmatch(tls["caSha256"])
            or not search.get("backendId") or not selected.get("completeSince") or not locker.get("bucket")
            or locker.get("endpoint") != "http://locker:9000"):
        return False
    contract = {"SERVICE": "session-pipeline-consumer", "RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER": "true",
                "SEARCH_INDEX_BACKEND": "postgres", "SEARCH_INDEX_POSTGRES_BACKEND_ID": search["backendId"],
                "READ_API_COMPLETE_SINCE": selected["completeSince"],
                "PIPELINE_KEY_PREFIX": selected.get("keyPrefix", "96bulls"), "PIPELINE_ORG_FROM_PREFIX": "true",
                "SESSION_POSTGRES_TLS_PROFILE": "custom-ca", "SESSION_POSTGRES_CA_SHA256": tls["caSha256"],
                "SESSION_POSTGRES_CA_FILE": "/etc/search-indexer-postgres/ca.crt",
                "NODE_EXTRA_CA_CERTS": "/etc/search-indexer-postgres/ca.crt",
                "LOCKER_ENDPOINT": "http://locker:9000", "LOCKER_BUCKET": locker["bucket"]}
    pod = pod_spec(doc)
    ca = {"name": "postgres-ca", "configMap": {"name": tls["caConfigMap"],
          "items": [{"key": tls.get("caKey", "ca.crt"), "path": "ca.crt"}]}}
    if not any(subset(ca, volume) for volume in pod.get("volumes", [])):
        return False
    for container in pod.get("containers", []):
        entries = container.get("env", [])
        env = {e["name"]: e.get("value") for e in entries}
        if (len(env) != len(entries) or not all(env.get(k) == v for k, v in contract.items())
                # The actual consumer defaults to off and refuses other fanout.
                or env.get("PIPELINE_FANOUT") not in (None, "off")
                or container.get("command") or container.get("args")
                or not re.fullmatch(r"[^@\s]+@sha256:[a-f0-9]{64}", container.get("image", ""))):
            continue
        if (not any(e.get("name") == "RELAYHISTORY_PIPELINE_CONSUMER_SECRET"
                    and e.get("valueFrom") == {"secretKeyRef": runtime} for e in entries)
                or not all(container.get(probe, {}).get("httpGet") == {"path": "/readyz", "port": "health"}
                           for probe in ("startupProbe", "readinessProbe"))
                or not any(subset({"name": "postgres-ca", "mountPath": "/etc/search-indexer-postgres", "readOnly": True}, mount)
                           for mount in container.get("volumeMounts", []))):
            continue
        return True
    return False


def verify_selection(stack, values, objects):
    from stack import pod_spec
    values_validate(values, stack.profile)
    reject_legacy_workloads(objects)
    pipeline = values["sessions-pipeline"]
    worker = pipeline.get("worker", {})
    indexer = worker.get("components", {}).get("hoopdb-indexer", {})
    native = pipeline.get("nativeConsumer", {})
    selected_consumer = isinstance(native, dict) and native.get("enabled") is True
    search = pipeline.get("searchIndexer", {})
    selected_search = isinstance(search, dict) and search.get("enabled") is True
    indexer_disabled = isinstance(indexer, dict) and indexer.get("enabled") is False
    if selected_consumer or selected_search or indexer_disabled:
        drained = (native.get("legacyIndexerDrained") if selected_consumer
                   else values["localKind"].get("legacyIndexerDrained"))
        if selected_consumer == selected_search or not indexer_disabled or drained is not True:
            fail("disabled legacy indexer requires an explicitly selected, drained native replacement")
    rendered = render_selected(stack, values)
    names = {d["metadata"]["name"] for d in rendered if d["kind"] == "Deployment"}
    if not REQUIRED_BASE <= names or names & OLD or ("Deployment", NAME) not in objects:
        fail("render does not select the completed public workload names")
    if selected_consumer or selected_search or indexer_disabled:
        contract = {"SERVICE": "session-pipeline-consumer", "RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER": "true",
                    "SEARCH_INDEX_BACKEND": "postgres", "PIPELINE_FANOUT": "off",
                    "NATIVE_CONSUMER_PREFLIGHT_MODE": "runtime", "NATIVE_CONSUMER_EXPECTED_ROLE": "search_consumer_runtime"}
        replacements = []
        for doc in rendered:
            if selected_search:
                if current_search_writer(doc, search):
                    replacements.append(doc["metadata"]["name"])
                continue
            if doc["kind"] != "Deployment":
                continue
            if doc["metadata"].get("labels", {}).get("app.kubernetes.io/name") != "session-pipeline-consumer":
                continue
            for container in pod_spec(doc).get("containers", []):
                env = {e["name"]: e.get("value") for e in container.get("env", [])}
                if all(env.get(k) == v for k, v in contract.items()):
                    replacements.append(doc["metadata"]["name"])
        if len(replacements) != 1:
            fail("selected native indexer replacement has no single rendered runtime Deployment")
        previous_name = indexer.get("fullnameOverride") or "session-metadata-indexer"
        for (kind, name), doc in objects.items():
            if kind != "Deployment":
                continue
            services = {e.get("value") for c in pod_spec(doc).get("containers", [])
                        for e in c.get("env", []) if e.get("name") == "SERVICE"}
            if name == previous_name or "hoopdb-indexer" in services:
                fail("old metadata indexer is still present beside the native replacement")
    for doc in rendered:
        if doc["kind"] != "Deployment":
            continue
        actual = objects.get(("Deployment", doc["metadata"]["name"]))
        if actual is None or actual.get("status", {}).get("readyReplicas", 0) < doc["spec"].get("replicas", 1):
            fail("selected application Deployment is missing or unready")
        if (not subset(doc["spec"]["selector"], actual["spec"]["selector"])
                or not subset(pod_spec(doc), pod_spec(actual))):
            fail("installed application configuration differs from the selected render")
    return rendered


def verify_control_cache(stack, receipt):
    """The next up exports this tag, so prove that export before changing state."""
    from control import inspect_archive
    temporary = stack.state / ("naming-control-" + secrets.token_hex(8) + ".tar")
    try:
        exported = stack.cmd([*stack.docker_args, "image", "save", "--platform", f"linux/{stack.arch}",
                              "-o", temporary, receipt["tag"]], check=False, timeout=300)
        if exported.returncode:
            fail("local Control tag is unavailable; restore the verified archive before reconciliation")
        if inspect_archive(temporary, stack.arch) != receipt:
            fail("local Control tag differs from the verified archive; restore it before reconciliation")
    finally:
        temporary.unlink(missing_ok=True)


def reconcile(stack, proof_path, control_archive=None, readiness_anchor=None):
    """Import a completed cutover as explicit local state, never as acceptance."""
    from control import REPOSITORY, inspect_archive, select_local_entrypoints
    from stack import pod_spec
    stack.docker(require_space=False)
    stack.require_owned_cluster()
    ownership = read(stack.marker)
    ready_path = stack.state / "ready.json"
    ready_source = Path(readiness_anchor).resolve() if readiness_anchor else ready_path
    if readiness_anchor and (not ready_source.is_relative_to(stack.state.resolve())
            or ready_source.name != "ready.json"
            or not re.fullmatch(r"named-history-[a-f0-9]{16}", ready_source.parent.name)
            or ready_source.is_symlink() or ready_source.parent.is_symlink()):
        fail("explicit readiness anchor must be this profile's preserved naming history")
    ready_bytes = ready_source.read_bytes()
    ready = read(ready_source)
    if (not isinstance(ready, dict) or ready.get("profile") != stack.profile or ready.get("clusterUid") != ownership.get("clusterUid")
            or any(not isinstance(ready.get(k), str) or not SHA.fullmatch(ready[k]) for k in ("recipeSha256", "renderSha256"))):
        fail("original readiness does not anchor this owned profile")
    original = {name: (stack.state / name).read_bytes() if (stack.state / name).exists() else None
                for name in ("ready.json", "images.json", "control-build.json", "values.json", "rendered.yaml", "proof.json", RECORD)}
    proof_path = Path(proof_path).resolve()
    if not proof_path.is_file() or not proof_path.is_relative_to((stack.root / ".kind").resolve()):
        fail("cutover proof must be an existing private artifact in this checkout")
    packet = proof_path.parent
    proof = read(proof_path)
    seeds = completed_proof(proof, read(packet / "before-inventory-normalized-private.json"),
                            read(packet / "after-inventory-normalized-private.json"))
    review = read(packet / "render-review-receipt.json")
    storage_values = read(packet / "values-before.json")
    if (not isinstance(review, dict) or review.get("result") != "PASS" or review.get("release") != RELEASE
            or review.get("chart") != "minio-5.4.0"
            or review.get("onlyChangedFields") != ["Deployment.metadata.name", "Deployment.spec.template.metadata.name"]
            or review.get("valuesSha256") != sha_file(packet / "values-before.json")
            or review.get("chartSha256") != sha_file(packet / "minio-5.4.0.tgz")
            or review.get("rendererSha256") != sha_file(packet / "plugins/storage-public-name/post-render-storage-name.py")
            or review.get("rendererSha256") != sha_file(stack.root / "ci/agent-relay/kind/storage-name-renderer/postrender.py")):
        fail("cutover did not qualify the same chart, values and PVC-preserving transform")
    objects = live_objects(stack)
    reject_legacy_workloads(objects)
    storage = storage_snapshot(stack, objects)
    if (storage["PersistentVolumeClaim/locker"]["uid"] != proof["pvcUid"]
            or storage["Deployment/" + NAME]["uid"] != proof["newDeploymentUid"]):
        fail("cutover proof belongs to different live storage identities")
    postgres = postgres_snapshot(objects)
    release, installed_storage_values, storage_manifest = live_release(stack, RELEASE)
    if release.get("chart") != "minio-5.4.0" or installed_storage_values != storage_values:
        fail("current storage release is not the one qualified by the cutover")
    # It must keep rendering exactly the original PVC and only the new storage
    # Deployment. Never accept an existingClaim switch that would prune it.
    manifest_names = {(d["kind"], d["metadata"]["name"]) for d in storage_manifest}
    if (manifest_names != {("ServiceAccount", "minio-sa"), ("ConfigMap", "locker"),
                          ("PersistentVolumeClaim", "locker"), ("Service", "locker"),
                          ("Service", "locker-console"), ("Deployment", NAME)}):
        fail("storage release manifest does not retain the original rendered claim")
    _, values, _ = live_release(stack, "agent-relay")
    stack.dependencies()
    rendered = verify_selection(stack, values, objects)
    control = next(d for d in rendered if d["kind"] == "Deployment" and d["metadata"]["name"] == "relay-control")
    image = pod_spec(control)["containers"][0]["image"]
    control_receipt = None
    if image.startswith(REPOSITORY + "@"):
        if not control_archive:
            fail("local Control selection requires its native OCI archive, not an old build receipt")
        control_receipt = inspect_archive(Path(control_archive), stack.arch)
        if control_receipt["reference"] != image:
            fail("Control archive does not match the installed selected image")
        paired = json.loads(json.dumps(values))
        select_local_entrypoints(paired, control_receipt["sourceRevision"])
        if paired != values:
            fail("Control image and API/migration entrypoints are not paired")
    elif control_archive:
        fail("a Control archive cannot qualify a different registry image")
    source_chart = stack.root / "charts/sessions-pipeline/charts/minio-5.4.0.tgz"
    if sha_file(source_chart) != review["chartSha256"]:
        fail("current source dependency differs from the qualified storage chart")
    record = {"version": 1, "type": "local-kind-named-layout", "name": stack.name,
              "profile": stack.profile, "clusterUid": ownership["clusterUid"], "dockerHost": stack.env["DOCKER_HOST"],
              "cutoverProofSha256": sha_file(proof_path), "storage": storage, "postgres": postgres,
              "privateState": private_state(stack), "postgresSecrets": postgres_secret_snapshot(stack, objects),
              "seedObjects": seeds, "sentinelKey": proof["sentinelKey"], "sentinelSha256": proof["sentinelSha256"],
              "storageValues": storage_values, "storageValuesSha256": digest(storage_values),
              "storageChartSha256": review["chartSha256"], "storageManifestSha256": digest(storage_manifest),
              "storageRendererSha256": review["rendererSha256"],
              "activeValuesSha256": digest(values), "controlBuildSha256": None}
    verify_seeded_readback(stack, record)
    verify_credentials(stack)
    verify_tls(stack)
    if control_receipt is not None:
        verify_control_cache(stack, control_receipt)
    # Check again before committing local metadata. A concurrent rollout must
    # produce a refusal, not a receipt assembled from incompatible snapshots.
    current = live_objects(stack)
    if storage_snapshot(stack, current) != storage or postgres_snapshot(current) != postgres:
        fail("live storage/Postgres changed during reconciliation")
    verify_selection(stack, values, current)
    if ready_source.read_bytes() != ready_bytes:
        fail("readiness changed during reconciliation")
    for name, before in original.items():
        path = stack.state / name
        if (path.read_bytes() if path.exists() else None) != before:
            fail("active local state changed during reconciliation")
    if live_release(stack, "agent-relay")[1] != values:
        fail("installed application selection changed during reconciliation")
    history = stack.state / ("named-history-" + secrets.token_hex(8))
    history.mkdir(mode=0o700)
    for name, data in original.items():
        if data is not None:
            path = history / name
            path.write_bytes(data)
            path.chmod(0o600)
    if original["ready.json"] is None:
        path = history / "ready.json"
        path.write_bytes(ready_bytes)
        path.chmod(0o600)
    record["history"] = history.name
    record["readyAnchorSha256"] = sha_file(history / "ready.json")
    try:
        write(stack.overrides, values)
        if control_receipt is not None:
            write(stack.state / "control-build.json", control_receipt)
            record["controlBuildSha256"] = sha_file(stack.state / "control-build.json")
        else:
            (stack.state / "control-build.json").unlink(missing_ok=True)
        # These describe the previous recipe. Leave its historical proof
        # untouched; require a complete new up/proof for the current selection.
        (stack.state / "images.json").unlink(missing_ok=True)
        ready_path.unlink(missing_ok=True)
        write(stack.state / RECORD, record)
    except BaseException:
        for name in ("ready.json", "images.json", "control-build.json", "values.json", RECORD):
            path = stack.state / name
            if original[name] is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(original[name])
                path.chmod(0o600)
        raise
    print("Selected the verified named layout; original readiness/images/build/values retained privately at " + str(history))
    print("No cluster resource changed and no acceptance result was issued. Run kind-up, then a fresh kind-proof.")
