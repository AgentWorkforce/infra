import unittest

from zero_diff_gate import check, parse_allow

ESM = "aws_lambda_event_source_mapping.events"


def rc(address, actions, before=None, after=None, importing=False):
    change = {"actions": actions, "before": before, "after": after}
    if importing:
        change["importing"] = {"id": "x"}
    return {"address": address, "change": change}


def esm(n):
    return {"batch_size": 10, "scaling_config": [{"maximum_concurrency": n}]}


ALLOW = [parse_allow(f"{ESM}:scaling_config.0.maximum_concurrency=20->25")]


class Gate(unittest.TestCase):
    def test_imports_only_pass(self):
        self.assertEqual(check({"resource_changes": [rc("aws_sqs_queue.events", ["no-op"], importing=True)]}, []), [])

    def test_approved_concurrency_change_passes(self):
        plan = {"resource_changes": [rc(ESM, ["update"], esm(20), esm(25), importing=True)]}
        self.assertEqual(check(plan, ALLOW), [])

    def test_other_attribute_on_same_resource_refused(self):
        after = esm(25)
        after["batch_size"] = 5
        plan = {"resource_changes": [rc(ESM, ["update"], esm(20), after)]}
        self.assertTrue(any("beyond" in p for p in check(plan, ALLOW)))

    def test_wrong_values_refused(self):
        plan = {"resource_changes": [rc(ESM, ["update"], esm(4), esm(25))]}
        self.assertTrue(check(plan, ALLOW))

    def test_any_other_update_refused(self):
        plan = {"resource_changes": [rc("aws_sqs_queue.events", ["update"], {"v": 1820}, {"v": 1800})]}
        self.assertTrue(check(plan, []))

    def test_create_and_replace_refused(self):
        for actions in (["create"], ["delete"], ["delete", "create"], ["create", "delete"]):
            self.assertTrue(check({"resource_changes": [rc("aws_iam_role.pipeline", actions)]}, []))

    def test_approved_change_missing_refused(self):
        plan = {"resource_changes": [rc(ESM, ["no-op"], esm(25), esm(25))]}
        self.assertTrue(any("not in the plan" in p for p in check(plan, ALLOW)))


if __name__ == "__main__":
    unittest.main()
