"""Common-role native reads only. No network/IAM mutations or es permission fallback."""
import json
import time
from contract import native_error, require
from files import read, save, sha

def value(runner, service, operation, *args):
    return json.loads(runner.aws(service, operation, *args).stdout)

def rules(groups, v):
    byid = {g['GroupId']: g for g in groups}
    require(set(byid) == {v['domain_security_group_id'], *v['client_security_group_ids']}, 'Missing/extra native SG prerequisites')
    require(all(g['OwnerId'] == v['account_id'] and g['VpcId'] == v['vpc_id'] for g in groups), 'Foreign SG owner/VPC')
    target = byid[v['domain_security_group_id']]
    require(target['GroupName'] != 'default' and target['IpPermissions'], 'Exclusive domain SG cannot be default or unconfigured')
    peers = set()
    for rule in target['IpPermissions']:
        require(rule.get('IpProtocol') == 'tcp' and rule.get('FromPort') == 443 and rule.get('ToPort') == 443 and not any(rule.get(k) for k in ['IpRanges', 'Ipv6Ranges', 'PrefixListIds']), 'Only peer-group HTTPS ingress is permitted')
        require(rule.get('UserIdGroupPairs'), 'Missing HTTPS peer group')
        for peer in rule['UserIdGroupPairs']:
            require(peer['GroupId'] in v['client_security_group_ids'] and peer['UserId'] == v['account_id'], 'Foreign or unapproved HTTPS peer')
            peers.add(peer['GroupId'])
    require(peers == set(v['client_security_group_ids']), 'Exact client group set required')

def interfaces(runner):
    # CLI pagination remains enabled; reject any residual token/incomplete shape.
    page = value(runner, 'ec2', 'describe-network-interfaces', '--filters', 'Name=group-id,Values=' + runner.v['domain_security_group_id'])
    require(isinstance(page.get('NetworkInterfaces'), list) and not page.get('NextToken'), 'Incomplete ENI inventory')
    return page['NetworkInterfaces']

def network(runner, operation):
    require(not runner.env.get('PIPPEN_SANDBOX_CAPABILITY_CONTEXT'), 'ENI/DNS/SLR reads use ordinary common-role execution, never capability-role grants')
    identity = runner.identity('common'); v = runner.v
    if operation == 'network-before':
        require(not runner.path('create.packet.json').exists() and not runner.path('network-before.json').exists(), 'Do not replace the immutable creation baseline')
        vpcs = value(runner, 'ec2', 'describe-vpcs', '--vpc-ids', v['vpc_id'])['Vpcs']
        require(len(vpcs) == 1 and vpcs[0]['OwnerId'] == v['account_id'], 'Foreign VPC')
        for attribute, field in [('enableDnsSupport', 'EnableDnsSupport'), ('enableDnsHostnames', 'EnableDnsHostnames')]:
            require(value(runner, 'ec2', 'describe-vpc-attribute', '--vpc-id', v['vpc_id'], '--attribute', attribute)[field]['Value'] is True, 'VPC DNS prerequisites disabled')
        subnets = value(runner, 'ec2', 'describe-subnets', '--subnet-ids', *v['subnet_ids'])['Subnets']
        require(len(subnets) == len(v['subnet_ids']) and {s['SubnetId'] for s in subnets} == set(v['subnet_ids']) and len({s['AvailabilityZone'] for s in subnets}) == len(subnets), 'Private AZ subnet inventory mismatch')
        require(all(s['OwnerId'] == v['account_id'] and s['VpcId'] == v['vpc_id'] and not s['MapPublicIpOnLaunch'] and s['AvailableIpAddressCount'] >= 8 for s in subnets), 'Foreign/public/exhausted private subnet')
        groups = value(runner, 'ec2', 'describe-security-groups', '--group-ids', v['domain_security_group_id'], *v['client_security_group_ids'])['SecurityGroups']
        rules(groups, v)
        require(interfaces(runner) == [], 'Domain SG is not exclusive: refuse pre-existing service/workload ENIs')
        role = value(runner, 'iam', 'get-role', '--role-name', 'AWSServiceRoleForAmazonOpenSearchService')['Role']
        require(role['Arn'] == f"arn:aws:iam::{v['account_id']}:role/aws-service-role/opensearchservice.amazonaws.com/AWSServiceRoleForAmazonOpenSearchService", 'Trusted existing OpenSearch service-linked-role prerequisite missing; never create it here')
        external_roles = {}
        for kind, arn in v['roles'].items():
            existing = value(runner, 'iam', 'get-role', '--role-name', arn.rsplit('/', 1)[1])['Role']
            require(existing['Arn'] == arn and existing.get('RoleId'), 'External data role is missing or has a different path/account')
            external_roles[kind] = {key: existing.get(key) for key in ['Arn', 'RoleId', 'PermissionsBoundary']}
        receipt = {'ok': True, 'observed_at': time.time(), 'inputs_sha256': sha(runner.variables), 'caller': identity, 'subnets': subnets, 'groups': groups, 'external_roles': external_roles, 'service_linked_role_arn': role['Arn'], 'domain_group_eni_baseline': []}
        save(runner.path('network-before.json'), receipt)
        return {'ok': True, 'scope': 'common-role read-only DNS/subnet/SG/empty ENI/SLR prerequisites; no domain absence claim'}
    original = runner.packet(); runner.immutable(original)
    _, context_sha256 = runner.sealed_context(original) # Provenance only: expired context may still support common-role read-only retirement checks.
    created = read(runner.path('created.json'))
    require(created['original_packet_sha256'] == sha(runner.path('create.packet.json')), 'Foreign creation capture')
    if operation == 'network-created':
        require(read(runner.path('phase.json')).get('status') == 'captured' and not runner.path('network-created.json').exists(), 'Capture service ENIs once after complete domain capture')
        rows = interfaces(runner)
        require(0 < len(rows) <= 8 and len({row['NetworkInterfaceId'] for row in rows}) == len(rows), 'Missing/duplicate/unbounded service ENIs')
        require(all(row['OwnerId'] == v['account_id'] and row['VpcId'] == v['vpc_id'] and row['SubnetId'] in v['subnet_ids'] and row.get('RequesterManaged') is True and {g['GroupId'] for g in row['Groups']} == {v['domain_security_group_id']} for row in rows), 'Unknown ENI producer/owner/network; quarantine rather than adopt or detach')
        save(runner.path('network-created.json'), {'ok': True, 'context_sha256': context_sha256, 'caller': identity, 'domain_name': created['domain_name'], 'domain_id': created['native_domain_id'], 'interfaces': rows, 'original_packet_sha256': created['original_packet_sha256']})
        return {'ok': True, 'service_eni_count': len(rows), 'ownership_basis': 'exclusive empty SG baseline + captured exact domain network + service-managed interfaces; no tag-only claim'}
    require(operation == 'network-absence' and read(runner.path('phase.json')).get('status') == 'destroyed-pending-native-absence', 'Terraform destroy required before native absence')
    captured = read(runner.path('network-created.json'))
    require(captured.get('context_sha256') == context_sha256, 'Foreign ENI context seal')
    require(captured['original_packet_sha256'] == created['original_packet_sha256'] and captured['domain_id'] == created['native_domain_id'], 'Foreign ENI capture')
    reviewed = read(runner.path('destroy.packet.json'))
    require(reviewed['created_sha256'] == sha(runner.path('created.json')) and reviewed['network_created_sha256'] == sha(runner.path('network-created.json')), 'Physical inventory differs from reviewed teardown')
    require(interfaces(runner) == [], 'Owned domain SG still has service ENIs; never force delete or touch unrelated interfaces')
    checks = {}
    for row in captured['interfaces']:
        identifier = row['NetworkInterfaceId']
        response = runner.aws('ec2', 'describe-network-interfaces', '--network-interface-ids', identifier, check=False)
        checks[identifier] = response.returncode != 0 and native_error(response.stderr, 'DescribeNetworkInterfaces', 'InvalidNetworkInterfaceID.NotFound')
    require(checks and all(checks.values()), 'Exact captured ENI absence unproved; Denied/empty/refresh errors do not count')
    receipt = {'ok': True, 'context_sha256': context_sha256, 'caller': identity, 'checks': checks, 'original_packet_sha256': created['original_packet_sha256']}
    domain = read(runner.path('domain-absence.json'))
    require(domain.get('ok') is True and domain.get('context_sha256') == context_sha256 and domain['original_packet_sha256'] == created['original_packet_sha256'], 'Separate capability-role typed domain absence still required')
    save(runner.path('network-absence.json'), receipt)
    return {'ok': True, 'scope': 'exact disposable domain and captured service ENIs only; external VPC/subnets/SGs/roles/SLR preserved'}
