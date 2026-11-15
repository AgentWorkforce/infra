"""The retired single-phase kind-up entry point refuses before any side effect."""
import contextlib
import io
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, patch

import stack
from stack import Stack, StackError


class RetiredLegacyEntry(unittest.TestCase):
    def test_native_and_disabled_selections_refuse_before_docker_or_ready_changes(self):
        for profile in ('core', 'addons'):
            for slot in (None, 'readApi', 'ingestEdge', 'nativeConsumer', 'nativeRouting'):
                with self.subTest(profile=profile, slot=slot), tempfile.TemporaryDirectory() as directory:
                    state=Path(directory);ready=state/'ready.json';ready.write_text('existing-receipt')
                    values=state/'values.json';values.write_text(json.dumps({'sessions-pipeline':{slot:{'enabled':True}}} if slot else {}))
                    local=SimpleNamespace(profile=profile,state=state,values_args=Mock(return_value=['-f',values]),
                                          docker=Mock(),cmd=Mock(),k=Mock())
                    with self.assertRaisesRegex(StackError,'retired with the standalone RelayHistory server'):
                        Stack.up(local)
                    for call in (local.docker,local.cmd,local.k,local.values_args):
                        call.assert_not_called()
                    self.assertEqual(ready.read_text(),'existing-receipt')

    def test_retired_actions_refuse_before_creating_state(self):
        for action in ('up', 'render', 'reconcile-names'):
            with self.subTest(action=action), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);stderr=io.StringIO()
                with patch.object(stack,'ROOT',root),patch('sys.argv',['stack.py',action,'--profile','core']),\
                        patch.object(stack.Stack,'__init__',side_effect=AssertionError('state touched')),\
                        contextlib.redirect_stderr(stderr):
                    self.assertEqual(stack.main(),1)
                self.assertIn('make local-up',stderr.getvalue())
                self.assertEqual(list(root.iterdir()),[])


if __name__=='__main__':unittest.main()
