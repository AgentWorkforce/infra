import copy
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from contract import native_error
from files import save, sha
from network import interfaces, network, rules
from test_contract import inputs

def groups(v):
    base={'OwnerId':v['account_id'],'VpcId':v['vpc_id']}
    return [{**base,'GroupId':'sg-client','GroupName':'client','IpPermissions':[]}, {**base,'GroupId':'sg-domain','GroupName':'exclusive-domain','IpPermissions':[{'IpProtocol':'tcp','FromPort':443,'ToPort':443,'UserIdGroupPairs':[{'GroupId':'sg-client','UserId':v['account_id']}]}]}]

class Network(unittest.TestCase):
    def test_only_exact_private_https_peer_ingress(self):
        v=inputs();rules(groups(v),v)
        for variant in ['world','foreign','port','default','missing']:
            data=groups(v);d=data[1]
            if variant=='world':d['IpPermissions'][0]['IpRanges']=[{'CidrIp':'0.0.0.0/0'}]
            if variant=='foreign':d['IpPermissions'][0]['UserIdGroupPairs'][0]['UserId']='222222222222'
            if variant=='port':d['IpPermissions'][0]['FromPort']=80
            if variant=='default':d['GroupName']='default'
            if variant=='missing':d['IpPermissions']=[]
            with self.subTest(variant=variant),self.assertRaises(RuntimeError):rules(data,v)

    def test_partial_eni_pages_and_denial_are_not_empty(self):
        for page in [{},{'NetworkInterfaces':[],'NextToken':'more'}]:
            runner=SimpleNamespace(v=inputs(),aws=lambda *a,**k:SimpleNamespace(stdout=json.dumps(page)))
            with self.assertRaises(RuntimeError):interfaces(runner)

    def test_profile_does_not_gain_common_eni_read_permissions(self):
        r=SimpleNamespace(env={'PIPPEN_SANDBOX_CAPABILITY_CONTEXT':'synthetic'})
        with self.assertRaisesRegex(RuntimeError,'ordinary common-role'):network(r,'network-before')

    def test_network_created_captures_only_complete_exclusive_service_interfaces(self):
        for variant in ['valid', 'empty', 'duplicate', 'foreign-owner', 'foreign-vpc', 'foreign-subnet', 'foreign-group', 'unmanaged', 'truncated']:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                v = inputs()
                save(root / 'create.packet.json', {'fixture': 'synthetic immutable create'})
                packet_sha = sha(root / 'create.packet.json')
                save(root / 'created.json', {'original_packet_sha256': packet_sha, 'native_domain_id': 'fixture-domain-id', 'domain_name': 'fixture-domain'})
                save(root / 'phase.json', {'status': 'captured'})
                row = {'NetworkInterfaceId': 'eni-fixture', 'OwnerId': v['account_id'], 'VpcId': v['vpc_id'], 'SubnetId': v['subnet_ids'][0], 'RequesterManaged': True, 'Groups': [{'GroupId': v['domain_security_group_id']}]}
                if variant == 'foreign-owner': row['OwnerId'] = '222222222222'
                if variant == 'foreign-vpc': row['VpcId'] = 'vpc-other'
                if variant == 'foreign-subnet': row['SubnetId'] = 'subnet-other'
                if variant == 'foreign-group': row['Groups'].append({'GroupId': 'sg-other'})
                if variant == 'unmanaged': row['RequesterManaged'] = False
                rows = [] if variant == 'empty' else [row, row] if variant == 'duplicate' else [row]
                page = {'NetworkInterfaces': rows, **({'NextToken': 'more'} if variant == 'truncated' else {})}
                def aws(*args, **kwargs):
                    self.assertEqual(args, ('ec2', 'describe-network-interfaces', '--filters', 'Name=group-id,Values=' + v['domain_security_group_id']))
                    return SimpleNamespace(returncode=0, stdout=json.dumps(page), stderr='')
                runner = SimpleNamespace(env={}, v=v, path=lambda name: root / name, identity=lambda mode: {'fixture': mode}, packet=lambda: {'fixture': 'original'}, immutable=lambda original: None, sealed_context=lambda original: ({}, 'c' * 64), aws=aws)
                if variant == 'valid':
                    self.assertEqual(network(runner, 'network-created')['service_eni_count'], 1)
                    capture = json.loads((root / 'network-created.json').read_text())
                    self.assertEqual(capture['interfaces'], rows)
                    self.assertEqual(capture['original_packet_sha256'], packet_sha)
                    self.assertEqual(capture['domain_id'], 'fixture-domain-id')
                    self.assertEqual(capture['context_sha256'], 'c' * 64)
                    with self.assertRaisesRegex(RuntimeError, 'Capture service ENIs once'):
                        network(runner, 'network-created')
                else:
                    with self.assertRaises(RuntimeError): network(runner, 'network-created')
                    self.assertFalse((root / 'network-created.json').exists())

    def test_network_success_is_published_only_after_domain_and_eni_absence(self):
        for variant in ['missing-domain', 'malformed-domain', 'false-domain', 'foreign-context', 'foreign-packet', 'eni-denied', 'eni-survives', 'valid']:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                context_sha = 'c' * 64
                save(root / 'create.packet.json', {'fixture': 'synthetic immutable create'})
                packet_sha = sha(root / 'create.packet.json')
                save(root / 'created.json', {'original_packet_sha256': packet_sha, 'native_domain_id': 'fixture-domain-id'})
                save(root / 'network-created.json', {'context_sha256': context_sha, 'original_packet_sha256': packet_sha, 'domain_id': 'fixture-domain-id', 'interfaces': [{'NetworkInterfaceId': 'eni-fixture'}]})
                save(root / 'destroy.packet.json', {'created_sha256': sha(root / 'created.json'), 'network_created_sha256': sha(root / 'network-created.json')})
                save(root / 'phase.json', {'status': 'destroyed-pending-native-absence'})
                domain = {'ok': True, 'context_sha256': context_sha, 'original_packet_sha256': packet_sha}
                if variant == 'false-domain': domain['ok'] = False
                if variant == 'foreign-context': domain['context_sha256'] = 'd' * 64
                if variant == 'foreign-packet': domain['original_packet_sha256'] = 'e' * 64
                if variant == 'malformed-domain': (root / 'domain-absence.json').write_text('{')
                elif variant != 'missing-domain': save(root / 'domain-absence.json', domain)
                calls = []
                def aws(*args, **kwargs):
                    calls.append(args)
                    if '--filters' in args:
                        return SimpleNamespace(returncode=0, stdout=json.dumps({'NetworkInterfaces': []}), stderr='')
                    self.assertEqual(args, ('ec2', 'describe-network-interfaces', '--network-interface-ids', 'eni-fixture'))
                    error = 'AccessDenied' if variant == 'eni-denied' else 'An error occurred (InvalidNetworkInterfaceID.NotFound) when calling the DescribeNetworkInterfaces operation'
                    if variant == 'eni-survives': return SimpleNamespace(returncode=0, stdout=json.dumps({'NetworkInterfaces': [{'NetworkInterfaceId': 'eni-fixture'}]}), stderr='')
                    return SimpleNamespace(returncode=255, stdout='', stderr=error)
                runner = SimpleNamespace(env={}, v=inputs(), path=lambda name: root / name, identity=lambda mode: {'fixture': mode}, packet=lambda: {'fixture': 'original'}, immutable=lambda original: None, sealed_context=lambda original: ({}, context_sha), aws=aws)
                if variant == 'valid':
                    self.assertTrue(network(runner, 'network-absence')['ok'])
                    receipt = json.loads((root / 'network-absence.json').read_text())
                    self.assertIs(receipt['ok'], True)
                    self.assertEqual(receipt['context_sha256'], context_sha)
                    self.assertEqual(receipt['original_packet_sha256'], packet_sha)
                    self.assertEqual(receipt['checks'], {'eni-fixture': True})
                else:
                    with self.assertRaises((RuntimeError, FileNotFoundError, json.JSONDecodeError)):
                        network(runner, 'network-absence')
                    self.assertFalse((root / 'network-absence.json').exists(), 'A refused retirement must not publish a success receipt')

if __name__ == '__main__': unittest.main()
