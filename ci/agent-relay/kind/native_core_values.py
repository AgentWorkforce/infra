"""Pure first-boot/final values composition for the native core adapter.

The planning token is deliberately not a UUID and is never deployable. Only
Control's supported first-boot APIs may supply the real workspace allowlist.
No credential value, SQL or cluster operation belongs in this module.
"""
from copy import deepcopy
import re

from native_control import control_contract
from native_recipe import merge_values, nonsecret, require

PLANNING_WORKSPACE = "CONTROL_BOOTSTRAP_REQUIRED_DO_NOT_DEPLOY"


def tenant(value):
    require(isinstance(value, dict) and set(value) == {"organizationId", "workspaceId"} and
            all(isinstance(v, str) and re.fullmatch(
                r"[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}", v)
                for v in value.values()), "official_control_tenant_identity_required")
    return deepcopy(value)


def image(reference):
    repository, delimiter, digest = reference.rpartition("@")
    require(delimiter and repository and re.fullmatch(r"sha256:[a-f0-9]{64}", digest),
            "immutable_native_image_reference_required")
    if repository.startswith("agent-relay-kind/"):
        repository = "docker.io/" + repository
    return {"repository": repository, "digest": digest, "pullPolicy": "Never"}


def compose(base, selected, operator, phase, observed_tenant=None):
    """No implicit tenant, license or credential authority is inferred."""
    require(phase in {"plan", "control", "serve"}, "unknown_native_values_phase")
    nonsecret(base)
    operator = control_contract(operator)
    require(selected["control"]["independentIssuer"] is True and
            selected["readerLoginAdvertisesSync"] is False,
            "complete_native_core_requires_independent_reader_authority")
    # Add-ons need their own workload/API/UI proof transport. Never silently
    # turn them on merely because a profile or entitlement string names them.
    require(selected["profile"] == "core", "complete_native_addons_transport_required")
    require(not base.get("relay-control", {}).get("selectedFeatures"),
            "core_must_not_select_optional_workloads")
    require(base.get("relaycast", {}).get("runtime", {}).get("backend", "sqlite") == "sqlite",
            "native_cast_postgres_transport_requires_separate_qualification")
    require(not base.get("relay-control", {}).get("extraEnv") and
            not base.get("relay-control", {}).get("license", {}).get("existingSecret") and
            not base.get("relay-control", {}).get("services", {}).get("publicHostAliases"),
            "complete_native_core_requires_managed_control_values_without_obsolete_license")
    if phase == "serve":
        actual = tenant(observed_tenant)
    else:
        require(observed_tenant is None, "tenant_is_observed_only_after_control_bootstrap")
        actual = None
    runtime, owner, cast = (operator[n] for n in ("runtime", "owner", "cast"))
    private_reader = "http://session-read-api.agent-relay.svc.cluster.local"
    refs = selected["secretRefs"]
    result = merge_values(base, {
        "localKind": {"enabled": True, "allowLocalOnly": True, "profile": "core", "temporaryRelayauth": False, "nativePhase": "control" if phase == "control" else "serve"},
        "components": {k: k in ({"control", "relaycast"} if phase == "control" else
                                {"control", "relaycast", "sessionsPipeline", "webapp"})
                       for k in base.get("components", {})},
        "relay-control": {
            "fullnameOverride": "relay-control", "image": image(selected["control"]["reference"]),
            "existingSecret": runtime["name"], "selectedFeatures": [],
            "extraEnv": [],
            "publicUrl": selected["siteOrigin"], "dashboardUrl": selected["siteOrigin"],
            "database": {"runtimeRole": runtime["role"]}, "migrations": {"enabled": False},
            "server": {"command": ["node"], "args": ["node_modules/relay-control/dist/server.js"]},
            "encryption": {"keyId": runtime["encryptionKeyId"]},
            "secretKeys": {"databaseUrl": runtime["databaseKey"], "databaseMigrationsUrl": owner["key"],
                "bootstrapToken": runtime["bootstrapKey"], "encryptionKey": runtime["encryptionKey"],
                "relayauthApiKey": "", "internalToken": runtime["internalKey"],
                "relaycastInternalSecret": runtime["castInternalKey"],
                "introspectSecret": runtime["introspectionKey"], "sessionReadApiSecret": runtime["readerIssuerKey"]},
            "postgresCa": {"enabled": True, "configMap": selected["postgresCa"]["configMap"], "secret": "", "key": "ca.crt"},
            "introspection": {"audiences": [selected["historyOrigin"]]},
            "bootstrap": {"orgName": operator["organizationName"] if phase == "control" else "",
                "adminEmail": operator["administrator"]["email"] if phase == "control" else "",
                "adminName": operator["administrator"]["displayName"] if phase == "control" else "",
                "workspaceName": "Default" if phase == "control" else ""},
            "services": {"relayhistoryBackend": "native", "relayauthEnabled": False, "relayauthUrl": "",
                "relayhistoryReadApiUrl": "", "relayhistoryReadApiEvents": False, "relayhistoryHostAliases": [],
                "relayhistoryUrl": "", "sessionReadApiUrl": private_reader,
                "relayhistoryPublicUrl": "", "sessionReadApiPublicUrl": selected["historyOrigin"],
                "sessionReadApiMcpReads": True, "relaycastUrl": "http://relaycast.agent-relay.svc.cluster.local:8787",
                "relaycastPublicUrl": "https://cast.kind.agentrelay.com"}},
        "relaycast": {"existingSecret": cast["name"], "baseUrl": "https://cast.kind.agentrelay.com",
                      "secretKeys": {"internalSecret": cast["internalKey"], "bootstrapSecret": cast["bootstrapKey"]}},
        "relay-webapp": {"image": {"pullPolicy": "Never"}, "runtime": {"publicUrl": selected["siteOrigin"]},
            "customerProfile": {"desktop": {"siteUrl": selected["siteOrigin"]}}},
        "sessions-pipeline": {"sessionReadApi": {
            "fullnameOverride": "session-read-api", "replicas": 1, "image": image(selected["reference"]),
            "config": {"existingSecret": refs["reader"]["name"], "key": refs["reader"]["key"]},
            "origin": selected["historyOrigin"], "login": {"advertisesSync": False},
            "completeSince": selected["completeSince"], "search": {"backend": "postgres", "backendId": selected["backendId"]},
            "allowInClusterHttp": True, "postgres": {"tlsProfile": "custom-ca"},
            "postgresCa": {"enabled": True, "configMap": selected["postgresCa"]["configMap"], "secret": "",
                "key": selected["postgresCa"]["key"], "sha256": selected["postgresCa"]["sha256"]},
            "events": {"messageIds": True},
            "directoryWorkspaces": actual["workspaceId"] if actual else PLANNING_WORKSPACE,
            "auth": {"mode": "self_issued", "relaycontrol": {"enabled": False, "url": "", "existingSecret": ""},
                "selfIssued": {"internalSecret": {"existingSecret": refs["readerIssuer"]["name"], "key": refs["readerIssuer"]["key"]}}},
            "networkPolicy": {"enabled": True, "controlFrom": [{"podSelector": {"matchLabels": {
                "app.kubernetes.io/name": "relay-control", "app.kubernetes.io/instance": "agent-relay",
                "app.kubernetes.io/component": "api"}}}], "publicFrom": [{"namespaceSelector": {"matchLabels": {
                    "kubernetes.io/metadata.name": "kind-edge"}}}]}},
            "nativeConsumer": {"fullnameOverride": "session-native-consumer", "replicas": 1, "image": image(selected["reference"]),
                "legacyIndexerDrained": True, "migrationDriverVerified": True,
                "backendId": selected["backendId"], "completeSince": selected["completeSince"], "allowInClusterHttp": True,
                "config": {"existingSecret": refs["consumer"]["name"], "key": refs["consumer"]["key"]},
                "postgres": {"host": selected["postgres"]["host"], "database": "hoopdb",
                    "caConfigMap": selected["postgresCa"]["configMap"], "caKey": selected["postgresCa"]["key"],
                    "caSha256": selected["postgresCa"]["sha256"]},
                "locker": {"bucket": selected["lockerBucket"], "endpoint": "http://locker.agent-relay.svc.cluster.local:9000",
                    "existingSecret": refs["locker"]["name"], "secretAccessKeyKey": refs["locker"]["key"], "accessKeyIdKey": "rootUser"},
                "bootstrap": {"enabled": False}},
            "ingestEdge": {"fullnameOverride": "session-native-ingest", "image": image(selected["reference"]),
                "origin": selected["historyOrigin"], "allowInClusterHttp": True,
                "config": {"existingSecret": refs["ingest"]["name"], "databaseUrlKey": refs["ingest"]["key"], "introspectSecretKey": "introspect-secret"},
                "relaycontrol": {"url": "http://relay-control.agent-relay.svc.cluster.local"},
                "postgres": {"caConfigMap": selected["postgresCa"]["configMap"], "caKey": selected["postgresCa"]["key"],
                    "caSha256": selected["postgresCa"]["sha256"]},
                "locker": {"bucket": selected["lockerBucket"], "endpoint": "http://locker.agent-relay.svc.cluster.local:9000",
                    "existingSecret": refs["locker"]["name"], "secretAccessKeyKey": refs["locker"]["key"], "accessKeyIdKey": "rootUser"}},
            "nativeRouting": {"enabled": True, "origin": selected["historyOrigin"], "className": "traefik",
                              "tls": {"existingSecret": "kind-tls"}},
            "hoopdb": {"enabled": False}, "session-object-storage": {"enabled": False}, "otel": {"enabled": False},
            "alleyoop": {"ingest": {"replicas": 0}},
            # The control-only install is followed by a same-release upgrade.
            # Retain generic worker names; disabling them is not a drained
            # rename acknowledgement, and native workload names are separate.
            "worker": {"legacyResourceNames": True, "migrations": {"enabled": False}, "lockerInit": {"enabled": False}, "components": {
                "hoopdb-indexer": {"enabled": False}, "bob-costas": {"enabled": False}, "referee": {"enabled": False}}},
            "runtimeRole": {"bootstrapJob": {"enabled": False}}, "functionDefaultRevoke": {"bootstrapJob": {"enabled": False}}}})
    # Canonical object store credentials remain Secret references, including
    # the standalone reader's upstream extraEnv interface. Reserve all of
    # those names so caller data cannot create duplicate environment authority.
    reader = result["sessions-pipeline"]["sessionReadApi"]
    canonical_env = [
        {"name": "LOCKER_BUCKET", "value": selected["lockerBucket"]},
        {"name": "LOCKER_ENDPOINT", "value": "http://locker.agent-relay.svc.cluster.local:9000"},
        {"name": "LOCKER_REGION", "value": "us-east-1"},
        {"name": "LOCKER_ACCESS_KEY_ID", "valueFrom": {"secretKeyRef": {"name": refs["locker"]["name"], "key": "rootUser"}}},
        {"name": "LOCKER_SECRET_ACCESS_KEY", "valueFrom": {"secretKeyRef": {
            "name": refs["locker"]["name"], "key": refs["locker"]["key"]}}},
        {"name": "PIPELINE_KEY_PREFIX", "value": selected["keyRoot"]},
        {"name": "PIPELINE_ORG_FROM_PREFIX", "value": "true"}]
    reserved = {e["name"] for e in canonical_env}
    require(not any(e.get("name") in reserved for e in reader.get("extraEnv", [])),
            "native_canonical_env_must_be_managed_not_duplicated")
    reader["extraEnv"] = canonical_env + reader.get("extraEnv", [])
    # Missing component flags must not inherit chart defaults and accidentally
    # start RelayAuth, a legacy worker or an optional product. The standalone
    # History component was removed from the chart, so it is never named here.
    result["components"] = {k: k in ({"control", "relaycast"} if phase == "control" else
                                    {"control", "relaycast", "sessionsPipeline", "webapp"})
                            for k in ("control", "relaycast", "sessionsPipeline", "webapp", "relayauth",
                                      "relayflows", "relayfile", "durableActors", "telemetryCollector", "relayChief")}
    if phase == "control":
        result["sessions-pipeline"]["nativeRouting"] = {"enabled": False}
        for slot in ("sessionReadApi", "nativeConsumer", "ingestEdge"):
            result["sessions-pipeline"][slot]["enabled"] = False
    else:
        for slot in ("sessionReadApi", "nativeConsumer", "ingestEdge"):
            result["sessions-pipeline"][slot]["enabled"] = True
    nonsecret(result)
    if phase != "plan":
        # The control-only phase has no reader Deployment at all, so its
        # directory placeholder must never become a deployable native value.
        require(phase == "control" or PLANNING_WORKSPACE not in str(result), "planning_tenant_must_never_be_deployed")
    return result
