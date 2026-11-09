"""Explicit complete-core transport. Importing this module never deploys anything.

Caller supplies reviewed artifact paths, an explicit first administrator and
managed native values. No fallback into the legacy SQL/bootstrap path exists.
This transport deliberately refuses add-ons until their separate workload,
capability, API and UI qualification adapter is provided.
"""
from copy import deepcopy
import hashlib
import hmac
import http.client
import json
from pathlib import Path
import re
import socket
import ssl
import tempfile
from types import SimpleNamespace
from urllib.parse import urlsplit

import yaml

from native_control import NativeControlTransport
from native_control_artifact import coordinates as control_coordinates
from native_core_values import compose, tenant, PLANNING_WORKSPACE
from native_inspect import document, native_archive, same_local_reference, sha
from native_pipeline import NativePipelineAdapter, canonical
from native_recipe import merge_values, require
from native_webapp import WEBAPP_INPUTS, coordinates as webapp_coordinates


def image_id_matches(value, reference, manifest, config):
    """Kubernetes/CRI's two documented content identities, never a tag match."""
    if value in (config, "containerd://" + config):
        return True
    if not isinstance(value, str):
        return False
    value = value.removeprefix("docker-pullable://")
    return same_local_reference(value, reference) and value.endswith("@" + manifest)


def runtime_field(container, key):
    """Normalize only EnvVar's API-omitted zero value, not arbitrary defaults."""
    value = deepcopy(container.get(key))
    if key == "env" and isinstance(value, list):
        for entry in value:
            if "valueFrom" not in entry and entry.get("value") in (None, ""):
                entry["value"] = ""
    return value


def strategy_type(deployment):
    """Deployment's documented default; explicit Recreate stays mandatory."""
    return deployment["spec"].get("strategy", {}).get("type", "RollingUpdate")


class NativeCoreAdapter(NativeControlTransport, NativePipelineAdapter):
    def __init__(self, stack, inputs, operator, tls_material=None):
        require(isinstance(inputs, dict) and WEBAPP_INPUTS <= set(inputs), "qualified_webapp_packet_and_native_archive_required")
        super().__init__(stack, inputs, tls_material)
        self._configure_control(operator)
        self._base_values = None
        self._base_sha = None
        self._release_revision = None
        self._ready_uids = None
        self._ready_specs = None
        self._recipe_sha = stack.recipe_hash()
        self._webapp = None
        self._pipeline_oids = None
        self._public_route = None
        self._public_route_binding = None

    def _preflight(self, selected, fresh=False):
        require(self.stack.recipe_hash() == self._recipe_sha, "native_recipe_source_changed_during_execution")
        if self._public_route_binding is not None:
            self._qualify_public_route(selected, self._public_route_binding)
        return super()._preflight(selected, fresh=fresh)

    def _selected_secret_names(self, selected):
        return (super()._selected_secret_names(selected) |
                {self.control[k]["name"] for k in ("owner", "runtime", "cast")} |
                {self.ADMIN_SECRET, self.SERVER_TLS_SECRET, "kind-tls"})

    def verify_artifact(self, selected):
        self._verified = None
        self._webapp = None
        result = super().verify_artifact(selected)
        self._verified = None
        # Presence of an environment knob does not prove an older image
        # implements independent reader authority. Run only pure module
        # imports in the already-bound, read-only networkless images before
        # creating any cluster, credential or database object.
        from native_inspect import pipeline_coordinates
        pipeline = pipeline_coordinates(self.inputs, selected)
        pipeline_image = self._image(pipeline["localTag"], selected["sourceRevision"], selected["architecture"],
                                     pipeline["buildIndexDigest"], selected["configDigest"])
        reader = self._probe(pipeline_image["Id"], "bun", """
const m=await import('/app/src/session-read-api/self-issued.ts');
console.log(JSON.stringify({accessPrefix:m.ACCESS_PREFIX,scope:m.READ_SCOPE,issuer:m.SESSIONS_PATH}));
""", {})
        require(reader == {"accessPrefix": "rth_at_read_", "scope": "rth:read",
                           "issuer": "/internal/v1/session-read/sessions"}, "qualified_independent_reader_module_required")
        control = control_coordinates(self.inputs, selected["control"], selected["architecture"])
        control_image = self._image(control["tag"], selected["control"]["sourceRevision"], selected["architecture"],
                                    control["dockerIndexDigest"], selected["control"]["configDigest"])
        features = self._probe(control_image["Id"], "node", """
import('/app/node_modules/relay-control/dist/features.js').then(m=>{
 console.log(JSON.stringify({names:m.FEATURES,defaults:m.NO_FEATURES}));
}).catch(()=>process.exitCode=1);
""", {})
        require(features == {"names": ["flows", "relayfile", "chief"],
                             "defaults": {"flows": False, "relayfile": False, "chief": False}},
                "qualified_selected_features_core_module_required")
        self._verify_webapp(selected)
        self._verified = result
        return result

    def _verify_webapp(self, selected):
        webapp = webapp_coordinates(self.inputs, selected["architecture"])
        actual = self._image(webapp["tag"], webapp["sourceRevision"], selected["architecture"],
                             webapp["indexDigest"], webapp["configDigest"])
        require(actual.get("RootFS", {}).get("Layers") == webapp["config"]["rootfs"]["diff_ids"] and
                all(actual.get("Config", {}).get(k) == v for k, v in webapp["config"]["config"].items()),
                "actual_webapp_config_or_rootfs_differs")
        lines = "".join(h + "  " + n + "\n" for n, h in sorted(webapp["files"].items()))
        result = self._docker_json(["run", "--pull", "never", "--rm", "-i", "--network", "none", "--read-only",
            "--cpus", "1", "--memory", "256m", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
            "--entrypoint", "/bin/sh", actual["Id"], "-ec",
            "cd /usr/share/nginx/html; sha256sum -c - >/dev/null; printf '%s\\n' '{\"checked\":" + str(len(webapp["files"])) + "}'"], data=lines)
        require(result == {"checked": len(webapp["files"])}, "actual_webapp_static_bundle_differs")
        self._webapp = webapp

    def inspect(self, selected):
        self._pipeline_oids = None
        facts = super().inspect(selected)
        if facts["mode"] == "repeat":
            bound = document(self.inputs["bindingReceipt"], self.inputs["bindingReceiptSha256"])
            from native_target import require_record
            require_record(self.stack, bound)
            require(bound.get("version") == 1 and bound.get("type") == "local-kind-native-core" and
                    bound.get("selection") == selected and bound.get("recipeSha256") == self.stack.recipe_hash(),
                    "repeat_requires_exact_native_selection_binding")
            require(bound.get("webapp", {}).get("packetSha256") == self.inputs["webappPacketSha256"],
                    "repeat_qualified_webapp_packet_changed")
            for resource in bound["resources"]:
                if "specSha256" not in resource:
                    continue
                current = self._get(resource["kind"].lower() + "/" + resource["name"])
                require(hashlib.sha256(canonical(current.get("spec", current.get("data", {}))).encode()).hexdigest() == resource["specSha256"],
                        "repeat_native_resource_spec_or_public_contract_changed")
            current_oids = self._pipeline_role_oids(selected)
            require(bound.get("pipelineRoleOids") == current_oids,
                    "pipeline_owner_or_runtime_role_identity_changed")
            self._pipeline_oids = current_oids
            self._owner_oid = current_oids[selected["roles"]["owner"]]
        return facts

    def _pipeline_role_oids(self, selected):
        names = set(selected["roles"].values())
        raw = self._psql(selected, "hoopdb", "SELECT coalesce(json_object_agg(rolname,oid),'{}'::json) FROM pg_roles WHERE rolname IN (" +
                         ",".join("'" + n + "'" for n in sorted(names)) + ");", read_only=True)
        value = json.loads(raw)
        require(isinstance(value, dict) and set(value) == names and
                all(type(oid) is int and oid > 0 for oid in value.values()) and
                len(set(value.values())) == len(names), "native_pipeline_role_identity_incomplete")
        return value

    def verify_credentials(self, selected):
        self._completed.discard("runtime_credentials_verified")
        try:
            result = super().verify_credentials(selected)
            current = self._pipeline_role_oids(selected)
            if self._inspected["mode"] == "fresh":
                require(current[selected["roles"]["owner"]] == self._owner_oid and
                        all(current[n] == oid for n, oid in self._claimed_oids.items()),
                        "pipeline_owner_or_runtime_role_identity_changed")
            else:
                require(current == self._pipeline_oids, "pipeline_owner_or_runtime_role_identity_changed")
            self._pipeline_oids = current
            return result
        except Exception:
            self._completed.discard("runtime_credentials_verified")
            raise

    def _base(self):
        args = self.stack.values_args()
        require(len(args) % 2 == 0 and all(args[i] == "-f" for i in range(0, len(args), 2)),
                "native_values_files_only")
        layers = [yaml.safe_load(Path(args[i]).read_text()) or {} for i in range(1, len(args), 2)]
        require(any(isinstance(v.get("relay-webapp", {}).get("image"), dict) and
                    v["relay-webapp"]["image"].get("repository") and v["relay-webapp"]["image"].get("digest")
                    for v in layers[1:]), "explicit_qualified_webapp_image_override_required")
        value = merge_values(*layers)
        if self._webapp is not None:
            image = value["relay-webapp"]["image"]
            require(same_local_reference(image["repository"] + "@" + image["digest"], self._webapp["reference"]),
                    "selected_webapp_differs_from_qualified_packet")
        actual = hashlib.sha256(canonical(value).encode()).hexdigest()
        require(self._base_sha in (None, actual), "native_input_values_changed")
        if self._base_sha is None:
            self._base_sha, self._base_values = actual, value
        return deepcopy(value)

    def _values(self, selected, phase):
        self._control_bound(selected)
        value = compose(self._base(), selected, self.control, phase,
                        self._tenant if phase == "serve" else None)
        if phase == "serve" and self._public_route is not None:
            from native_network import public_route_values
            value = public_route_values(value, self._public_route)
        return value

    def _network_stack(self, selected):
        return SimpleNamespace(state=self.stack.state, marker=self.stack.marker, name=self.stack.name,
            profile=self.stack.profile, env=self.stack.env,
            require_owned_cluster=lambda: self._owned_uid(selected),
            k=lambda *a, **k: self._transport_call("k", *a, **k),
            cmd=lambda *a, **k: self._transport_call("cmd", *a, **k))

    def _qualify_public_route(self, selected, expected=None, *, allow_absent=False):
        from native_network import control_public_route
        # No cached admission survives a failed observation. Public route
        # qualification is GET-only and precedes any chart/state mutation.
        self._public_route = None
        bound = self._public_route_binding
        require(bound is None or expected in (None, bound), "control_public_gateway_binding_must_not_change")
        observed = control_public_route(self._network_stack(selected), self._values(selected, "serve"), bound or expected,
                                        allow_absent=allow_absent)
        self._public_route_binding = observed
        self._public_route = observed
        return observed

    def _render_values(self, value):
        result = self._transport_call("cmd", ["helm", "template", "agent-relay", "charts/agent-relay",
            "-n", "agent-relay", "-f", "-"], data=yaml.safe_dump(value), sensitive=True, timeout=60)
        docs = [d for d in yaml.safe_load_all(result.stdout) if d]
        require(not any(d.get("kind") == "Secret" for d in docs), "native_chart_must_reference_managed_secrets")
        return docs

    def _validate_render_docs(self, selected, docs):
        result = super()._validate_render_docs(selected, docs)
        owners = {self.control["owner"]["name"], selected["secretRefs"]["owner"]["name"], self.ADMIN_SECRET}
        allowed = {
            "relay-control": {self.control["runtime"]["name"]}, "relaycast": {self.control["cast"]["name"]},
            "relay-webapp": set(),
            "session-native-consumer": {selected["secretRefs"][k]["name"] for k in ("consumer", "locker")},
            "session-native-ingest": {selected["secretRefs"][k]["name"] for k in ("ingest", "locker")},
            "session-read-api": {selected["secretRefs"][k]["name"] for k in ("reader", "readerIssuer", "locker")}}
        def references(value):
            found = set()
            if isinstance(value, dict):
                for k, v in value.items():
                    if k in {"secretKeyRef", "secretRef", "nodePublishSecretRef", "secret"} and isinstance(v, dict) and v.get("name", v.get("secretName")):
                        found.add(v.get("name", v.get("secretName")))
                    if k == "imagePullSecrets" and isinstance(v, list):
                        found |= {r["name"] for r in v if isinstance(r, dict) and r.get("name")}
                    if k == "secretName" and isinstance(v, str):
                        found.add(v)
                    found |= references(v)
            elif isinstance(value, list):
                for v in value:
                    found |= references(v)
            return found
        for d in docs:
            if d["kind"] != "Deployment" or not d["spec"].get("replicas", 1):
                continue
            name, pod = d["metadata"]["name"], d["spec"]["template"]["spec"]
            refs = references(pod)
            require(name in allowed and not (refs & owners) and refs <= allowed[name],
                    "native_runtime_owner_or_foreign_secret_reference_refused")
        api = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "relay-control")
        runtime = self.control["runtime"]
        volumes = api["spec"]["template"]["spec"].get("volumes", [])
        credentials = [v["secret"] for v in volumes if "secret" in v]
        expected_keys = {runtime[k] for k in ("databaseKey", "bootstrapKey", "encryptionKey", "castInternalKey", "internalKey", "introspectionKey", "readerIssuerKey")}
        require(len(credentials) == 1 and credentials[0].get("secretName") == runtime["name"] and
                {v.get("key") for v in credentials[0].get("items", [])} == expected_keys,
                "control_runtime_projects_only_generated_runtime_credentials")
        return result

    def render(self, selected):
        self._rendered = False
        self._bind_selection(selected)
        require(selected["reference"].startswith("docker.io/agent-relay-kind/"),
                "complete_core_requires_explicit_local_pipeline_registry")
        # Contract validation and all Helm admission happen before any cluster
        # creation. The token is render-only, not a fabricated tenant identity.
        if self._inspected["mode"] == "repeat":
            binding = document(self.inputs["bindingReceipt"], self.inputs["bindingReceiptSha256"])
            require(binding.get("controlContractSha256") == self._control_contract_sha,
                    "repeat_control_operator_contract_changed")
            self._tenant = tenant(binding.get("tenant"))
            require(binding.get("controlPublicRoute"), "repeat_control_public_gateway_binding_required")
            self._qualify_public_route(selected, binding["controlPublicRoute"])
        docs = self._render_values(self._values(selected, "serve" if self._tenant else "plan"))
        result = self._validate_render_docs(selected, docs)
        if self._inspected["mode"] == "repeat":
            require(binding.get("valuesSha256") == self._base_sha and
                    binding.get("renderSha256") == hashlib.sha256(canonical(docs).encode()).hexdigest(),
                    "repeat_chart_or_values_change_requires_explicit_operator_upgrade")
        self._rendered = True
        return result

    def _template(self, selected, overrides):
        # The official consumer prepare Job must use the *observed* Default
        # workspace and authority, not return to the original input files.
        require(self._tenant is not None, "real_tenant_required_before_pipeline_bootstrap")
        value = merge_values(self._values(selected, "serve"), overrides)
        return self._transport_call("cmd", ["helm", "template", "agent-relay", "charts/agent-relay", "-n", "agent-relay",
            "-f", "-"], data=yaml.safe_dump(value), sensitive=True, timeout=60)

    def _helm_state(self, *, absent=False):
        result = self._transport_call("cmd", ["helm", "list", "-n", "agent-relay", "--all", "-o", "json"],
                                      sensitive=True, timeout=30)
        entries = [r for r in json.loads(result.stdout) if r.get("name") == "agent-relay"]
        if absent:
            require(not entries, "existing_app_release_refuses_fresh_control_install")
            return None
        require(len(entries) == 1 and entries[0].get("status") == "deployed" and
                str(entries[0].get("revision", "")).isdigit(), "native_release_must_be_deployed")
        revision = int(entries[0]["revision"])
        require(self._release_revision in (None, revision), "concurrent_native_release_changed")
        return revision

    def _upgrade(self, selected, value, *, install=False):
        self._phase(selected)
        self._helm_state(absent=install)
        require(value["relay-control"]["migrations"]["enabled"] is False,
                "owner_migration_job_must_not_run_in_runtime_upgrade")
        require(not value["components"]["sessionsPipeline"] or
                (self._tenant and value["sessions-pipeline"]["sessionReadApi"]["directoryWorkspaces"] == self._tenant["workspaceId"]),
                "planning_tenant_must_never_be_deployed")
        docs = self._render_values(value)
        require(not any(d["kind"] == "Job" for d in docs), "runtime_upgrade_must_not_apply_privileged_jobs")
        if value["components"]["sessionsPipeline"]:
            self._validate_render_docs(selected, docs)
        else:
            require({d["metadata"]["name"] for d in docs if d["kind"] == "Deployment"} == {"relay-control", "relaycast"},
                    "first_boot_must_start_only_control_and_cast")
        version = self._transport_call("cmd", ["helm", "version", "--template", "{{.Version}}"], sensitive=True).stdout.strip()
        require(version.startswith(("v3.", "v4.")), "unsupported_native_helm_version")
        args = ["helm", "upgrade", "agent-relay", "charts/agent-relay", "-n", "agent-relay", "-f", "-", "--reset-values",
                "--wait", "--wait-for-jobs", "--timeout", "10m"]
        if install:
            args.append("--install")
        if version.startswith("v4."):
            args.append("--server-side=false")
        # No atomic rollback, uninstall, adoption, delete, implicit schema
        # upgrade, credential regeneration or retry on a partial failure.
        self._transport_call("cmd", args, data=yaml.safe_dump(value), sensitive=True, timeout=630)
        self._release_revision = None
        self._release_revision = self._helm_state()
        return docs

    def _import_control(self, selected):
        cr = control_coordinates(self.inputs, selected["control"], selected["architecture"])
        control = selected["control"]
        tag = cr["tag"]
        require(isinstance(tag, str) and re.fullmatch(r"agent-relay-kind/[a-z0-9._/-]+:[A-Za-z0-9_.-]+", tag),
                "qualified_local_control_tag_required")
        with tempfile.TemporaryDirectory(prefix="native-control-image-", dir=self.stack.state) as directory:
            archive = Path(directory) / "native.tar"
            self._transport_call("cmd", [*self.stack.docker_args, "image", "save", "--platform", "linux/" + selected["architecture"],
                "-o", archive, tag], timeout=300, sensitive=True)
            native_archive(archive, sha(archive), control["sourceRevision"], control["manifestDigest"], control["configDigest"], selected["architecture"])
            self._transport_call("cmd", ["kind", "load", "image-archive", "--name", self.stack.name, archive], timeout=300, sensitive=True)
        from control import alias
        bound = SimpleNamespace(cmd=lambda *a, **k: self._transport_call("cmd", *a, **k),
                                docker_args=self.stack.docker_args, name=self.stack.name, arch=self.stack.arch)
        alias(bound, control["reference"].removeprefix("docker.io/"), {
            "tag": tag, "manifestDigest": control["manifestDigest"], "configDigest": control["configDigest"]})

    def _import_webapp(self, selected):
        require(self._webapp is not None, "qualified_webapp_preflight_required")
        # Recheck unchanged raw receipts/archive before exporting the real
        # local tag. Never assume native manifest == Docker index/config ID.
        current = webapp_coordinates(self.inputs, selected["architecture"])
        require(current == self._webapp, "qualified_webapp_changed_before_import")
        with tempfile.TemporaryDirectory(prefix="native-webapp-image-", dir=self.stack.state) as directory:
            archive = Path(directory) / "native.tar"
            self._transport_call("cmd", [*self.stack.docker_args, "image", "save", "--platform", "linux/" + selected["architecture"],
                "-o", archive, current["tag"]], timeout=300, sensitive=True)
            native_archive(archive, sha(archive), current["sourceRevision"], current["manifestDigest"], current["configDigest"], selected["architecture"])
            self._transport_call("cmd", ["kind", "load", "image-archive", "--name", self.stack.name, archive], timeout=300, sensitive=True)
        from control import alias
        bound = SimpleNamespace(cmd=lambda *a, **k: self._transport_call("cmd", *a, **k),
                                docker_args=self.stack.docker_args, name=self.stack.name, arch=self.stack.arch)
        alias(bound, current["reference"].removeprefix("docker.io/"), {
            "tag": current["tag"], "manifestDigest": current["manifestDigest"], "configDigest": current["configDigest"]})

    def _runtime_pod(self, deployment):
        workload = self._get("deployment/" + deployment)
        require(workload.get("spec", {}).get("replicas") == 1 and
                workload.get("status", {}).get("readyReplicas") == 1 and
                workload.get("status", {}).get("updatedReplicas") == 1 and
                workload.get("status", {}).get("availableReplicas") == 1 and
                workload.get("status", {}).get("observedGeneration") == workload.get("metadata", {}).get("generation"),
                "selected_native_deployment_not_ready")
        labels = workload["spec"]["selector"]["matchLabels"]
        pods = json.loads(self._transport_call("k", "get", "pod", "-l",
            ",".join(k + "=" + v for k, v in sorted(labels.items())), "-o", "json", sensitive=True).stdout)["items"]
        active = [p for p in pods if not p["metadata"].get("deletionTimestamp")]
        require(len(active) == 1 and all(c.get("ready") is True for c in active[0].get("status", {}).get("containerStatuses", [])) and
                active[0].get("status", {}).get("containerStatuses"), "one_ready_native_pod_required")
        require(active[0].get("spec", {}).get("containers") == workload["spec"]["template"]["spec"].get("containers"),
                "native_pod_configuration_is_not_current_deployment")
        # Prove the selected Pod belongs to the live Deployment, not merely a
        # foreign Pod with matching labels.
        refs = active[0]["metadata"].get("ownerReferences", [])
        require(len(refs) == 1 and refs[0].get("kind") == "ReplicaSet", "owned_native_replicaset_required")
        rs = self._get("replicaset/" + refs[0]["name"])
        require(rs["metadata"]["uid"] == refs[0]["uid"] and any(
            r.get("kind") == "Deployment" and r.get("uid") == workload["metadata"]["uid"]
            for r in rs["metadata"].get("ownerReferences", [])), "native_pod_deployment_identity_changed")
        return workload, active[0]

    def _control_pod(self, selected):
        workload, pod = self._runtime_pod("relay-control")
        containers = workload["spec"]["template"]["spec"]["containers"]
        require(len(containers) == 1 and containers[0].get("name") == "api" and
                same_local_reference(containers[0].get("image"), selected["control"]["reference"]),
                "qualified_control_runtime_image_required_before_operator_api")
        return pod["metadata"]["name"]

    def install_control(self, selected):
        self._phase(selected, ("infrastructure",), fresh=True)
        self._helm_state(absent=True)
        self._claim_control_credentials(selected)
        self._import_control(selected)
        job = self._control_migration_document(selected)
        self._control_migration = self._create("Job", job["metadata"]["name"], {"apiVersion": "batch/v1", "spec": job["spec"]})
        result = self._transport_call("wait_job", job["metadata"]["name"], seconds=600)
        require(result.get("succeeded") == 1 and not result.get("failed", 0), "official_control_migrations_failed")
        self._verify_control_ledger(selected)
        initial = self._values(selected, "control")
        # Cast is a released immutable image selected by the reviewed chart;
        # it must be cached through the normal native node transport first.
        for d in self._render_values(initial):
            if d["kind"] != "Deployment" or d["metadata"]["name"] == "relay-control":
                continue
            for c in d["spec"]["template"]["spec"].get("containers", []):
                require("@sha256:" in c["image"], "immutable_cast_image_required")
                self._transport_call("load", c["image"])
        self._upgrade(selected, initial, install=True)
        self._tenant = self._observe_control(selected, self._control_pod(selected))
        self._completed.add("control_installed")
        return {"ok": True, **self._tenant, "sourceRevision": selected["control"]["sourceRevision"],
                "configDigest": selected["control"]["configDigest"], "jobName": job["metadata"]["name"]}

    def verify_control(self, selected):
        self._phase(selected)
        require(self._tenant is not None, "bound_control_tenant_required")
        self._verify_control_ledger(selected)
        actual = self._observe_control(selected, self._control_pod(selected))
        require(actual == self._tenant, "repeat_control_tenant_changed")
        self._verify_control_authorities(selected)
        roles = self._control_roles(selected)
        binding = document(self.inputs["bindingReceipt"], self.inputs["bindingReceiptSha256"])
        require(binding.get("controlRoleOids") == {n: r["oid"] for n, r in roles.items()},
                "control_owner_or_runtime_role_identity_changed")
        self._release_revision = self._helm_state()
        return {"ok": True, **actual, "sourceRevision": selected["control"]["sourceRevision"], "configDigest": selected["control"]["configDigest"]}

    def _verify_control_authorities(self, selected):
        runtime = self.control["runtime"]
        secret = self._get("secret/" + runtime["name"])
        require(secret.get("immutable") is True, "immutable_control_runtime_secret_required")
        for own_key, name in ((runtime["introspectionKey"], "introspection"), (runtime["readerIssuerKey"], "readerIssuer")):
            ref = selected["secretRefs"][name]
            shared = self._get("secret/" + ref["name"])
            require(shared.get("immutable") is True and own_key in secret.get("data", {}) and
                    ref["key"] in shared.get("data", {}) and hmac.compare_digest(
                        secret["data"][own_key], shared["data"][ref["key"]]), "control_service_authority_binding_changed")
        require(not hmac.compare_digest(secret["data"][runtime["introspectionKey"]],
                                       secret["data"][runtime["readerIssuerKey"]]), "reader_and_ingest_authority_must_be_distinct")

    def serve(self, selected, request):
        self._phase(selected, ("runtime_credentials_verified",))
        require(request == {"bootstrapEnabled": False, "phase": "serve"}, "native_runtime_only_request_required")
        value = self._values(selected, "serve")
        # Existing manual/foreign routes refuse before gateway installation.
        # The complete native mode uses an internal reader Service; it never
        # creates the legacy public-host IP alias helper Service.
        import native_network
        from stack import TRAEFIK_CHART
        from edge import install
        network_stack = self._network_stack(selected)
        native_network.preflight(network_stack, value)
        self._qualify_public_route(selected, self._public_route, allow_absent=True)
        install(self.stack, TRAEFIK_CHART, "agent-relay", wait_for_route=False)
        observation = native_network.ensure(network_stack, value)
        require(native_network.selected_values(value, observation) == value,
                "independent_reader_must_not_gain_legacy_alias_values")
        self._qualify_public_route(selected, self._public_route)
        value = self._values(selected, "serve")
        # Cache exact qualified pipeline images; already prepared schema/role
        # Jobs remain terminal and are never requeued by this runtime chart.
        self._ensure_pipeline_image(selected)
        self._import_webapp(selected)
        docs = self._upgrade(selected, value)
        self._completed.add("native_served")
        return {"ok": True, "releaseRevision": self._release_revision,
                "renderSha256": hashlib.sha256(canonical(docs).encode()).hexdigest()}

    def verify_ready(self, selected):
        self._ready_uids = None
        self._ready_specs = None
        self._phase(selected, ("native_served", "runtime_credentials_verified"))
        self._helm_state()
        docs = self._render_values(self._values(selected, "serve"))
        self._validate_render_docs(selected, docs)
        names = {"relay-control", "relay-webapp", "session-native-ingest", "session-native-consumer", "session-read-api"}
        uids, specs = {}, {}
        for name in sorted(names):
            wanted = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == name)
            workload, pod = self._runtime_pod(name)
            if name == "relay-control":
                aliases = wanted["spec"]["template"]["spec"].get("hostAliases", [])
                require(workload["spec"]["template"]["spec"].get("hostAliases", []) == aliases and
                        pod["spec"].get("hostAliases", []) == aliases,
                        "native_control_public_route_alias_changed")
            require(strategy_type(workload) == strategy_type(wanted) and
                    workload["spec"]["template"]["spec"]["containers"] == pod["spec"]["containers"],
                    "native_live_pod_does_not_match_selected_workload")
            for expected in wanted["spec"]["template"]["spec"]["containers"]:
                actual = next(c for c in workload["spec"]["template"]["spec"]["containers"] if c["name"] == expected["name"])
                require(all(runtime_field(actual, k) == runtime_field(expected, k) for k in ("image", "env", "volumeMounts", "command", "args")),
                        "native_selected_runtime_configuration_changed")
                binding = selected["control"] if name == "relay-control" else self._webapp if name == "relay-webapp" else selected
                running = next((c for c in pod["status"]["containerStatuses"] if c.get("name") == expected["name"]), {})
                require(image_id_matches(running.get("imageID"), binding["reference"], binding["manifestDigest"], binding["configDigest"]),
                        "running_native_container_content_identity_mismatch")
                probe = expected.get("readinessProbe", {}).get("exec", {}).get("command")
                if probe:
                    self._transport_call("k", "exec", pod["metadata"]["name"], "-c", expected["name"], "--", *probe,
                                         sensitive=True, timeout=30)
            uids[name] = workload["metadata"]["uid"]
            specs[name] = hashlib.sha256(canonical(workload["spec"]).encode()).hexdigest()
        require(self._observe_control(selected, self._control_pod(selected)) == self._tenant,
                "final_control_tenant_changed")
        self.verify_owner_final(selected)
        self.qualify_references(selected)
        self._runtime_pod("relaycast")
        self._verify_control_authorities(selected)
        self._verify_public_routes(selected)
        require(self._public_route is not None, "control_public_gateway_must_be_qualified")
        self._qualify_public_route(selected, self._public_route)
        self._ready_uids = uids
        self._ready_specs = specs
        return {"ok": True, "deploymentUids": uids}

    def _verify_public_routes(self, selected):
        ca = self._get("configmap/" + selected["postgresCa"]["configMap"])["data"]["ca.crt"]
        require(hashlib.sha256(ca.encode()).hexdigest() == selected["postgresCa"]["sha256"], "public_route_ca_changed")
        context = ssl.create_default_context(cadata=ca)
        context.verify_flags |= ssl.VERIFY_X509_STRICT
        # Fixed host/SNI and loopback socket; no global DNS or OS trust edit.
        site, history = urlsplit(selected["siteOrigin"]), urlsplit(selected["historyOrigin"])
        # An unauthenticated reader request must reach its auth fence, not
        # succeed on the webapp's catch-all or expose an internal issuer.
        routes = ((site.hostname, site.port or 443, "/", 200),
                  (history.hostname, history.port or 443, "/v1/sessions", 401))
        for host, port, path, expected_status in routes:
            connection = http.client.HTTPSConnection(host, port, context=context, timeout=10)
            connection._create_connection = lambda a, timeout, source_address=None, port=port: socket.create_connection(("127.0.0.1", port), timeout)
            try:
                connection.request("GET", path)
                response = connection.getresponse()
                body = response.read(65536)
                require(response.status == expected_status, "verified_public_application_route_not_ready")
                if expected_status == 401:
                    require(json.loads(body).get("error", {}).get("code") == "missing_authorization",
                            "verified_public_reader_auth_fence_not_ready")
            finally:
                connection.close()

    def record_ready(self, selected, scope):
        self._phase(selected, ("native_served", "runtime_credentials_verified"))
        require(self._ready_uids and scope.get("fullAcceptance") is False and scope.get("sourceRevision") == selected["sourceRevision"],
                "native_ready_requires_observed_scoped_runtime")
        for name, expected in self._ready_uids.items():
            live = self._get("deployment/" + name)
            require(live["metadata"]["uid"] == expected and
                    hashlib.sha256(canonical(live["spec"]).encode()).hexdigest() == self._ready_specs[name],
                    "native_runtime_changed_after_final_verification")
        uid = self._get("namespace/kube-system", namespace=False)["metadata"]["uid"]
        require(self._pipeline_oids and self._pipeline_role_oids(selected) == self._pipeline_oids,
                "pipeline_owner_or_runtime_role_identity_changed")
        require(self._public_route is not None, "control_public_gateway_must_be_qualified")
        self._qualify_public_route(selected, self._public_route)
        resources = self._get("deployments,statefulsets,persistentvolumeclaims,configmaps")["items"]
        for name in sorted(self._selected_secret_names(selected)):
            resources.append(self._get("secret/" + name))
        record = {"version": 1, "type": "local-kind-native-core", "clusterUid": uid, "profile": selected["profile"],
            "sourceRevision": selected["sourceRevision"], "generation": selected["generation"], "roles": selected["roles"],
            "selection": selected, "controlRoleOids": {n: r["oid"] for n, r in self._control_roles(selected).items()},
            "pipelineRoleOids": self._pipeline_oids,
            "webapp": {k: self._webapp[k] for k in ("sourceRevision", "reference", "manifestDigest", "configDigest", "packetSha256", "archiveSha256")},
            "officialBootstrapSha256": selected["officialBootstrapSha256"], "tenant": self._tenant,
            "controlContractSha256": self._control_contract_sha, "releaseRevision": self._helm_state(),
            "controlPublicRoute": self._public_route,
            "valuesSha256": self._base_sha, "recipeSha256": self._recipe_sha,
            "renderSha256": hashlib.sha256(canonical(self._render_values(self._values(selected, "serve"))).encode()).hexdigest(),
            "resources": sorted([{"kind": d["kind"], "name": d["metadata"]["name"], "uid": d["metadata"]["uid"],
                **({"specSha256": hashlib.sha256(canonical(d.get("spec", d.get("data", {}))).encode()).hexdigest()}
                   if d["kind"] != "Secret" else {})} for d in resources],
                                key=lambda r: (r["kind"], r["name"])),
            "fullAcceptance": False, "castPostgresBackendAccepted": False}
        from native_target import binding
        target = binding(self.stack)
        if target is not None:
            record["nativeTarget"] = target
        path = self.stack.state / "native-binding.json"
        if self._inspected["mode"] == "repeat":
            bound = document(self.inputs["bindingReceipt"], self.inputs["bindingReceiptSha256"])
            require(bound.get("resources") == record["resources"] and bound.get("tenant") == record["tenant"],
                    "native_repeat_resource_binding_changed")
            return {"ok": True, "receiptSha256": self.inputs["bindingReceiptSha256"]}
        self._exclusive_json(path, record)
        return {"ok": True, "receiptSha256": sha(path)}
