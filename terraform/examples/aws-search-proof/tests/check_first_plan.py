"""Validate compiled native mock first-create product configuration, offline.

Test UI output is not a saved-plan/prior-state history object. This calls only
the same fixed configuration checks used AFTER strict runtime history admission;
it never establishes history, ownership or apply authority.

AWS mock providers leave computed tags_all unknown or empty even though AWS
planning derives it from the explicit tags/default-tags configuration. The ONLY
substitution below is that deterministic mock field. No runtime normalization,
nested identity/region/partition override or policy/security substitution exists.
"""
from pathlib import Path
import json
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'proof'))
from contract import DOMAIN, POLICY, _configuration_changes, require
from test_contract import inputs

result = subprocess.run([sys.argv[1], 'test', '-filter=tests/proof.tftest.hcl', '-json', '-verbose'], cwd=root, capture_output=True, text=True, timeout=120)
require(result.returncode == 0, 'Native mock test failed; inspect Terraform/OpenTofu test output')
events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
plans = [event['test_plan'] for event in events if event.get('type') == 'test_plan']
require(plans, 'Native mock first-plan event missing')
plan = plans[0]
rows = {row['address']: row for row in plan['resource_changes']}
policy = rows[POLICY]['change']
require(isinstance(policy['after'].get('access_policies'), str) and not policy.get('after_unknown', {}).get('access_policies'), 'Permission-bearing policy is unknown in the native first-create plan')
domain = rows[DOMAIN]['change']
substitutions = []
if domain['after'].get('tags_all') != domain['after']['tags']:
    domain['after']['tags_all'] = domain['after']['tags']
    substitutions.append(DOMAIN + '.tags_all=explicit_tags (test only; generic mock computed metadata)')
v = inputs(); v['subnet_ids'] = ['subnet-a']; v['vpc_id'] = 'vpc-example' # Existing HCL fixture.
_configuration_changes(plan, v) # Same fixed payload checks; NOT saved-plan/history admission.
print(json.dumps({'ok': True, 'first_create_policy_json_known': True, 'native_compiled_configuration_passes': True, 'history_admission_tested': False, 'scope': 'native test_plan UI compiled policy/configuration only; no saved-plan/history/ownership proof', 'test_only_substitutions': substitutions, 'remaining_domain_unknown_fields': domain.get('after_unknown', {}), 'remaining_policy_unknown_fields': policy.get('after_unknown', {}), 'aws_calls': 0}))
