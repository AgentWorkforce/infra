"""Terraform-only mock state-history regression, never an AWS plan/apply.

Terraform 1.16's test state_key shares the legacy fixture state with this module.
The final test and mock teardown MUST fail at the still-present literal guard.
OpenTofu 1.11 lacks state_key; its portable module tests are run separately.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile

module = Path(__file__).resolve().parents[1]
repo = module.parents[3]
baseline = 'd3040fa209ef5c90ce61bde2a776f783c01cfaba'
engine = sys.argv[1]
scratch = module / '.terraform'; scratch.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='mock-history-', dir=scratch) as directory:
    root = Path(directory); fixture = root / 'fixtures/legacy'; fixture.mkdir(parents=True)
    for name in ['main.tf', 'outputs.tf', 'variables.tf', 'versions.tf']:
        shutil.copy2(module / name, root / name)
        old = subprocess.check_output(['git', '-C', str(repo), 'show', f'{baseline}:terraform/modules/aws/search/{name}'])
        (fixture / name).write_bytes(old)
    shutil.copy2(module / '.terraform.lock.hcl', root / '.terraform.lock.hcl')
    with (fixture / 'outputs.tf').open('a') as f:
        f.write('\noutput "legacy_resource_id" { value = aws_opensearch_domain.this.id }\n')
    tests = root / 'tests'; tests.mkdir()
    provider = (module / 'tests/disposable.tftest.hcl').read_text().split('variables {', 1)[0]
    (tests / 'history.tftest.hcl').write_text(provider + '''
variables {
  domain_name = "relay-search"
  subnet_ids = ["subnet-synthetic"]
  security_group_ids = ["sg-synthetic"]
  master_user_arn = "arn:aws:iam::111111111111:role/search-admin"
  workload_roles = { create = false }
  log_publishing = []
  create_log_resource_policy = false
}
run "legacy_unindexed_state" {
  state_key = "main"
  module { source = "./fixtures/legacy" }
}
run "default_migration_retains_same_resource_id" {
  state_key = "main"
  assert {
    condition = aws_opensearch_domain.this[0].id == run.legacy_unindexed_state.legacy_resource_id && length(aws_opensearch_domain.disposable) == 0
    error_message = "Historical protected object must move without recreation or disposable conversion."
  }
}
run "protected_to_disposable_refused" {
  state_key = "main"
  command = plan
  variables { disposable = true }
}
''')
    subprocess.run([engine, 'init', '-backend=false', '-lockfile=readonly', '-no-color'], cwd=root, check=True, capture_output=True, text=True)
    result = subprocess.run([engine, 'test', '-no-color'], cwd=root, capture_output=True, text=True, timeout=120)
    log = result.stdout + result.stderr
    assert result.returncode != 0 and '"legacy_unindexed_state"... pass' in log and '"default_migration_retains_same_resource_id"... pass' in log and '"protected_to_disposable_refused"... fail' in log and 'prevent_destroy' in log and 'aws_opensearch_domain.this[0]' in log, log
print(json.dumps({'ok': True, 'historical_mock_state_migration_preserves_id': True, 'protected_to_disposable_refused': True, 'protected_mock_teardown_refused': True, 'aws_calls': 0}))
