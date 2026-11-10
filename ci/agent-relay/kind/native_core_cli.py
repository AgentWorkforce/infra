#!/usr/bin/env python3
"""Explicit native core plan/execute entry point; default is static plan only.

Credentials are generated in memory and delivered only to owned Kubernetes
Secrets. No credential, private key or complete rendered manifest is written to
an evidence file. Existing legacy fixtures require their separate qualification
path; this command cannot adopt or upgrade one implicitly.
"""
import argparse
from copy import deepcopy
import json
import os
from pathlib import Path
import re
import yaml


from native_bootstrap import fresh_tls_material
from native_control import control_contract
from native_core import NativeCoreAdapter
from native_inspect import sha, INPUT_FIELDS, OPTIONAL_INPUT_FIELDS
from native_recipe import CORE_OPERATIONS, NativeRecipe, nonsecret, require, selection
from native_webapp import WEBAPP_INPUTS

GENERATE_CA = "generate-local-test-ca"


def config(path, expected_sha, *, instance_target=None):
    path = Path(path)
    require(not path.is_symlink() and path.is_file() and re.fullmatch(r"[a-f0-9]{64}", expected_sha or "") and
            sha(path) == expected_sha, "reviewed_native_config_bytes_required")
    value = json.loads(path.read_text())
    nonsecret(value)
    require(isinstance(value, dict) and set(value) == {"version", "selection", "operator", "inputs", "values"} and
            type(value["version"]) is int and value["version"] == 1, "typed_native_core_config_required")
    require(value["selection"].get("profile") == "core", "complete_native_addons_transport_required")
    control_contract(value["operator"])
    require(isinstance(value["inputs"], dict) and INPUT_FIELDS <= set(value["inputs"]) and
            set(value["inputs"]) <= INPUT_FIELDS | OPTIONAL_INPUT_FIELDS, "unexpected_native_input_fields")
    require(WEBAPP_INPUTS <= set(value["inputs"]), "qualified_webapp_packet_and_native_archive_required")
    require(isinstance(value["values"], dict) and set(value["values"]) == {"path", "sha256"}, "pinned_selected_values_required")
    selected_values = Path(value["values"]["path"])
    require(not selected_values.is_symlink() and selected_values.is_file() and sha(selected_values) == value["values"]["sha256"],
            "selected_values_bytes_changed")
    overlay = yaml.safe_load(selected_values.read_text())
    nonsecret(overlay)
    webapp = overlay.get("relay-webapp", {}).get("image", {}) if isinstance(overlay, dict) else {}
    require(isinstance(webapp.get("repository"), str) and webapp["repository"] and
            re.fullmatch(r"sha256:[a-f0-9]{64}", webapp.get("digest", "")),
            "explicit_qualified_webapp_image_override_required")
    selected = deepcopy(value["selection"])
    generated = selected["postgresCa"]["sha256"] == GENERATE_CA
    if generated:
        require("bindingReceipt" not in value["inputs"], "repeat_must_not_regenerate_ca")
        # This value is structural validation only, never deployment input.
        selected["postgresCa"]["sha256"] = "0" * 64
    selected = selection(selected, target=instance_target)
    require(selected["control"]["independentIssuer"] is True, "native_control_backend_required")
    return value, selected, generated


def run(path, expected_sha, *, execute=False, generate_local_test_ca=False, stack_factory=None,
        instance_target=None, reviewed_target_sha256=None):
    target_binding = None
    if instance_target is not None:
        from native_target import NativeInstanceTarget
        require(type(instance_target) is NativeInstanceTarget, "typed_native_target_required")
        target_binding = instance_target.binding()
        require(not execute or stack_factory is None, "native_target_exact_factory_required")
        require(type(reviewed_target_sha256) is str and reviewed_target_sha256 == target_binding["targetSha256"],
                "reviewed_native_target_hash_required")
    else:
        require(reviewed_target_sha256 is None, "native_target_hash_without_target")
    value, selected, generated = config(path, expected_sha, instance_target=instance_target)
    require(not generate_local_test_ca or (execute and generated), "local_test_ca_flag_is_fresh_execute_only")
    if not execute:
        return {"result": "STATIC_NATIVE_CORE_PLAN_ONLY", "configSha256": expected_sha,
                "profile": "core", "phases": list(CORE_OPERATIONS), "generatedPublicCaPending": generated,
                "artifactRuntimeVerified": False, "clusterChanged": False, "fullAcceptance": False,
                **({"nativeTarget": target_binding} if target_binding is not None else {})}
    require(generate_local_test_ca is generated, "explicit_fresh_local_test_ca_intent_required")
    require(generated or ("bindingReceipt" in value["inputs"] and "bindingReceiptSha256" in value["inputs"]),
            "repeat_requires_prior_native_public_ca_binding")
    if stack_factory is None:
        from stack import Stack
        if instance_target is None:
            stack_factory = Stack
        else:
            from native_target import NativeInstanceStack
            stack_factory = lambda profile: NativeInstanceStack(profile, instance_target)
    stack = stack_factory("core")
    from native_target import binding, require_free_ports
    require(binding(stack) == target_binding, "native_target_factory_mismatch")
    if generated:
        require_free_ports(stack)
    # Use only the base profile and the pinned explicitly selected values.
    # Historical .kind/core/values.json may not leak into native composition.
    base = Path(__file__).resolve().parents[3] / "charts/agent-relay/values-kind-core.yaml"
    selected_path = Path(value["values"]["path"]).resolve()
    stack.values_args = lambda: ["-f", base, "-f", selected_path]
    stack.docker(require_space=False)
    material = None
    if generated:
        require(not any(p.exists() or p.is_symlink() for p in (stack.marker, stack.kubeconfig, stack.state / "ready.json")),
                "retained_target_cannot_generate_local_test_ca")
        clusters = stack.cmd(["kind", "get", "clusters"], timeout=30).stdout.splitlines()
        require(stack.name not in clusters, "existing_cluster_cannot_generate_local_test_ca")
        from stack import HOSTS
        material = fresh_tls_material([selected["postgres"]["host"], *HOSTS])
        selected["postgresCa"]["sha256"] = material.ca_sha256
        selected = selection(selected, target=instance_target)
    else:
        require("bindingReceipt" in value["inputs"] and "bindingReceiptSha256" in value["inputs"],
                "repeat_requires_prior_native_public_ca_binding")
    adapter = NativeCoreAdapter(stack, value["inputs"], value["operator"], material)
    if generated:
        # Public plan only; private keys remain in TlsMaterial until the
        # create-only owned Secret operation. An interrupted fresh attempt
        # requires review, never a second silent certificate identity.
        adapter._exclusive_json(stack.state / "native-execution-plan.json", {
            "version": 1, "configSha256": expected_sha, "selection": selected,
            "operatorContractSha256": adapter._control_contract_sha, "fullAcceptance": False,
            **({"nativeTarget": target_binding} if target_binding is not None else {})})
    stack.dependencies()
    receipts = NativeRecipe(selected, target=instance_target).run(adapter)
    return {"result": "NATIVE_CORE_RUNTIME_PHASES_COMPLETE", "phases": [r["phase"] for r in receipts],
            "configSha256": expected_sha, "publicCaSha256": selected["postgresCa"]["sha256"], "fullAcceptance": False,
            "scope": "Owned native core lifecycle only; separate actual Desktop upload/dashboard and add-on proof required",
            **({"nativeTarget": target_binding} if target_binding is not None else {})}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--reviewed-config-sha256", required=True)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--generate-local-test-ca", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        print(json.dumps(run(args.config, args.reviewed_config_sha256, execute=args.execute,
                             generate_local_test_ca=args.generate_local_test_ca)))
    except Exception as error:
        # Transport failures may carry credential-bearing captured output.
        # Emit a known internal enum only, never arbitrary exception text.
        print(json.dumps(failure_diagnostic(error)))
        raise SystemExit(1)


def failure_diagnostic(error):
    from native_recipe import NativePhaseError, NativeRecipeError, CORE_OPERATIONS, PHASE_FAILURE_CODES
    if isinstance(error, NativePhaseError):
        if type(error.phase) is str and type(error.code) is str and error.phase in (*CORE_OPERATIONS, "addons") and error.code in PHASE_FAILURE_CODES:
            return {"result": "REFUSED", "phase": error.phase, "errorCode": error.code}
        return {"result": "REFUSED", "errorCode": "native_core_failed_review_required"}
    code = str(error) if isinstance(error, NativeRecipeError) and re.fullmatch(r"[a-zA-Z0-9_:.-]+", str(error)) else "native_core_failed_review_required"
    return {"result": "REFUSED", "errorCode": code}


if __name__ == "__main__":
    main()
