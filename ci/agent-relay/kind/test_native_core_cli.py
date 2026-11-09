"""Static plan and authority refusal tests; transport must remain untouched."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from native_core_cli import config, run, GENERATE_CA
from native_inspect import INPUT_FIELDS
from native_recipe import NativeRecipeError
from test_native_control import contract
from test_native_recipe import selected


class Cli(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.values = self.root / "selected.json"
        self.original_values = json.dumps({"relay-webapp": {"image": {"repository": "example.invalid/qualified-webapp", "digest": "sha256:" + "b" * 64}}})
        self.values.write_text(self.original_values)
        self.s = selected(); self.s["control"]["independentIssuer"] = True
        self.s["readerLoginAdvertisesSync"] = False
        self.s["postgresCa"]["sha256"] = GENERATE_CA
        self.value = {"version": 1, "selection": self.s, "operator": contract(),
            "inputs": {n: "source-only-path" for n in INPUT_FIELDS},
            "values": {"path": str(self.values), "sha256": hashlib.sha256(self.values.read_bytes()).hexdigest()}}

    def save(self):
        path = self.root / "config.json"; path.write_text(json.dumps(self.value))
        return path, hashlib.sha256(path.read_bytes()).hexdigest()

    def no_stack(self, *args):
        self.fail("static/refused input instantiated a runtime stack")

    def test_default_plan_never_instantiates_stack_or_claims_artifact_runtime_acceptance(self):
        result = run(*self.save(), stack_factory=self.no_stack)
        self.assertEqual(result["result"], "STATIC_NATIVE_CORE_PLAN_ONLY")
        self.assertTrue(result["generatedPublicCaPending"])
        self.assertFalse(result["artifactRuntimeVerified"])
        self.assertFalse(result["clusterChanged"])
        self.assertFalse(result["fullAcceptance"])
        self.assertNotIn("0" * 64, json.dumps(result))
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["config.json", "selected.json"])

    def test_fresh_generation_requires_explicit_execute_flag_before_runtime(self):
        for execute, generate in ((True, False), (False, True)):
            with self.assertRaises(NativeRecipeError):
                run(*self.save(), execute=execute, generate_local_test_ca=generate, stack_factory=self.no_stack)

    def test_repeat_never_regenerates_ca_and_must_name_prior_native_binding(self):
        self.s["postgresCa"]["sha256"] = "f" * 64
        with self.assertRaisesRegex(NativeRecipeError, "fresh_execute_only"):
            run(*self.save(), execute=True, generate_local_test_ca=True, stack_factory=self.no_stack)
        self.s["postgresCa"]["sha256"] = GENERATE_CA
        self.value["inputs"].update(bindingReceipt="existing.json", bindingReceiptSha256="a" * 64)
        with self.assertRaisesRegex(NativeRecipeError, "must_not_regenerate"):
            run(*self.save(), execute=True, generate_local_test_ca=True, stack_factory=self.no_stack)

    def test_wrong_config_or_values_hash_and_inline_credentials_refuse_before_runtime(self):
        path, digest = self.save()
        with self.assertRaisesRegex(NativeRecipeError, "config_bytes"):
            run(path, "0" * 64, execute=True, generate_local_test_ca=True, stack_factory=self.no_stack)
        self.values.write_text("{\"changed\":true}")
        with self.assertRaisesRegex(NativeRecipeError, "values_bytes"):
            run(path, digest, execute=True, generate_local_test_ca=True, stack_factory=self.no_stack)
        self.values.write_text(self.original_values); self.value["operator"]["password"] = "never-allowed"
        with self.assertRaisesRegex(NativeRecipeError, "credential_values"):
            run(*self.save(), stack_factory=self.no_stack)

    def test_historical_default_webapp_pin_cannot_be_inherited_implicitly(self):
        self.values.write_text("{}")
        self.value["values"]["sha256"] = hashlib.sha256(self.values.read_bytes()).hexdigest()
        with self.assertRaisesRegex(NativeRecipeError, "webapp_image_override"):
            run(*self.save(), stack_factory=self.no_stack)


if __name__ == "__main__": unittest.main()
