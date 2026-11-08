"""Native shared-root mock histories; no AWS/backend or production state.

Uses only the already initialized module's provider packages as a filesystem
mirror. Terraform/OpenTofu test UI JSON is not saved-plan show-json and is not
fed to the state/plan classifier. Legacy cross-module state_key remains a
separate Terraform-only check_migration.py coverage boundary.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile

module = Path(__file__).resolve().parents[1]
engine = sys.argv[1]
mirror = module / '.terraform/providers'
assert mirror.is_dir() and (module / '.terraform.lock.hcl').is_file(), 'Initialize this module with its reviewed engine-specific lock first'
base = module / '.terraform/mode-history'; base.mkdir(exist_ok=True)
prefix = (module / 'tests/disposable.tftest.hcl').read_text().split('run "', 1)[0]
results = {}
for protected in [False, True]:
    label = 'protected-to-disposable' if protected else 'disposable-to-protected'
    with tempfile.TemporaryDirectory(prefix=label+'-', dir=base) as temporary:
        root = Path(temporary); (root / 'home').mkdir()
        for path in module.iterdir():
            if path.is_file() and path.name.endswith(('.tf', '.tf.json', '.tofu', '.tofu.json')):
                shutil.copy2(path, root / path.name)
        shutil.copy2(module / '.terraform.lock.hcl', root / '.terraform.lock.hcl')
        rc = root / 'terraform.rc'
        rc.write_text('disable_checkpoint = true\nprovider_installation {\n filesystem_mirror {\n path = '+json.dumps(str(mirror))+'\n }\n}\n')
        env = {'PATH':os.environ.get('PATH','/usr/bin:/bin'), 'HOME':str(root/'home'), 'CHECKPOINT_DISABLE':'1', 'TF_CLI_CONFIG_FILE':str(rc)}
        tests = root / 'tests'; tests.mkdir()
        source = prefix.replace('disposable                 = true', 'disposable                 = false') if protected else prefix
        source += '''run "created" {
 command = apply
 assert {
   condition = terraform_data.creation_mode.input == var.disposable
   error_message = "Persist the actual creation mode."
 }
}
run "flip" {
 command = plan
 variables { disposable = '''+('true' if protected else 'false')+''' }
'''
        if not protected: source += ' expect_failures = [terraform_data.creation_mode]\n'
        source += '}\n'
        if not protected:
            source += '''run "same_mode_after_refusal" {
 command = plan
 assert {
   condition = terraform_data.creation_mode.input && length(aws_opensearch_domain.disposable) == 1 && length(aws_opensearch_domain.this) == 0
   error_message = "Refusal must retain disposable state; its ordinary mock teardown must still succeed."
 }
}
'''
        (tests/'history.tftest.hcl').write_text(source)
        init = subprocess.run([engine,'init','-backend=false','-lockfile=readonly','-input=false','-no-color'], cwd=root, env=env, capture_output=True, text=True, timeout=120)
        assert init.returncode == 0, init.stdout+init.stderr
        test = subprocess.run([engine,'test','-json','-verbose','-no-color'], cwd=root, env=env, capture_output=True, text=True, timeout=120)
        output = test.stdout+test.stderr; (base/(label+'.jsonl')).write_text(output)
        events = [json.loads(line) for line in output.splitlines() if line.startswith('{')]
        if protected:
            assert test.returncode != 0 and 'prevent_destroy' in output and any(e.get('test_run',{}).get('status') == 'pass' and e.get('@testrun') == 'created' for e in events), output
            results[label] = 'refused by native literal protection; protected mock teardown intentionally refused'
        else:
            assert test.returncode == 0 and events[-1].get('test_summary',{}).get('passed') == 3, output
            created = next(e['test_state'] for e in events if e.get('type') == 'test_state' and e.get('@testrun') == 'created')
            unchanged = next(e['test_plan'] for e in events if e.get('type') == 'test_plan' and e.get('@testrun') == 'same_mode_after_refusal')
            # Pinned Terraform test UI emits root_module directly; pinned Tofu
            # wraps it in values. Neither wrapper is a saved-plan prior_state.
            state_root = created['root_module'] if 'root_module' in created else created['values']['root_module']
            old = next(r for r in state_root['resources'] if r['address'] == 'aws_opensearch_domain.disposable[0]')
            same = next(r['change'] for r in unchanged['resource_changes'] if r['address'] == old['address'])
            assert same['actions'] == ['no-op'] and same['before']['id'] == old['values']['id'] == same['after']['id'], output

            results[label] = 'hard mode postcondition expected/refused; same-mode plan and full disposable mock teardown passed'
print(json.dumps({'ok':True,'native_shared_root_history':results,'aws_calls':0,'legacy_cross_module_tofu_history':'not covered: pinned Tofu lacks state_key'}))
