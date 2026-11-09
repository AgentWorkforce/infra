"""Native kind render keeps namespace denial and scopes the edge exception."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('native_routing_fixtures',ROOT/'ci/sessions-pipeline-native-routing/test_native_routing.py')
fixtures=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixtures)


class NativeKindPolicy(unittest.TestCase):
    def render(self, native=True):
        values=yaml.safe_load((ROOT/'charts/agent-relay/values-kind-core.yaml').read_text())
        if native:
            fixtures.merge(values['sessions-pipeline'], fixtures.fixture())
            for name in ('runtimeRole', 'functionDefaultRevoke'):
                values['sessions-pipeline'][name]['bootstrapJob']['enabled']=False
            api=fixtures.umbrella_fixture()['relay-control']
            fixtures.merge(values['relay-control'], api)
            values['relayhistory']['ingress']['enabled']=False
            values['sessions-pipeline']['alleyoop']['auth']['historyOrigin']=fixtures.ORIGIN
            values['relayhistory']['relayauth']['historyOrigin']=fixtures.ORIGIN
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'values.json';path.write_text(json.dumps(values))
            result=subprocess.run(['helm','template','agent-relay','charts/agent-relay','-n','agent-relay','-f',str(path)],cwd=ROOT,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        return [d for d in yaml.safe_load_all(result.stdout) if d]

    def test_default_profile_has_no_edge_exception(self):
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
