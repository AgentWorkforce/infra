"""Exercise the real legacy up entry point before its first side effect."""
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, patch

from native_network import refuse_legacy_bootstrap
from stack import Stack


class NativeBootstrapGuard(unittest.TestCase):
    def test_all_native_selections_refuse_before_legacy_docker_or_ready_changes(self):
        for profile in ('core', 'addons'):
            for slot in ('readApi', 'ingestEdge', 'nativeConsumer', 'nativeRouting'):
                with self.subTest(profile=profile, slot=slot), tempfile.TemporaryDirectory() as directory:
                    state=Path(directory);ready=state/'ready.json';ready.write_text('existing-receipt')
                    values=state/'values.json';values.write_text(json.dumps({'sessions-pipeline':{slot:{'enabled':True}}}))
                    stack=SimpleNamespace(profile=profile,state=state,values_args=Mock(return_value=['-f',values]),docker=Mock())
                    with patch('stack.shutil.which',return_value='/owned/test-tool'):
                        with self.assertRaisesRegex(ValueError,'legacy kind-up refused before'):
                            Stack.up(stack)
                    stack.docker.assert_not_called()
                    self.assertEqual(ready.read_text(),'existing-receipt')

    def test_normal_disabled_selection_still_reaches_the_legacy_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            values=Path(directory)/'values.json';values.write_text('{}')
            stack=SimpleNamespace(values_args=Mock(return_value=['-f',values]),docker=Mock(side_effect=RuntimeError('legacy-entry-observed')))
            with patch('stack.shutil.which',return_value='/owned/test-tool'):
                with self.assertRaisesRegex(RuntimeError,'legacy-entry-observed'):
                    Stack.up(stack)

    def test_overlay_order_and_invalid_types_cannot_bypass_selection(self):
        refuse_legacy_bootstrap([{'sessions-pipeline':{'readApi':{'enabled':True}}},{'sessions-pipeline':{'readApi':{'enabled':False}}}])
        for invalid in ('true', 'false', 1, None):
            with self.subTest(invalid=invalid):
                with self.assertRaisesRegex(ValueError,'must be booleans'):
                    refuse_legacy_bootstrap([{'sessions-pipeline':{'readApi':{'enabled':invalid}}}])


if __name__=='__main__':unittest.main()
