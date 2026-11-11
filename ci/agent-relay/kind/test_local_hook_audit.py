import copy
import unittest

from local_hook_audit import snapshot, verify


class HookAuditTests(unittest.TestCase):
    def setUp(self):
        self.settings = {"hooks": {"PreToolUse": [{"matcher": "*", "hooks": [
            {"type": "command", "command": "probe --socket desktop.q7m2k9.sock"},
            {"type": "command", "command": "probe --socket desktop.jhs.sock", "timeout": 10},
            {"type": "command", "command": "my-own-hook"}]}]}}

    def without_kind(self):
        after = copy.deepcopy(self.settings)
        after["hooks"]["PreToolUse"][0]["hooks"].pop(0)
        return after

    def test_removing_only_kind_from_a_mixed_group_preserves_other_hooks(self):
        before = snapshot(self.settings, ["jhs"])
        after = snapshot(self.without_kind(), ["jhs"])
        verify(before, after)
        self.assertEqual(before["kindHookCount"], 1)
        self.assertEqual(after["protectedHookCount"], 1)
        self.assertNotIn("desktop.jhs.sock", str(before))

    def test_changed_protected_hook_or_matcher_is_refused(self):
        for change in ("command", "matcher"):
            after = self.without_kind()
            group = after["hooks"]["PreToolUse"][0]
            if change == "command":
                group["hooks"][0]["command"] += " changed"
            else:
                group["matcher"] = "different"
            with self.assertRaisesRegex(ValueError, "hooks changed"):
                verify(snapshot(self.settings, ["jhs"]), snapshot(after, ["jhs"]))

    def test_changing_an_unrelated_hook_is_also_refused(self):
        after = self.without_kind()
        after["hooks"]["PreToolUse"][0]["hooks"][1]["command"] = "changed-user-hook"
        with self.assertRaisesRegex(ValueError, "hooks changed"):
            verify(snapshot(self.settings, ["jhs"]), snapshot(after, ["jhs"]))

    def test_leftover_kind_or_ambiguous_ownership_is_refused(self):
        before = snapshot(self.settings, ["jhs"])
        with self.assertRaisesRegex(ValueError, "Kind hooks remain"):
            verify(before, before)
        self.settings["hooks"]["PreToolUse"][0]["hooks"][0]["command"] += " jhs"
        with self.assertRaisesRegex(ValueError, "both Kind"):
            snapshot(self.settings, ["jhs"])

    def test_changing_the_protected_marker_is_refused(self):
        with self.assertRaisesRegex(ValueError, "hooks changed"):
            verify(snapshot(self.settings, ["jhs"]), snapshot(self.without_kind(), ["different"]))


if __name__ == "__main__":
    unittest.main()
