"""Order/side-effect tests for explicit network preparation; no cluster calls."""
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, patch

import edge
import native_network
from stack import Stack, StackError
from test_native_network import values


class PrepareCommand(unittest.TestCase):
    def fixture(self, directory):
        state = Path(directory)
        selected = state / 'selected.json'
        selected.write_text(json.dumps(values()))
        for name in ('ready.json', 'images.json', 'values.json', 'proof.json'):
            (state / name).write_text('original-' + name)
        order = []
        stack = SimpleNamespace(profile='core', state=state,
            docker=Mock(side_effect=lambda **kw: order.append('docker')),
            require_owned_cluster=Mock(side_effect=lambda: order.append('owned')),
            dependencies=Mock(side_effect=lambda: order.append('dependencies')),
            cmd=Mock(side_effect=lambda *args: order.append('render')))
        return stack, selected, order

    def test_manual_resource_refusal_precedes_gateway_and_metadata_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            stack, selected, order = self.fixture(directory)
            before = {p.name: p.read_bytes() for p in stack.state.iterdir()}
            with patch.object(native_network, 'preflight', side_effect=ValueError('manual resource')) as preflight, patch.object(edge, 'install') as gateway, patch.object(native_network, 'ensure') as ensure:
                with self.assertRaisesRegex(ValueError, 'manual resource'):
                    Stack.prepare_native_network(stack, selected)
            preflight.assert_called_once()
            gateway.assert_not_called(); ensure.assert_not_called()
            stack.dependencies.assert_not_called(); stack.cmd.assert_not_called()
            self.assertEqual(before, {p.name: p.read_bytes() for p in stack.state.iterdir()})

    def test_success_only_writes_proposed_values_after_qualified_service(self):
        with tempfile.TemporaryDirectory() as directory:
            stack, selected, order = self.fixture(directory)
            before = {p.name: p.read_bytes() for p in stack.state.iterdir()}
            proposed = values(); proposed['testAllocatedMapping'] = 'owned observation only'
            with patch.object(native_network, 'preflight', side_effect=lambda *args: order.append('preflight')), patch.object(edge, 'install', side_effect=lambda *args, **kw: order.append('gateway')) as gateway, patch.object(native_network, 'ensure', side_effect=lambda *args: order.append('ensure') or {'typed': 'observation'}), patch.object(native_network, 'selected_values', return_value=proposed), redirect_stdout(io.StringIO()):
                Stack.prepare_native_network(stack, selected)
            self.assertEqual(order, ['docker', 'owned', 'preflight', 'dependencies', 'render', 'gateway', 'ensure', 'render'])
            self.assertFalse(gateway.call_args.kwargs['wait_for_route'])
            self.assertEqual(json.loads((stack.state/'native-network-values.json').read_text()), proposed)
            self.assertEqual((stack.state/'native-network-values.json').stat().st_mode & 0o777, 0o600)
            for name, content in before.items():
                self.assertEqual((stack.state/name).read_bytes(), content)

    def test_disabled_selection_is_not_network_creation_authority(self):
        with tempfile.TemporaryDirectory() as directory:
            stack, selected, order = self.fixture(directory)
            selected.write_text(json.dumps({'sessions-pipeline': {'nativeRouting': {'enabled': False}}}))
            with self.assertRaisesRegex(StackError, 'requires an enabled nativeRouting'):
                Stack.prepare_native_network(stack, selected)
            self.assertEqual(order, [])

    def test_inputs_must_be_explicit_regular_files(self):
        with tempfile.TemporaryDirectory() as directory:
            stack, selected, order = self.fixture(directory)
            link = stack.state/'linked.json'; link.symlink_to(selected)
            with self.assertRaisesRegex(StackError, 'regular selected-values'):
                Stack.prepare_native_network(stack, link)
            self.assertEqual(order, [])

    def test_addons_uses_core_then_addons_then_selected_values_for_both_renders(self):
        with tempfile.TemporaryDirectory() as directory:
            stack, selected, order = self.fixture(directory)
            stack.profile = 'addons'; selected.write_text(json.dumps(values('addons')))
            with patch.object(native_network, 'preflight'), patch.object(edge, 'install'), patch.object(native_network, 'ensure'), patch.object(native_network, 'selected_values', return_value=values('addons')), redirect_stdout(io.StringIO()):
                Stack.prepare_native_network(stack, selected)
            for call in stack.cmd.call_args_list:
                args = call.args[0]
                inputs = [str(args[i+1]) for i,x in enumerate(args) if x == '-f']
                self.assertEqual(len(inputs), 3)
                self.assertTrue(inputs[0].endswith('values-kind-core.yaml'))
                self.assertTrue(inputs[1].endswith('values-kind-addons.yaml'))


if __name__ == '__main__':
    unittest.main()
