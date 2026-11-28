import unittest

from zero_diff_gate import check, parse_allow

ESM = "aws_lambda_event_source_mapping.events"


def rc(address, actions, before=None, after=None, importing=False, after_unknown=None):
    change = {"actions": actions, "before": before, "after": after, "after_unknown": after_unknown or {}}
    if importing:
        change["importing"] = {"id": "x"}
    return {"address": address, "change": change}


def esm(n):
    return {"batch_size": 10, "scaling_config": [{"maximum_concurrency": n}]}


ALLOW = [parse_allow(f"{ESM}:scaling_config.0.maximum_concurrency=20->25")]


def plan(*changes, **top):
    return {"complete": True, "errored": False, "applyable": True, "resource_changes": list(changes), **top}


class Gate(unittest.TestCase):
    def test_imports_only_pass(self):
        self.assertEqual(check(plan(rc("aws_sqs_queue.events", ["no-op"], importing=True)), []), [])

    def test_approved_concurrency_change_passes(self):
        self.assertEqual(check(plan(rc(ESM, ["update"], esm(20), esm(25), importing=True)), ALLOW), [])

    def test_other_attribute_on_same_resource_refused(self):
        after = esm(25)
        after["batch_size"] = 5
        self.assertTrue(any("beyond" in p for p in check(plan(rc(ESM, ["update"], esm(20), after)), ALLOW)))

    def test_wrong_values_refused(self):
        self.assertTrue(check(plan(rc(ESM, ["update"], esm(4), esm(25))), ALLOW))

    def test_any_other_update_refused(self):
        self.assertTrue(check(plan(rc("aws_sqs_queue.events", ["update"], {"v": 1820}, {"v": 1800})), []))

    def test_create_and_replace_refused(self):
        for actions in (["create"], ["delete"], ["delete", "create"], ["create", "delete"]):
            self.assertTrue(check(plan(rc("aws_iam_role.pipeline", actions)), []))

    def test_approved_change_missing_refused(self):
        self.assertTrue(any("not in the plan" in p for p in check(plan(rc(ESM, ["no-op"], esm(25), esm(25))), ALLOW)))

    def test_incomplete_plan_refused_even_with_allowed_change(self):
        p = plan(rc(ESM, ["update"], esm(20), esm(25)), complete=False)
        self.assertTrue(any("not complete" in x for x in check(p, ALLOW)))

    def test_missing_complete_field_refused(self):
        p = plan(rc("aws_sqs_queue.events", ["no-op"]))
        del p["complete"]
        self.assertTrue(check(p, []))

    def test_errored_and_unapplyable_refused(self):
        self.assertTrue(check(plan(errored=True), []))
        self.assertTrue(check(plan(applyable=False), []))

    def test_unknown_after_value_on_allowed_resource_refused(self):
        p = plan(rc(ESM, ["update"], esm(20), esm(25), after_unknown={"tags_all": True}))
        self.assertTrue(any("unknown" in x for x in check(p, ALLOW)))

    def test_nested_unknown_refused(self):
        p = plan(rc(ESM, ["update"], esm(20), esm(25), after_unknown={"scaling_config": [{"maximum_concurrency": True}]}))
        self.assertTrue(check(p, ALLOW))

    def test_unrelated_change_next_to_allowed_one_refused(self):
        p = plan(rc(ESM, ["update"], esm(20), esm(25)), rc("aws_kms_key_policy.transcripts", ["update"], {"policy": "a"}, {"policy": "b"}))
        self.assertTrue(any("aws_kms_key_policy.transcripts" in x for x in check(p, ALLOW)))

    def test_deferred_data_read_refused(self):
        self.assertTrue(check(plan(rc("data.aws_lambda_function.pipeline", ["read"])), []))


if __name__ == "__main__":
    unittest.main()
