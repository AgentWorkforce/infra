"""Native kind phase boundary. No command runs when this module is imported.

The adapter is deliberately injected: the legacy Stack.up adapter must not be
used until it implements every operation below. The same plan serves core and
addons; selected optional workloads are a separate proof phase after native core.
"""
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
import re
import subprocess


class NativeRecipeError(ValueError):
    pass


ROLES = {
    "owner": "hoop",
    "runtime": "sessions_pipeline_runtime",
    "ingest": "bulls96_session_ingest",
    "reader": "bulls96_read_api",
    "consumer": "search_consumer_runtime",
}
BOOTSTRAP = (
    "session_directory_search_worker.sql", "session_token_verifier.sql",
    "session_ingest_roles.sql", "session_read_api_roles.sql",
    "session_consumer_roles.sql", "hoopdb_runtime_role.sql",
    "hoopdb_function_default_revoke.sql", "session_consumer_credential_probe.sql",
    "session_ingest_role.sql", "session_ingest_role_verify.sql", "session_ingest_verify.sql",
    "session_read_api_role.sql", "session_read_api_role_verify.sql",
    "session_consumer_role.sql", "session_consumer_role_verify.sql",
)
SECRET_KEYS = {
    "owner": ("consumer-json", "hoopdb_url"),
    "consumer": ("consumer-json", "hoopdb_url"),
    "reader": ("reader-json", "supabase_url"),
    "ingest": ("database-url", None),
    "introspection": ("introspect-secret", None),
    "readerIssuer": ("internal-secret", None),
    "locker": ("rootPassword", None),
}
CORE_OPERATIONS = (
    "inspect", "verify_artifact", "render", "prepare_infrastructure",
    "verify_infrastructure", "install_control", "verify_control",
    "prepare_owner", "schema_plan", "schema_apply", "schema_noop",
    "consumer_prepare", "post_roles", "finalize_owner", "verify_owner_final",
    "verify_claimed_roles", "initial_credentials", "verify_credentials",
    "serve", "verify_ready", "record_ready",
)
PHASE_FAILURE_CODES = frozenset({"command_failed", "command_timeout", "transport_failure", "invalid_response", "unexpected_failure"})


class NativePhaseError(NativeRecipeError):
    """Only closed phase/code/command details cross the public error boundary."""
    def __init__(self, phase, code, details=None):
        if type(phase) is not str or type(code) is not str or phase not in (*CORE_OPERATIONS, "addons") or code not in PHASE_FAILURE_CODES:
            raise NativeRecipeError("invalid_native_phase_diagnostic")
        self.phase = phase
        self.code = code
        from native_diagnostics import validate_details
        self.details = validate_details(details)
        # Existing callers that emit only a safe ValueError string also retain
        # the phase, without reading or printing the underlying exception.
        super().__init__("native_phase_" + phase + "_" + code)


def phase_operation(name, operation, *args):
    try:
        return operation(*args)
    except NativeRecipeError:
        raise
    except Exception as error:
        from stack import StackError
        details = None
        if isinstance(error, StackError):
            code = error.safe_code
            from native_diagnostics import validate_details
            try:
                details = validate_details(error.safe_details)
            except (ValueError, AttributeError):
                details = None
        elif isinstance(error, (subprocess.TimeoutExpired, TimeoutError)):
            code = "command_timeout"
        elif isinstance(error, subprocess.CalledProcessError):
            code = "command_failed"
        elif isinstance(error, json.JSONDecodeError):
            code = "invalid_response"
        else:
            code = "unexpected_failure"
        raise NativePhaseError(name, code, details) from None
SELECTION_FIELDS = {"profile", "sourceRevision", "manifestDigest", "configDigest", "reference", "architecture", "generation",
                    "artifactReceiptSha256", "sourceClean", "control", "acceptedSource", "officialBootstrapSha256", "roles",
                    "postgres", "postgresCa", "secretRefs", "keyRoot", "orgFromPrefix", "backend", "backendId", "completeSince",
                    "siteOrigin", "historyOrigin", "publication", "gc", "ownerBuffered", "readerLoginAdvertisesSync", "lockerBucket", "lockerClaim"}
CONTROL_FIELDS = {"sourceRevision", "manifestDigest", "configDigest", "reference", "artifactReceiptSha256", "nativeEvents", "independentIssuer"}
RECEIPT_FIELDS = {
    "prepare_infrastructure": {"clusterUid", "postgresPvcUid", "objectStoragePvcUid", "caSha256"},
    "verify_infrastructure": {"clusterUid", "postgresPvcUid", "objectStoragePvcUid", "caSha256"},
    "install_control": {"workspaceId", "organizationId", "sourceRevision", "configDigest", "jobName"},
    "verify_control": {"workspaceId", "organizationId", "sourceRevision", "configDigest"},
    "prepare_owner": {"ownerOid", "consumerOid"},
    "schema_plan": {"pending", "physicalLedgerSha256", "planSha256", "generation"},
    "schema_apply": {"applied", "skipped", "planSha256", "generation", "jobName"},
    "schema_noop": {"applied", "skipped", "generation", "jobName"},
    "consumer_prepare": {"jobName", "sourceRevision", "consumerOid"},
    "post_roles": {"roleOids"}, "finalize_owner": {"ownerOid", "ownerNoCreateRole"},
    "verify_owner_final": {"ownerOid", "ownerNoCreateRole"}, "verify_claimed_roles": {"roleOids"},
    "initial_credentials": {"secretUids", "roleOids"}, "verify_credentials": {"secretUids", "roleOids"},
    "serve": {"releaseRevision", "renderSha256"}, "verify_ready": {"deploymentUids"},
    "addons": {"capabilitiesVerified", "workloadsVerified", "apiVerified", "uiVerified", "featureModes"}, "record_ready": {"receiptSha256"},
}


def require(condition, code):
    if not condition:
        raise NativeRecipeError(code)


def digest(value, code="invalid_digest"):
    require(isinstance(value, str) and re.fullmatch(r"[a-f0-9]{64}", value), code)
    return value


def exact_keys(value, keys, code):
    require(isinstance(value, dict) and set(value) == set(keys), code)


def phase_receipt(name, receipt):
    require(isinstance(receipt, dict) and receipt.get("ok") is True and
            set(receipt) <= RECEIPT_FIELDS[name] | {"ok"}, "unexpected_phase_receipt_fields:" + name)
    nonsecret(receipt)
    for key, value in receipt.items():
        if key == "ok":
            continue
        if key in {"roleOids", "secretUids", "deploymentUids"}:
            require(isinstance(value, dict), "invalid_identity_receipt")
            allowed = set(ROLES.values()) if key == "roleOids" else (set(SECRET_KEYS) if key == "secretUids" else
                       {"relay-control", "relay-webapp", "session-native-ingest", "session-native-consumer", "session-read-api"})
            require(set(value) <= allowed, "unexpected_identity_receipt_fields")
            for identity in value.values():
                require(type(identity) is int and identity > 0 if key == "roleOids" else
                        isinstance(identity, str) and re.fullmatch(r"[a-f0-9-]{8,64}", identity), "invalid_identity_receipt_value")
        elif key == "featureModes":
            require(isinstance(value, dict) and set(value) <= {"flows", "relayfile", "chief"} and
                    all(v in {"disabled", "enabled"} for v in value.values()), "invalid_feature_mode_receipt")
        elif key in {"ownerNoCreateRole", "capabilitiesVerified", "workloadsVerified", "apiVerified", "uiVerified"}:
            require(type(value) is bool, "invalid_boolean_receipt")
        elif key in {"pending", "applied", "skipped", "releaseRevision", "ownerOid", "consumerOid"}:
            require(type(value) is int and value >= 0, "invalid_integer_receipt")
        elif key == "sourceRevision":
            require(isinstance(value, str) and re.fullmatch(r"[a-f0-9]{40}", value), "invalid_source_receipt")
        elif key == "configDigest":
            require(isinstance(value, str) and re.fullmatch(r"sha256:[a-f0-9]{64}", value), "invalid_config_receipt")
        elif key.endswith("Sha256") or key == "generation":
            digest(value, "invalid_digest_receipt")
        elif key.endswith("Uid") or key in {"workspaceId", "organizationId"}:
            require(isinstance(value, str) and re.fullmatch(r"[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}", value),
                    "invalid_resource_identity_receipt")
        else:
            require(key == "jobName" and isinstance(value, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", value), "invalid_named_identity_receipt")
    if name == "addons":
        require(all(receipt.get(k) is True for k in ("capabilitiesVerified", "workloadsVerified", "apiVerified", "uiVerified")) and
                receipt.get("featureModes", {}).get("flows") == "enabled" and
                receipt.get("featureModes", {}).get("relayfile") == "enabled", "addons_selected_workload_api_ui_proof_required")
    return receipt


def selection(raw, *, target=None):
    """Validate non-secret references and exact reviewed inputs before any I/O."""
    v = deepcopy(raw)
    exact_keys(v, SELECTION_FIELDS, "unexpected_selection_fields")
    nonsecret(v)
    require(v.get("profile") in ("core", "addons"), "invalid_profile")
    require(re.fullmatch(r"[a-f0-9]{40}", v.get("sourceRevision", "")), "invalid_source")
    for k in ("manifestDigest", "configDigest"):
        require(re.fullmatch(r"sha256:[a-f0-9]{64}", v.get(k, "")), "invalid_" + k)
    require(v.get("reference", "").endswith("@" + v["manifestDigest"]), "image_reference_mismatch")
    require(v.get("architecture") in ("arm64", "amd64"), "invalid_architecture")
    digest(v.get("generation"), "invalid_generation")
    digest(v.get("artifactReceiptSha256"), "artifact_receipt_required")
    require(v.get("sourceClean") is True, "clean_source_required")
    control = v.get("control", {})
    exact_keys(control, CONTROL_FIELDS, "unexpected_control_selection_fields")
    require(re.fullmatch(r"[a-f0-9]{40}", control.get("sourceRevision", "")) and
            re.fullmatch(r"sha256:[a-f0-9]{64}", control.get("manifestDigest", "")) and
            re.fullmatch(r"sha256:[a-f0-9]{64}", control.get("configDigest", "")) and
            control.get("reference", "").endswith("@" + control.get("manifestDigest", "invalid")) and
            control.get("nativeEvents") is True and type(control.get("independentIssuer")) is bool,
            "qualified_control_native_readback_required")
    digest(control.get("artifactReceiptSha256"), "qualified_control_receipt_required")
    accepted = v.get("acceptedSource", {})
    exact_keys(accepted, {"revision", "scope", "accepted", "bootstrapSha256"}, "unexpected_accepted_source_fields")
    require(accepted.get("revision") == v["sourceRevision"] and
            accepted.get("scope") == "native-kind" and accepted.get("accepted") is True,
            "accepted_native_source_required")
    # This is module acceptance, not a PR-number inference or a boolean knob in
    # extraEnv. The adapter must compare every hash with the qualified image.
    files = v.get("officialBootstrapSha256", {})
    exact_keys(files, BOOTSTRAP, "unexpected_official_bootstrap_set")
    exact_keys(accepted["bootstrapSha256"], BOOTSTRAP, "unexpected_accepted_bootstrap_set")
    for f in BOOTSTRAP:
        digest(files.get(f), "accepted_official_bootstrap_required:" + f)
    require(accepted.get("bootstrapSha256") == files, "accepted_bootstrap_binding_mismatch")
    require(v.get("roles") == ROLES, "native_role_binding_mismatch")
    # Cast's separate database name is a topology reservation. Its currently
    # selected SQLite runtime still needs independent PostgreSQL acceptance.
    require(v.get("postgres") == {
        "host": "postgres.agent-relay.svc.cluster.local", "port": 5432,
        "pipelineDatabase": "hoopdb", "controlDatabase": "relaycontrol",
        "fileDatabase": "relayfile", "castDatabase": "relaycast",
        "tls": "verify-full",
    }, "separate_service_database_tls_binding_required")
    ca = v.get("postgresCa", {})
    exact_keys(ca, {"sha256", "configMap", "key", "immutable"}, "unexpected_ca_fields")
    digest(ca.get("sha256"), "postgres_ca_required")
    require(isinstance(ca.get("configMap"), str) and ca["configMap"] and
            ca.get("key") == "ca.crt" and ca.get("immutable") is True,
            "immutable_public_ca_reference_required")
    refs = v.get("secretRefs", {})
    exact_keys(refs, SECRET_KEYS, "unexpected_secret_reference_set")
    for name, (key, field) in SECRET_KEYS.items():
        ref = refs.get(name, {})
        require(set(ref) == {"name", "key", "jsonField"} and
                isinstance(ref["name"], str) and re.fullmatch(r"[a-z0-9][a-z0-9-]*", ref["name"]) and
                ref["key"] == key and ref["jsonField"] == field,
                "managed_secret_reference_required:" + name)
    require(len({refs[n]["name"] for n in ("owner", "consumer", "reader", "ingest")}) == 4,
            "owner_and_runtime_secrets_must_be_distinct")
    require(v.get("keyRoot") == "96bulls" and v.get("orgFromPrefix") is True,
            "bare_canonical_root_required")
    require(isinstance(v.get("lockerBucket"), str) and re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", v["lockerBucket"]) and
            isinstance(v.get("lockerClaim"), str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", v["lockerClaim"]),
            "explicit_locker_bucket_claim_required")
    require(type(v.get("readerLoginAdvertisesSync")) is bool and
            v["readerLoginAdvertisesSync"] is (not control["independentIssuer"]),
            "reader_discovery_must_match_selected_authority")
    require(len({refs[n]["name"] for n in SECRET_KEYS}) == len(SECRET_KEYS),
            "distinct_native_authority_and_database_secrets_required")
    if target is not None:
        from native_target import NativeInstanceTarget
        require(type(target) is NativeInstanceTarget and v["profile"] == "core" and
                control["independentIssuer"] is True, "native_target_core_independent_issuer_required")
    history_origin = target.history_origin if target is not None else "https://history.kind.agentrelay.com:8443"
    require(v.get("historyOrigin") == history_origin and
            v.get("siteOrigin") == "https://relay.kind.agentrelay.com", "origin_audience_binding_required")
    require(v.get("backend") == "postgres" and isinstance(v.get("backendId"), str) and
            re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", v["backendId"]), "explicit_backend_required")
    # Epoch is the upstream explicit new-store contract. Existing stores may
    # use a prospective ISO floor, but repeat admission binds the exact prior
    # selection and cannot lower it merely by choosing epoch.
    if v.get("completeSince") != "epoch":
        require(re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z", v.get("completeSince", "")),
                "explicit_coverage_floor_required")
        try:
            floor = datetime.fromisoformat(v["completeSince"].replace("Z", "+00:00"))
        except ValueError:
            raise NativeRecipeError("invalid_coverage_floor_date") from None
        require(floor <= datetime.now(timezone.utc), "future_coverage_floor_refused")
    require(v.get("publication") is False and v.get("gc") is False and
            v.get("ownerBuffered") is False, "unsupported_owner_ceremonies_must_stay_off")
    return v


def native_selected(values):
    """Recognize managed native selection, including an incomplete prepare phase."""
    pipeline = values.get("sessions-pipeline", {})
    if not isinstance(pipeline, dict):
        raise NativeRecipeError("pipeline_values_must_be_object")
    enabled = False
    for key in ("nativeConsumer", "readApi", "sessionReadApi", "ingestEdge", "nativeRouting"):
        part = pipeline.get(key, {})
        require(isinstance(part, dict), "native_values_must_be_object")
        require("enabled" not in part or type(part["enabled"]) is bool, "native_enabled_must_be_boolean")
        if part.get("enabled") is True:
            enabled = True
    return enabled


def nonsecret(value):
    if isinstance(value, dict):
        require(not set(value).intersection({"password", "token", "stringData", "secretValue", "rawUrl", "dsn", "credentials"}),
                "credential_values_not_allowed_in_recipe_or_receipts")
        for child in value.values():
            nonsecret(child)
    elif isinstance(value, list):
        for child in value:
            nonsecret(child)
    elif isinstance(value, str):
        require(not re.search(r"(?:postgres(?:ql)?://[^\s/@]+:[^\s/@]+@|\bsh_at_[A-Za-z0-9_-]+)", value),
                "credential_values_not_allowed_in_recipe_or_receipts")


def refuse_legacy_up(values):
    """Call before ready unlink, image preparation or any PostgreSQL operation."""
    if native_selected(values):
        raise NativeRecipeError("native_selected_requires_native_orchestrator_before_any_mutation")


def merge_values(*values):
    """Helm-style object overlay for the early read-only recipe guard only."""
    result = {}

    def merge(a, b):
        require(isinstance(b, dict), "values_must_be_object")
        for key, value in b.items():
            if value is None:
                a.pop(key, None)
            elif isinstance(value, dict) and isinstance(a.get(key), dict):
                merge(a[key], value)
            else:
                a[key] = deepcopy(value)
    for value in values:
        merge(result, value)
    return result


def official_sql(image_files, selected, name):
    """Expand only qualified source includes; no arbitrary path or SQL substitution."""
    require(name in BOOTSTRAP, "unknown_official_bootstrap")
    seen = set()

    def expand(n):
        require(n in BOOTSTRAP and n not in seen, "unqualified_or_cyclic_sql_include")
        raw = image_files.get(n)
        require(isinstance(raw, bytes), "official_sql_bytes_missing")
        require(hashlib.sha256(raw).hexdigest() == selected["officialBootstrapSha256"][n], "official_sql_bytes_changed")
        seen.add(n)
        out = []
        for line in raw.decode().splitlines():
            m = re.fullmatch(r"\s*\\ir\s+([a-z0-9_]+\.sql)\s*", line)
            if m:
                out.append(expand(m.group(1)))
            else:
                require(not re.match(r"\s*\\i[r]?\s+", line), "unqualified_sql_include")
                out.append(line)
        seen.remove(n)
        return "\n".join(out) + "\n"

    return expand(name)


class NativeRecipe:
    """Executable phase orchestration over a complete, dependency-injected adapter.

    The adapter owns Kubernetes/SQL transport, verifies actual facts and returns
    credential-free receipts. Merely rendering this plan never claims runtime
    acceptance. No fallback into legacy Stack.up is permitted.
    """
    def __init__(self, raw, *, target=None):
        self.selected = selection(raw, target=target)
        self._target = target
        self._target_binding = target.binding() if target is not None else None

    def run(self, operations):
        if self._target_binding is not None:
            from native_target import binding
            require(self._target.binding() == self._target_binding and
                    binding(getattr(operations, "stack", None)) == self._target_binding,
                    "native_recipe_target_adapter_mismatch")
        s = self.selected
        names = CORE_OPERATIONS + (("addons",) if s["profile"] == "addons" else ())
        require(all(callable(getattr(operations, n, None)) for n in names), "complete_native_adapter_required")
        # All three are read-only. Fail before infrastructure/credentials/ready
        # changes if ownership, image modules, TLS inputs or rendered writers drift.
        facts = phase_operation("inspect", operations.inspect, s)
        require(isinstance(facts, dict) and set(facts) <= {"owned", "mode", "clusterUid", "foreignWriters", "boundResourceCount"},
                "unexpected_inspection_receipt_fields")
        nonsecret(facts)
        require(facts.get("owned") is True and facts.get("mode") in ("fresh", "repeat"), "owned_fresh_or_repeat_target_required")
        require(facts.get("foreignWriters") == [], "foreign_or_legacy_writer_requires_review")
        chain = phase_operation("verify_artifact", operations.verify_artifact, s)
        exact_keys(chain, {"sourceRevision", "manifestDigest", "configDigest", "generation", "officialBootstrapSha256", "control"},
                   "unexpected_artifact_receipt_fields")
        require(all(chain.get(k) == s[k] for k in ("sourceRevision", "manifestDigest", "configDigest", "generation")),
                "verified_artifact_chain_mismatch")
        require(chain.get("officialBootstrapSha256") == s["officialBootstrapSha256"], "verified_bootstrap_chain_mismatch")
        require(chain.get("control") == s["control"], "verified_control_chain_mismatch")
        rendered = phase_operation("render", operations.render, s)
        exact_keys(rendered, {"legacyWriterCount", "managedNative", "ownerBuffered", "publication", "readerLoginAdvertisesSync"},
                   "unexpected_render_receipt_fields")
        require(rendered.get("legacyWriterCount") == 0 and rendered.get("managedNative") is True and
                rendered.get("ownerBuffered") is False and rendered.get("publication") is False and
                rendered.get("readerLoginAdvertisesSync") is s["readerLoginAdvertisesSync"],
                "rendered_native_contract_refused")
        results = []

        def call(name, *args):
            receipt = phase_operation(name, getattr(operations, name), s, *args)
            require(isinstance(receipt, dict) and receipt.get("ok") is True, "phase_refused:" + name)
            phase_receipt(name, receipt)
            results.append({"phase": name, "receipt": receipt})
            return receipt

        if facts["mode"] == "fresh":
            # Infrastructure must create one strict-TLS server, separate service
            # databases and preserved object storage, never a plaintext interim.
            call("prepare_infrastructure", facts)
            tenant = call("install_control")
            require(tenant.get("workspaceId") and tenant.get("organizationId"), "real_control_tenant_required")
            # prepare_owner is the only explicit temporary CREATEROLE boundary.
            # A partial failure must also finalize; adapter records uncertainty
            # and does not auto-reset credentials or resume legacy writers.
            try:
                call("prepare_owner")
                plan = call("schema_plan")
                digest(plan.get("physicalLedgerSha256"), "raw_physical_ledger_binding_required")
                digest(plan.get("planSha256"), "saved_schema_plan_binding_required")
                call("schema_apply", plan)
                call("schema_noop")
                # Official399 helper and managed bootstrap Job run while the
                # exact owner is CREATEROLE. Then official post-schema grants.
                call("consumer_prepare")
                call("post_roles")
            finally:
                call("finalize_owner")
            call("verify_owner_final")
            call("initial_credentials")
        else:
            # Repeat-up never calls the one-shot installer, grants CREATEROLE,
            # rotates credentials, rewrites TLS, or requeues a bootstrap Job.
            call("verify_infrastructure", facts)
            call("verify_control")
            plan = call("schema_plan")
            require(plan.get("pending") == 0, "pending_schema_requires_explicit_native_operator_upgrade")
            digest(plan.get("physicalLedgerSha256"), "raw_physical_ledger_binding_required")
            digest(plan.get("planSha256"), "saved_schema_plan_binding_required")
            call("schema_noop")
            call("verify_claimed_roles")
            call("verify_owner_final")
        call("verify_credentials")
        call("serve", {"bootstrapEnabled": False, "phase": "serve"})
        call("verify_ready")
        if s["profile"] == "addons":
            call("addons")
        # Readiness is not an upload/UI acceptance claim. The separate
        # proof driver must use real supported login and actual session readback.
        call("record_ready", {"clusterUid": facts.get("clusterUid"), "sourceRevision": s["sourceRevision"],
                              "generation": s["generation"], "pipelineScope": "native-canonical",
                              "fullAcceptance": False, "castPostgresBackendAccepted": False})
        return results
