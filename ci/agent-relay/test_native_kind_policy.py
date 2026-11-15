"""Native kind render keeps namespace denial and scopes the edge exception."""
from pathlib import Path
import subprocess
import sys
import unittest
import yaml

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'ci/agent-relay/kind'))
import test_stack as kind_profiles  # the kind base layer renders only through the native composition


class NativeKindPolicy(unittest.TestCase):
    def render(self, native=True):
        # serve selects native routing; the control-only bootstrap phase has none.
        return kind_profiles.Profiles().render('serve' if native else 'control')

    def test_control_phase_without_native_routing_has_no_edge_exception(self):
        docs=self.render(False)
        self.assertFalse(any(d['metadata']['name']=='kind-control-native-readback-egress' for d in docs))

    def test_only_control_api_can_reach_traefik_secure_port(self):
        docs=self.render()
        denial=next(d for d in docs if d['kind']=='NetworkPolicy' and d['metadata']['name']=='kind-no-external-egress')
        self.assertEqual(denial['spec']['podSelector'],{})
        self.assertFalse(any('ipBlock' in target for rule in denial['spec']['egress'] for target in rule.get('to',[])))
        policy=next(d for d in docs if d['kind']=='NetworkPolicy' and d['metadata']['name']=='kind-control-native-readback-egress')
        control=next(d for d in docs if d['kind']=='Deployment' and d['metadata']['name']=='relay-control')
        self.assertEqual(policy['spec']['podSelector']['matchLabels'],control['spec']['selector']['matchLabels'])
        self.assertEqual(policy['spec']['policyTypes'],['Egress'])
        self.assertEqual(policy['spec']['egress'],[{'to':[{'namespaceSelector':{'matchLabels':{'kubernetes.io/metadata.name':'kind-edge'}},'podSelector':{'matchLabels':{'app.kubernetes.io/instance':'kind-edge-kind-edge','app.kubernetes.io/name':'traefik'}}}],'ports':[{'protocol':'TCP','port':8443}]}])
        run=subprocess.run(['kubeconform','-strict','-summary'],input=yaml.safe_dump(policy),text=True,capture_output=True)
        self.assertEqual(run.returncode,0,run.stdout+run.stderr)


if __name__=='__main__':unittest.main()
