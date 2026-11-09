import datetime as dt
import importlib
import inspect
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import runner as r

SESSION = '11111111-1111-4111-8111-111111111111'
ARN = f'arn:aws:sts::{r.ACCOUNT}:assumed-role/agent-session/agent-{SESSION}'


def future():
    return (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%S.000Z')


def protected_database(name='x', status=None):
    instance = {'attributes': {'deletion_protection': True}}
    if status:
        instance['status'] = status
    return {'mode': 'managed', 'module': 'module.postgres', 'type': 'aws_db_instance', 'name': name, 'instances': [instance]}


def security_group():
    return {'mode': 'managed', 'type': 'aws_security_group', 'name': 'database', 'instances': [{'attributes': {}}]}


CREATE_MISSING = [{'address': 'aws_secretsmanager_secret.runtime', 'type': 'aws_secretsmanager_secret', 'change': {'actions': ['create']}}]
DESTROY = [{'address': 'aws_security_group.database', 'type': 'aws_security_group', 'change': {'actions': ['delete']}}]


class Fake:
    """Synthetic Terraform and AWS. Nothing here reaches a tool or provider."""

    def __init__(self, execution):
        self.execution = execution
        self.calls = []
        self.arn = ARN
        self.account = r.ACCOUNT
        self.resources = []
        self.fail_apply = False
        self.raise_apply = False
        self.state_broken = False
        self.on_apply = None
        self.applied_resources = None
        self.untargeted_changes = None
        self.last_plan = []
        self.contract = None
        self.changes = []
        self.compute = {'instance_id': 'i-0123456789abcdef0', 'root_volume_ids': ['vol-0123456789abcdef0'], 'eni_id': 'eni-0123456789abcdef0'}
        self.restored = None
        self.receipts = {}
        self.backups = {'db-A': 'retained'}
        self.deleted_backups = []
        self.backend = None
        self.init_ignored = False
        self.state_reads = []
        self.last_vars = {}
        self.payload_changes = None
        self.fail_native = False
        self.fail_output = False
        self.null_output = False

    def done(self, args, stdout='', code=0):
        return subprocess.CompletedProcess(args, code, stdout, '')

    def contract_value(self, compute=None):
        return {'account_id': r.ACCOUNT, 'region': 'us-west-2', 'source_sha': 'a' * 40, 'run_id': 'rds67', 'lease': {'agent': r.AGENT, 'session_id': SESSION}, 'deadline': self.deadline,
                'marker': 'm', 'phase': 'seed', 'database': {'identifier': 'db', 'host': 'db.example', 'secret_arn': 'arn:secret:master'}, 'runtime_secret': {'arn': 'arn:secret:rt'},
                'bucket': 'b', 'payload_key': 'transport/x.tar.gz', 'payload_sha256': self.payload_sha, 'security_group_ids': ['sg-db', 'sg-v'], 'private_subnet_ids': ['s1', 's2'], 'vpc_id': 'vpc-1',
                'verifier_identity': {'role_arn': 'arn:aws:iam::x:role/pippen/workload/v'}, 'compute': compute, 'restored': self.restored}

    def __call__(self, args, timeout=0, check=True):
        self.calls.append(list(args))
        if args[0] == 'aws':
            return self.aws(args)
        verb = args[1]
        if verb == 'init':
            if not self.init_ignored:
                self.backend = next(a for a in args if a.startswith('-backend-config=path='))[len('-backend-config=path='):]
            return self.done(args)
        if verb == 'plan':
            out = next(a for a in args if a.startswith('-out='))[5:]
            Path(out).write_bytes(('plan:' + str(len(self.calls))).encode())
            self.last_plan = list(args)
            variables = next((a for a in args if a.startswith('-var-file=')), None)
            self.last_vars = json.loads(Path(variables[len('-var-file='):]).read_text()) if variables else {}
            return self.done(args)
        if verb == 'show':
            # Real Terraform plans every resource the configuration still declares unless targeted.
            if self.payload_changes is not None and self.last_vars.get('payload_version_id'):
                return self.done(args, json.dumps({'resource_changes': self.payload_changes}))
            untargeted = self.untargeted_changes is not None and not any(a.startswith('-target=') for a in self.last_plan)
            return self.done(args, json.dumps({'resource_changes': self.untargeted_changes if untargeted else self.changes}))
        if verb == 'apply':
            if self.on_apply:
                self.on_apply(args)
            if self.raise_apply:
                raise r.CommandInterrupted(15)
            self.resources = self.applied_resources if self.applied_resources is not None else [protected_database()]
            return self.done(args, code=1 if self.fail_apply else 0)
        if verb == 'state':
            self.state_reads.append(self.backend)
            if self.state_broken:
                return self.done(args, code=1)
            return self.done(args, json.dumps({'serial': 3, 'resources': self.resources}))
        if verb == 'output':
            if self.null_output:
                return self.done(args, 'null')
            if self.contract is None or self.fail_output:
                return self.done(args, code=1)
            return self.done(args, json.dumps(self.contract))
        raise AssertionError(args)

    def aws(self, args):
        operation = args[5]
        if operation == 'get-caller-identity':
            return self.done(args, json.dumps({'Account': self.account, 'Arn': self.arn}))
        if operation == 'describe-db-instances':
            if self.fail_native:
                return self.done(args, code=1)
            return self.done(args, json.dumps({'DBInstances': [{'DbiResourceId': 'db-A', 'DBInstanceStatus': 'available', 'Endpoint': {'Address': 'db.example'}, 'EngineVersion': '17.4', 'MasterUserSecret': {'SecretArn': 'arn:secret:master'}}]}))
        if operation == 'describe-network-interfaces':
            return self.done(args, json.dumps({'NetworkInterfaces': [{'NetworkInterfaceId': 'eni-db'}]}))
        if operation == 'list-secret-version-ids':
            return self.done(args, json.dumps({'Versions': []}))
        if operation == 'get-role':
            return self.done(args, json.dumps({'Role': {'Arn': 'arn:aws:iam::x:role/pippen/workload/v'}}))
        if operation == 'describe-security-groups':
            return self.done(args, json.dumps({'SecurityGroups': [{'GroupId': g, 'VpcId': 'vpc-1'} for g in ('sg-db', 'sg-v')]}))
        if operation == 'describe-subnets':
            return self.done(args, json.dumps({'Subnets': [{'SubnetId': s, 'VpcId': 'vpc-1'} for s in ('s1', 's2')]}))
        if operation == 'get-bucket-versioning':
            return self.done(args, json.dumps({'Status': 'Enabled'}))
        if operation == 'put-object':
            return self.done(args, json.dumps({'VersionId': 'v-payload'}))
        if operation == 'head-object':
            return self.done(args, json.dumps({'ContentLength': 7}))
        if operation == 'list-object-versions':
            prefix = args[args.index('--prefix') + 1] if '--prefix' in args else None
            if prefix:
                phase = prefix.split('/')[1].split('.')[0]
                return self.done(args, json.dumps({'Versions': [{'Key': prefix, 'VersionId': 'r-' + phase}] if phase in self.receipts else []}))
            return self.done(args, json.dumps({'IsTruncated': False, 'Versions': [{'Key': 'unrelated/sentinel', 'VersionId': 'sv'}]}))
        if operation == 'get-object':
            phase = args[args.index('--key') + 1].split('/')[1].split('.')[0]
            Path(args[-3]).write_text(json.dumps(self.receipts[phase]))
            return self.done(args)
        if operation == 'list-multipart-uploads':
            return self.done(args, json.dumps({'IsTruncated': False}))
        if operation == 'describe-instances':
            return self.done(args, json.dumps({'Reservations': []}))
        if operation == 'describe-db-instance-automated-backups':
            rid = args[args.index('--dbi-resource-id') + 1]
            rows = [{'DbiResourceId': rid, 'Status': self.backups[rid]}] if rid in self.backups else []
            return self.done(args, json.dumps({'DBInstanceAutomatedBackups': rows}))
        if operation == 'delete-db-instance-automated-backup':
            rid = args[args.index('--dbi-resource-id') + 1]
            self.deleted_backups.append(rid)
            self.backups.pop(rid)
            return self.done(args, '{}')
        raise AssertionError(args)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        for target in [patch.object(r, 'EXECUTION_PREFIX', '/')]:
            target.start()
            self.addCleanup(target.stop)
        self.archive = base / 'payload.tar.gz'
        self.archive.write_bytes(b'payload')
        self.deadline = future()
        self.inputs = {'account_id': r.ACCOUNT, 'region': 'us-west-2', 'run_id': 'rds67', 'pippen': {'agent': r.AGENT, 'session_id': SESSION}, 'source_sha': 'a' * 40,
                       'payload_sha256': r.sha(self.archive), 'payload_version_id': None, 'restore_checkpoint': None, 'retire': False, 'deadline': self.deadline, 'postgres_version': '17.4', 'guest_sources': {'composition_commit': 'b' * 40}}
        self.vars = base / 'inputs.json'
        self.vars.write_text(json.dumps(self.inputs))
        selector = base / 'selector'
        selector.write_text('[profile pippen-sandbox]\nregion = us-west-2\ncredential_process = /usr/bin/true\n')
        self.env = {'AWS_PROFILE': 'pippen-sandbox', 'AWS_SHARED_CREDENTIALS_FILE': '/dev/null', 'AWS_EC2_METADATA_DISABLED': 'true', 'AWS_CONFIG_FILE': str(selector),
                    'PIPPEN_SANDBOX_ACCOUNT_ID': r.ACCOUNT, 'PIPPEN_SANDBOX_AGENT_ID': r.AGENT, 'PIPPEN_SANDBOX_SESSION_ID': SESSION}
        self.execution = base / 'run'
        self.terraform = base / 'terraform'
        self.terraform.write_text('')
        self.fake = Fake(self.execution)
        self.fake.deadline = self.deadline
        self.fake.payload_sha = self.inputs['payload_sha256']
        self.binding = {'source_commit': 'a' * 40, 'lock': 'one'}
        test = self

        class Local(r.Runner):
            def bindings(self):
                return dict(test.binding)

            def backend_path(self):
                return test.fake.backend
        self.runner = Local(self.execution, self.vars, self.terraform, env=self.env, transport=self.fake)

    def plan_apply(self, phase):
        out = self.runner.plan(phase)
        return self.runner.apply(phase, out['plan_sha256'])

    def provision(self):
        self.fake.contract = self.fake.contract_value()
        return self.plan_apply('provision')

    def through_upload(self):
        self.provision()
        self.runner.prerequisites()
        self.runner.upload(self.archive)

    def through_seed(self):
        self.through_upload()
        self.fake.contract = self.fake.contract_value(self.fake.compute)
        self.plan_apply('seed')


class Import(unittest.TestCase):
    def test_import_runs_nothing_and_main_is_guarded(self):
        self.assertIn("if __name__ == '__main__':", inspect.getsource(r))
        with patch.object(subprocess, 'Popen') as popen, patch.object(subprocess, 'run') as run, patch.object(subprocess, 'check_output') as output:
            importlib.reload(r)
        popen.assert_not_called()
        run.assert_not_called()
        output.assert_not_called()


class SavedPlan(Base):
    def test_plan_stops_and_writes_digest_and_summary(self):
        self.fake.changes = [{'address': 'aws_s3_object.sentinel', 'type': 'aws_s3_object', 'change': {'actions': ['create']}}]
        out = self.runner.plan('provision')
        self.assertFalse([c for c in self.fake.calls if len(c) > 1 and c[1] == 'apply'])
        self.assertEqual(out['plan_sha256'], r.sha(self.execution / 'provision.tfplan'))
        self.assertIn('create   aws_s3_object.sentinel', (self.execution / 'provision.summary.txt').read_text())

    def test_digest_mismatch_refuses_without_applying(self):
        self.runner.plan('provision')
        with self.assertRaisesRegex(r.Refused, 'digest'):
            self.runner.apply('provision', '0' * 64)
        self.assertFalse([c for c in self.fake.calls if len(c) > 1 and c[1] == 'apply'])
        self.assertIsNone(self.runner.status_of('provision'))

    def test_swapped_plan_file_refuses(self):
        out = self.runner.plan('provision')
        (self.execution / 'provision.tfplan').write_bytes(b'other')
        with self.assertRaisesRegex(r.Refused, 'digest'):
            self.runner.apply('provision', out['plan_sha256'])

    def test_changed_source_vars_or_lock_refuses(self):
        out = self.runner.plan('provision')
        self.binding['lock'] = 'two'
        with self.assertRaisesRegex(r.Refused, 'changed since this plan'):
            self.runner.apply('provision', out['plan_sha256'])

    def test_changed_state_refuses(self):
        out = self.runner.plan('provision')
        (self.execution / 'state.tfstate').write_text('{}')
        with self.assertRaisesRegex(r.Refused, 'State changed'):
            self.runner.apply('provision', out['plan_sha256'])

    def test_pending_is_persisted_before_apply(self):
        seen = {}

        def on_apply(_args):
            seen['status'] = r.read(self.execution / 'phases.json')['provision']['status']
        self.fake.on_apply = on_apply
        self.provision()
        self.assertEqual(seen['status'], 'pending')
        self.assertEqual(self.runner.status_of('provision'), 'captured')
        self.assertEqual(r.read(self.execution / 'contract.json')['run_id'], 'rds67')


class UnknownState(Base):
    def test_failed_state_read_after_apply_is_unknown(self):
        self.fake.contract = self.fake.contract_value()
        out = self.runner.plan('provision')
        self.fake.state_broken = True
        with self.assertRaisesRegex(r.Refused, 'unknown'):
            self.runner.apply('provision', out['plan_sha256'])
        self.assertEqual(self.runner.status_of('provision'), 'unknown')

    def test_empty_state_after_apply_is_unknown(self):
        self.fake.contract = self.fake.contract_value()
        out = self.runner.plan('provision')
        self.fake.on_apply = lambda _args: None
        original = self.fake.__call__

        def empty(args, timeout=0, check=True):
            result = original(args, timeout=timeout, check=check)
            if len(args) > 1 and args[1] == 'apply':
                self.fake.resources = []
            return result
        self.runner.transport = empty
        with self.assertRaisesRegex(r.Refused, 'unknown'):
            self.runner.apply('provision', out['plan_sha256'])
        self.assertEqual(self.runner.status_of('provision'), 'unknown')

    def test_retirement_refuses_while_state_is_unknown_then_recovers(self):
        self.fake.contract = self.fake.contract_value()
        out = self.runner.plan('provision')
        self.fake.state_broken = True
        with self.assertRaises(r.Refused):
            self.runner.apply('provision', out['plan_sha256'])
        with self.assertRaisesRegex(r.Refused, 'reconcile'):
            self.runner.plan('release')
        self.fake.state_broken = False
        self.assertEqual(self.runner.reconcile('provision')['status'], 'failed')
        self.assertIn('plan_sha256', self.runner.plan('release'))

    def test_failed_apply_captures_state_before_refusing(self):
        self.fake.contract = None
        self.fake.fail_apply = True
        out = self.runner.plan('provision')
        with self.assertRaisesRegex(r.Refused, 'did not complete'):
            self.runner.apply('provision', out['plan_sha256'])
        self.assertEqual(self.runner.status_of('provision'), 'failed')
        self.assertEqual(r.read(self.execution / 'provision.capture.json')['resources'], ['module.postgres.aws_db_instance.x'])

    def test_interrupted_apply_is_captured(self):
        self.fake.contract = None
        self.fake.raise_apply = True
        self.fake.resources = [{'module': '', 'type': 'aws_vpc', 'name': 'x'}]
        out = self.runner.plan('provision')
        with self.assertRaisesRegex(r.Refused, 'did not complete'):
            self.runner.apply('provision', out['plan_sha256'])
        self.assertEqual(self.runner.status_of('provision'), 'interrupted')

    def test_successful_apply_without_contract_is_invalid(self):
        self.fake.null_output = True
        out = self.runner.plan('provision')
        with self.assertRaisesRegex(r.Refused, 'validation'):
            self.runner.apply('provision', out['plan_sha256'])
        self.assertEqual(self.runner.status_of('provision'), 'captured-invalid')

    def test_contract_for_another_lifecycle_is_invalid_but_captured(self):
        self.fake.contract = {**self.fake.contract_value(), 'run_id': 'other'}
        out = self.runner.plan('provision')
        with self.assertRaisesRegex(r.Refused, 'run_id'):
            self.runner.apply('provision', out['plan_sha256'])
        self.assertTrue((self.execution / 'contract.json').exists())


class Guards(Base):
    def test_expired_deadline_refuses_forward(self):
        self.inputs['deadline'] = '2020-01-01T00:00:00.000Z'
        self.vars.write_text(json.dumps(self.inputs))
        fresh = r.Runner(self.execution.parent / 'expired', self.vars, self.terraform, env=self.env, transport=self.fake)
        with self.assertRaisesRegex(r.Refused, 'Deadline expired'):
            fresh.plan('provision')

    def test_wrong_caller_refuses(self):
        self.fake.arn = f'arn:aws:sts::{r.ACCOUNT}:assumed-role/AdministratorAccess/someone'
        with self.assertRaisesRegex(r.Refused, 'Wrong caller'):
            self.runner.plan('provision')

    def test_wrong_session_in_caller_refuses(self):
        self.fake.arn = ARN.replace('1111', '2222', 1)
        with self.assertRaisesRegex(r.Refused, 'Wrong caller'):
            self.runner.plan('provision')

    def test_wrong_account_refuses(self):
        self.fake.account = '000000000000'
        with self.assertRaisesRegex(r.Refused, 'Wrong account'):
            self.runner.plan('provision')

    def test_apply_rechecks_caller(self):
        out = self.runner.plan('provision')
        self.fake.arn = 'arn:aws:sts::1:assumed-role/x/y'
        with self.assertRaises(r.Refused):
            self.runner.apply('provision', out['plan_sha256'])
        self.assertIsNone(self.runner.status_of('provision'))

    def test_static_credentials_and_missing_lease_refuse(self):
        for key, value in [('AWS_ACCESS_KEY_ID', 'x'), ('AWS_PROFILE', 'admin'), ('PIPPEN_SANDBOX_SESSION_ID', 'other')]:
            self.runner.env = {**self.env, key: value}
            with self.assertRaises(r.Refused):
                self.runner.plan('provision')
            self.runner.env = dict(self.env)

    def test_inputs_for_another_account_or_agent_refuse(self):
        for key, value in [('account_id', '000000000000'), ('pippen', {'agent': 'other', 'session_id': SESSION}), ('retire', True), ('payload_version_id', 'v')]:
            self.vars.write_text(json.dumps({**self.inputs, key: value}))
            with self.assertRaises(r.Refused):
                r.Runner(self.execution.parent / ('bad-' + key), self.vars, self.terraform, env=self.env, transport=self.fake)

    def test_execution_directory_must_be_private_and_outside_repo(self):
        self.vars.write_text(json.dumps(self.inputs))
        wide = self.execution.parent / 'wide'
        wide.mkdir(mode=0o755)
        os.chmod(wide, 0o755)
        with self.assertRaisesRegex(r.Refused, '0700'):
            r.Runner(wide, self.vars, self.terraform, env=self.env, transport=self.fake)
        with self.assertRaisesRegex(r.Refused, 'outside'):
            r.Runner(r.ROOT / 'private-run', self.vars, self.terraform, env=self.env, transport=self.fake)


class Order(Base):
    def test_phases_cannot_be_skipped(self):
        with self.assertRaisesRegex(r.Refused, 'provision must complete'):
            self.runner.prerequisites()
        self.provision()
        with self.assertRaisesRegex(r.Refused, 'prerequisites must complete'):
            self.runner.upload(self.archive)
        with self.assertRaisesRegex(r.Refused, 'upload must complete'):
            self.runner.plan('seed')

    def test_full_forward_sequence_derives_phase_variables(self):
        self.through_seed()
        seed = r.read(self.execution / 'seed.tfvars.json')
        self.assertEqual(seed['payload_version_id'], 'v-payload')
        self.assertIsNone(seed['restore_checkpoint'])
        self.assertFalse(seed['retire'])
        self.fake.receipts['seed'] = {'ok': True, 'phase': 'seed', 'source_sha': 'a' * 40, 'marker': 'm', 'application_sql_ready': False, 'secret_version_id': 'sv', 'runtime_secret_version_id': 'rv', 'database_resource_id': 'db-A', 'guest': {'receipt': {'evidenceSha256': 'e' * 64}}}
        self.runner.receipt('seed')
        self.fake.restored = {'identifier': 'db2', 'host': 'h', 'resource_id': 'db-B'}
        self.fake.contract = self.fake.contract_value({**self.fake.compute, 'instance_id': 'i-0123456789abcdef1', 'eni_id': 'eni-0123456789abcdef1', 'root_volume_ids': ['vol-0123456789abcdef1']})
        self.plan_apply('restore')
        checkpoint = r.read(self.execution / 'restore.tfvars.json')['restore_checkpoint']
        self.assertEqual(checkpoint['seed_receipt_version_id'], 'r-seed')
        self.assertEqual(checkpoint['seed_evidence_sha256'], 'e' * 64)
        self.assertEqual(len(r.read(self.execution / 'compute-history.json')), 2)
        self.fake.receipts['restore'] = {**self.fake.receipts['seed'], 'phase': 'restore', 'database_resource_id': 'db-B'}
        self.runner.receipt('restore')
        self.assertEqual(self.runner.status_of('restore-receipt'), 'ok')

    def test_applied_phase_cannot_rerun(self):
        self.provision()
        with self.assertRaisesRegex(r.Refused, 'no blind re-run'):
            self.runner.plan('provision')

    def test_failed_phase_blocks_forward(self):
        self.fake.contract = None
        self.fake.fail_apply = True
        out = self.runner.plan('provision')
        with self.assertRaises(r.Refused):
            self.runner.apply('provision', out['plan_sha256'])
        with self.assertRaisesRegex(r.Refused, 'retire or reconcile'):
            self.runner.plan('provision')

    def test_receipt_not_published_is_not_success(self):
        self.through_seed()
        with self.assertRaisesRegex(r.Refused, 'not published'):
            self.runner.receipt('seed')

    def test_receipt_for_another_lifecycle_refuses(self):
        self.through_seed()
        self.fake.receipts['seed'] = {'ok': True, 'phase': 'seed', 'source_sha': 'b' * 40, 'marker': 'm', 'application_sql_ready': False}
        with self.assertRaisesRegex(r.Refused, 'does not match'):
            self.runner.receipt('seed')

    def test_receipt_claiming_readiness_refuses(self):
        self.through_seed()
        self.fake.receipts['seed'] = {'ok': True, 'phase': 'seed', 'source_sha': 'a' * 40, 'marker': 'm', 'application_sql_ready': True}
        with self.assertRaisesRegex(r.Refused, 'readiness'):
            self.runner.receipt('seed')

    def test_upload_requires_reviewed_digest(self):
        self.provision()
        self.runner.prerequisites()
        self.archive.write_bytes(b'tampered')
        with self.assertRaisesRegex(r.Refused, 'digest'):
            self.runner.upload(self.archive)

    def test_upload_without_version_is_unknown(self):
        self.provision()
        self.runner.prerequisites()
        original = self.fake.aws

        def no_version(args):
            if args[5] == 'put-object':
                return self.fake.done(args, code=1)
            return original(args)
        self.fake.aws = no_version
        with self.assertRaisesRegex(r.Refused, 'unknown'):
            self.runner.upload(self.archive)
        self.assertEqual(self.runner.status_of('upload'), 'unknown')

    def test_provision_must_not_create_compute(self):
        self.fake.changes = [{'address': 'aws_instance.verifier[0]', 'type': 'aws_instance', 'change': {'actions': ['create']}}]
        with self.assertRaisesRegex(r.Refused, 'must not create compute'):
            self.runner.plan('provision')

    def test_only_destroy_may_delete_the_database(self):
        self.provision()
        self.fake.changes = [{'address': 'module.postgres.aws_db_instance.this', 'type': 'aws_db_instance', 'change': {'actions': ['delete']}}]
        with self.assertRaisesRegex(r.Refused, 'Only destroy'):
            self.runner.plan('release')


class Retirement(Base):
    def retire(self):
        if self.fake.contract is not None:
            # Real post-release output: retire=true sets the instance count to 0.
            self.fake.contract = self.fake.contract_value(None)
        out = self.runner.plan('release')
        self.runner.apply('release', out['plan_sha256'])
        self.assertTrue(r.read(self.execution / 'release.tfvars.json')['retire'])
        if self.runner.path('contract.json').exists():
            self.runner.inventory()
            ledger = r.sha(self.execution / 'ledger.json')
            with patch.dict('sys.modules', {'drain_bucket': type('D', (), {'drain': staticmethod(lambda _l: {'ok': True, 'versions_deleted': 0})})}):
                self.runner.drain(ledger)
        self.fake.changes = [{'address': 'aws_s3_bucket.b', 'type': 'aws_s3_bucket', 'change': {'actions': ['delete']}}]
        out = self.runner.plan('destroy')
        self.assertIn('-destroy', next(c for c in self.fake.calls if len(c) > 1 and c[1] == 'plan' and 'destroy.tfplan' in ' '.join(c)))
        real = self.fake.__call__

        def emptied(args, timeout=0, check=True):
            result = real(args, timeout=timeout, check=check)
            if len(args) > 1 and args[1] == 'apply':
                self.fake.resources = []
            return result
        self.runner.transport = emptied
        self.assertEqual(self.runner.apply('destroy', out['plan_sha256'])['status'], 'captured')

    def test_released_compute_passes_the_real_inventory_check(self):
        self.through_seed()
        self.retire()
        import retirement
        ledger = r.read(self.execution / 'ledger.json')
        self.assertIsNone(ledger['contract']['compute'])
        self.assertTrue(ledger['compute_released'])
        self.assertEqual(retirement.compute_inventory(ledger, ledger['contract']), ledger['compute_history'])

    def test_backups_deletes_retained_by_exact_resource_id(self):
        self.provision()
        self.retire()
        self.assertEqual(self.runner.backups()['deleted'], ['db-A'])
        self.assertEqual(self.fake.deleted_backups, ['db-A'])
        self.assertEqual(self.runner.status_of('backups'), 'ok')

    def test_failed_native_read_is_not_captured_and_reconciles_when_clean(self):
        self.fake.contract = self.fake.contract_value()
        self.fake.fail_native = True
        out = self.runner.plan('provision')
        with self.assertRaisesRegex(r.Refused, 'run reconcile --phase provision'):
            self.runner.apply('provision', out['plan_sha256'])
        self.assertEqual(self.runner.status_of('provision'), 'unknown')
        self.assertFalse(r.read(self.execution / 'provision.capture.json')['native_complete'])
        with self.assertRaisesRegex(r.Refused, 'never finished capture'):
            self.runner.plan('release')
        with self.assertRaises(r.Refused):
            self.runner.reconcile('provision')
        self.assertEqual(self.runner.status_of('provision'), 'unknown')
        self.fake.fail_native = False
        self.assertEqual(self.runner.reconcile('provision')['status'], 'captured')
        self.assertEqual(r.read(self.execution / 'native.json')['database_resource_ids'], ['db-A'])

    def test_failed_contract_read_after_clean_apply_is_recoverable(self):
        self.fake.contract = self.fake.contract_value()
        self.fake.fail_output = True
        out = self.runner.plan('provision')
        with self.assertRaisesRegex(r.Refused, 'run reconcile --phase provision'):
            self.runner.apply('provision', out['plan_sha256'])
        self.assertEqual(self.runner.status_of('provision'), 'unknown')
        with self.assertRaises(r.Refused):
            self.runner.reconcile('provision')
        self.assertEqual(self.runner.status_of('provision'), 'unknown')
        self.fake.fail_output = False
        self.assertEqual(self.runner.reconcile('provision')['status'], 'captured')
        self.assertEqual(r.read(self.execution / 'native.json')['database_resource_ids'], ['db-A'])

    def test_failed_apply_without_output_does_not_wait_for_one(self):
        self.fake.contract = None
        self.fake.fail_apply = True
        out = self.runner.plan('provision')
        with self.assertRaisesRegex(r.Refused, 'did not complete'):
            self.runner.apply('provision', out['plan_sha256'])
        self.assertEqual(self.runner.status_of('provision'), 'failed')

    def test_failed_apply_with_failed_native_read_reconciles_as_failed(self):
        self.fake.contract = self.fake.contract_value()
        self.fake.fail_native = True
        self.fake.fail_apply = True
        out = self.runner.plan('provision')
        with self.assertRaisesRegex(r.Refused, 'run reconcile'):
            self.runner.apply('provision', out['plan_sha256'])
        self.fake.fail_native = False
        self.assertEqual(self.runner.reconcile('provision')['status'], 'failed')

    def verifier_updates(self):
        return [{'address': a, 'type': a.split('.')[0], 'change': {'actions': ['update']}} for a in
                ('terraform_data.execution', 'terraform_data.application_gate', 'aws_iam_role_policy.verifier', 'aws_launch_template.verifier')]

    def test_release_after_upload_before_seed_keeps_the_provisioned_payload(self):
        self.through_upload()
        self.fake.changes = []
        self.fake.payload_changes = self.verifier_updates()
        out = self.runner.plan('release')
        self.assertIsNone(self.fake.last_vars['payload_version_id'])
        self.assertTrue(self.fake.last_vars['retire'])
        self.assertIn('plan_sha256', out)

    def test_release_of_a_seeded_lifecycle_still_sends_the_payload_and_guards_changes(self):
        self.through_seed()
        self.fake.changes = []
        self.fake.payload_changes = self.verifier_updates()
        with self.assertRaises(r.Refused):
            self.runner.plan('release')
        self.assertEqual(self.fake.last_vars['payload_version_id'], 'v-payload')

    def second_runner(self):
        test = self

        class Local(r.Runner):
            def bindings(self):
                return dict(test.binding)

            def backend_path(self):
                return test.fake.backend
        return Local(self.execution.parent / 'other', self.vars, self.terraform, env=self.env, transport=self.fake)

    def test_state_reads_rebind_after_another_execution_redirects_the_root(self):
        self.provision()
        other = self.second_runner()
        other.plan('provision')
        self.assertEqual(self.fake.backend, str(other.state))
        self.fake.state_reads.clear()
        self.assertIsNotNone(self.runner.read_state())
        self.assertEqual(self.fake.state_reads, [str(self.runner.state)])
        other_state_contract = self.runner.capture_contract()
        self.assertIsNotNone(other_state_contract)
        self.assertEqual(self.fake.backend, str(self.runner.state))

    def test_state_read_refuses_a_root_it_cannot_bind(self):
        self.provision()
        self.fake.backend = '/somewhere/else.tfstate'
        self.fake.init_ignored = True
        self.fake.state_reads.clear()
        self.assertIsNone(self.runner.read_state())
        self.assertEqual(self.fake.state_reads, [])
        self.assertIsNone(self.runner.capture_contract())

    def test_backups_refuses_a_ledger_changed_after_drain(self):
        self.provision()
        self.retire()
        path = self.execution / 'ledger.json'
        ledger = r.read(path)
        ledger['database_resource_ids'] = ['db-FOREIGN']
        r.save(path, ledger)
        self.fake.backups['db-FOREIGN'] = 'retained'
        with self.assertRaisesRegex(r.Refused, 'changed after the reviewed drain'):
            self.runner.backups()
        self.assertEqual(self.fake.deleted_backups, [])

    def test_backups_refuses_an_id_that_was_never_captured(self):
        self.provision()
        self.retire()
        path = self.execution / 'native.json'
        native = r.read(path)
        native['database_resource_ids'] = ['db-OTHER']
        r.save(path, native)
        with self.assertRaisesRegex(r.Refused, 'did not capture'):
            self.runner.backups()
        self.assertEqual(self.fake.deleted_backups, [])

    def test_backups_waits_while_not_yet_retained_and_can_rerun(self):
        self.provision()
        self.retire()
        self.fake.backups['db-A'] = 'creating'
        with self.assertRaisesRegex(r.Refused, 'not retained yet'):
            self.runner.backups()
        self.assertEqual(self.fake.deleted_backups, [])
        self.assertEqual(self.runner.status_of('backups'), 'failed')
        self.fake.backups['db-A'] = 'retained'
        self.assertEqual(self.runner.backups()['deleted'], ['db-A'])

    def test_backups_requires_destroy_and_absence_requires_backups(self):
        self.provision()
        with self.assertRaisesRegex(r.Refused, 'Destroy must complete before backups'):
            self.runner.backups()
        self.retire()
        with self.assertRaisesRegex(r.Refused, 'Backups must complete before absence'):
            self.runner.absence()

    def test_pending_apply_blocks_retirement_until_reconciled(self):
        self.provision()
        self.runner.mark('provision', 'pending', plan_sha256='x')
        with self.assertRaisesRegex(r.Refused, 'reconcile'):
            self.runner.plan('release')
        self.assertEqual(self.runner.reconcile('provision')['status'], 'failed')
        self.assertTrue((self.execution / 'provision.capture.json').exists())
        self.assertIn('plan_sha256', self.runner.plan('release'))

    def test_reconcile_stays_unknown_while_state_is_unreadable(self):
        self.provision()
        self.runner.mark('provision', 'pending')
        self.fake.state_broken = True
        with self.assertRaisesRegex(r.Refused, 'do not assume no resources'):
            self.runner.reconcile('provision')
        self.assertEqual(self.runner.status_of('provision'), 'unknown')

    def test_reconcile_refuses_a_settled_phase(self):
        self.provision()
        with self.assertRaisesRegex(r.Refused, 'nothing to reconcile'):
            self.runner.reconcile('provision')

    def test_unsettled_marker_blocks_later_processes(self):
        self.provision()
        self.runner.record_unsettled(999999)
        calls = len(self.fake.calls)
        fresh = type(self.runner)(self.execution, self.vars, self.terraform, env=self.env, transport=self.fake)
        with self.assertRaisesRegex(r.Refused, 'Unsettled'):
            fresh.plan('release')
        self.assertEqual(len(self.fake.calls), calls)

    def test_unsettled_real_group_is_persisted(self):
        real = r.Runner(self.execution, self.vars, self.terraform, env=self.env)
        with patch.object(real, 'settle_group', return_value=False):
            with self.assertRaisesRegex(r.Refused, 'Unsettled'):
                real.run(['true'])
        self.assertTrue((self.execution / 'unsettled.json').exists())

    def test_unsettled_apply_captures_nothing_and_blocks_a_new_runner(self):
        self.provision()
        out = self.runner.plan('release')

        def hung(_args):
            self.runner.record_unsettled(999999)
            raise r.Refused('Unsettled owned process group; quarantine before recovery')
        self.fake.on_apply = hung
        calls = []
        self.fake.calls = calls
        with self.assertRaisesRegex(r.Refused, 'unknown'):
            self.runner.apply('release', out['plan_sha256'])
        applied = next(i for i, c in enumerate(calls) if len(c) > 1 and c[1] == 'apply')
        self.assertEqual(calls[applied + 1:], [])
        self.assertEqual(self.runner.status_of('release'), 'unknown')
        fresh = type(self.runner)(self.execution, self.vars, self.terraform, env=self.env, transport=self.fake)
        before = len(calls)
        with self.assertRaisesRegex(r.Refused, 'Unsettled'):
            fresh.plan('release')
        with self.assertRaisesRegex(r.Refused, 'Unsettled'):
            fresh.reconcile('release')
        self.assertEqual(len(calls), before)

    def fail_provision(self, resources):
        self.fake.contract = None
        self.fake.applied_resources = resources
        self.fake.fail_apply = True
        out = self.runner.plan('provision')
        with self.assertRaises(r.Refused):
            self.runner.apply('provision', out['plan_sha256'])
        self.fake.fail_apply = False
        self.assertEqual(self.runner.status_of('provision'), 'failed')
        self.fake.untargeted_changes = CREATE_MISSING

    def finish_destroy(self):
        self.fake.untargeted_changes = None
        self.fake.changes = DESTROY
        out = self.runner.plan('destroy')
        self.fake.applied_resources = []
        return self.runner.apply('destroy', out['plan_sha256'])

    def test_partial_provision_with_a_database_releases_only_that_database(self):
        self.fail_provision([protected_database(), security_group()])
        self.fake.changes = [{'address': 'module.postgres.aws_db_instance.x', 'type': 'aws_db_instance',
                              'change': {'actions': ['update'], 'before': {'deletion_protection': True}, 'after': {'deletion_protection': False}}}]
        out = self.runner.plan('release')
        self.assertIn('-target=module.postgres.aws_db_instance.x', self.fake.last_plan)
        self.assertEqual(self.runner.apply('release', out['plan_sha256'])['status'], 'captured')
        self.assertIn('targeted to a partial lifecycle', (self.execution / 'release.summary.txt').read_text())
        self.assertEqual(self.finish_destroy()['status'], 'captured')

    def test_partial_provision_with_nothing_to_release_records_it_and_can_destroy(self):
        self.fail_provision([security_group()])
        result = self.runner.plan('release')
        self.assertEqual(result['status'], 'not-required')
        self.assertEqual(self.runner.status_of('release'), 'not-required')
        self.assertFalse(any(len(c) > 1 and c[1] == 'plan' and 'release.tfplan' in ' '.join(c) for c in self.fake.calls))
        self.assertEqual(self.finish_destroy()['status'], 'captured')

    def test_partial_release_is_not_required_only_without_protection_or_compute(self):
        self.fail_provision([{'mode': 'managed', 'type': 'aws_instance', 'name': 'verifier', 'instances': [{'index_key': 0, 'attributes': {}}]}])
        self.fake.changes = [{'address': 'aws_instance.verifier[0]', 'type': 'aws_instance', 'change': {'actions': ['delete']}}]
        out = self.runner.plan('release')
        self.assertIn('-target=aws_instance.verifier[0]', self.fake.last_plan)
        self.assertIn('plan_sha256', out)

    def test_targeted_partial_release_still_refuses_a_create(self):
        self.fail_provision([protected_database()])
        self.fake.changes = CREATE_MISSING
        with self.assertRaisesRegex(r.Refused, 'Release may only'):
            self.runner.plan('release')

    def test_tainted_database_refuses_with_recovery_instructions(self):
        self.fail_provision([protected_database(status='tainted')])
        with self.assertRaisesRegex(r.Refused, 'tainted'):
            self.runner.plan('release')
        self.assertNotIn('release', self.runner.phases())

    def test_complete_provision_is_not_targeted_and_still_refuses_creates(self):
        self.provision()
        self.fake.changes = CREATE_MISSING
        with self.assertRaisesRegex(r.Refused, 'Release may only'):
            self.runner.plan('release')
        self.assertFalse(any(a.startswith('-target=') for a in self.fake.last_plan))
        self.assertNotEqual(self.runner.status_of('release'), 'not-required')

    def test_destroy_still_requires_release_when_it_is_not_recorded(self):
        self.fail_provision([protected_database()])
        with self.assertRaisesRegex(r.Refused, 'Release must complete'):
            self.runner.plan('destroy')

    def test_settle_clears_only_when_the_group_is_gone(self):
        self.provision()
        self.runner.record_unsettled(os.getpgrp())
        with self.assertRaisesRegex(r.Refused, 'still exists'):
            self.runner.settle()
        self.runner.record_unsettled(999999)
        with patch('os.killpg', side_effect=ProcessLookupError):
            self.assertEqual(self.runner.settle()['status'], 'settled')
        self.assertFalse((self.execution / 'unsettled.json').exists())

    def test_receipt_must_name_the_captured_database(self):
        self.through_seed()
        good = {'ok': True, 'phase': 'seed', 'source_sha': 'a' * 40, 'marker': 'm', 'application_sql_ready': False, 'secret_version_id': 'sv', 'runtime_secret_version_id': 'rv',
                'database_resource_id': 'db-OTHER', 'source_database_resource_id': 'db-OTHER', 'guest': {'receipt': {'evidenceSha256': 'e' * 64}}}
        self.fake.receipts['seed'] = good
        with self.assertRaisesRegex(r.Refused, 'captured database'):
            self.runner.receipt('seed')

    def test_restore_receipt_must_name_the_captured_clone(self):
        self.through_seed()
        seed = {'ok': True, 'phase': 'seed', 'source_sha': 'a' * 40, 'marker': 'm', 'application_sql_ready': False, 'secret_version_id': 'sv', 'runtime_secret_version_id': 'rv',
                'database_resource_id': 'db-A', 'source_database_resource_id': 'db-A', 'guest': {'receipt': {'evidenceSha256': 'e' * 64}}}
        self.fake.receipts['seed'] = seed
        self.runner.receipt('seed')
        self.fake.restored = {'identifier': 'db2', 'host': 'h', 'resource_id': 'db-B'}
        self.fake.contract = self.fake.contract_value({**self.fake.compute, 'instance_id': 'i-0123456789abcdef1', 'eni_id': 'eni-0123456789abcdef1', 'root_volume_ids': ['vol-0123456789abcdef1']})
        self.plan_apply('restore')
        self.fake.receipts['restore'] = {**seed, 'phase': 'restore', 'database_resource_id': 'db-C'}
        with self.assertRaisesRegex(r.Refused, 'captured database'):
            self.runner.receipt('restore')

    def test_release_guard_allows_only_deletion_protection_and_compute_removal(self):
        ok = [{'address': 'aws_db_instance.r', 'type': 'aws_db_instance', 'action': 'update', 'attributes': [{'name': 'deletion_protection', 'before': True, 'after': False}]},
              {'address': 'aws_instance.v', 'type': 'aws_instance', 'action': 'delete'}]
        r.guard_changes('release', ok)
        for bad in [[{'address': 'a', 'type': 'aws_db_instance', 'action': 'update', 'attributes': [{'name': 'instance_class', 'before': 'x', 'after': 'y'}]}],
                    [{'address': 'a', 'type': 'aws_db_instance', 'action': 'update', 'attributes': [{'name': 'deletion_protection', 'before': True, 'after': False}, {'name': 'tags', 'before': '(changed)', 'after': '(changed)'}]}],
                    [{'address': 'a', 'type': 'aws_db_instance', 'action': 'update', 'attributes': [{'name': 'deletion_protection', 'before': False, 'after': True}]}],
                    [{'address': 'a', 'type': 'aws_iam_role', 'action': 'update', 'attributes': []}],
                    [{'address': 'a', 'type': 'aws_security_group', 'action': 'delete'}]]:
            with self.subTest(bad=bad), self.assertRaisesRegex(r.Refused, 'Release'):
                r.guard_changes('release', bad)

    def test_summary_shows_attribute_diffs_and_masks_sensitive(self):
        rendered = {'resource_changes': [{'address': 'aws_db_instance.p', 'type': 'aws_db_instance', 'change': {'actions': ['update'],
                    'before': {'deletion_protection': True, 'password': 'hidden', 'same': 1}, 'after': {'deletion_protection': False, 'password': 'hunter2', 'same': 1},
                    'before_sensitive': {'password': True}, 'after_sensitive': {'password': True}, 'after_unknown': {}}}]}
        attributes = r.summarize(rendered)[0]['attributes']
        self.assertEqual(attributes, [{'name': 'deletion_protection', 'before': True, 'after': False}, {'name': 'password', 'before': '(sensitive)', 'after': '(sensitive)'}])
        text = r.render_summary(r.summarize(rendered), 'd' * 64)
        self.assertIn('deletion_protection: true -> false', text)
        self.assertNotIn('hunter2', text)

    def test_retire_after_provision(self):
        self.provision()
        self.retire()

    def test_retire_after_upload(self):
        self.through_upload()
        self.retire()
        self.assertIsNone(r.read(self.execution / 'release.tfvars.json')['payload_version_id'])

    def test_retire_after_seed(self):
        self.through_seed()
        self.retire()

    def test_retire_after_failed_seed(self):
        self.through_upload()
        self.fake.contract = self.fake.contract_value(self.fake.compute)
        self.fake.fail_apply = True
        out = self.runner.plan('seed')
        with self.assertRaises(r.Refused):
            self.runner.apply('seed', out['plan_sha256'])
        self.fake.fail_apply = False
        self.retire()

    def test_retire_after_failed_provision_without_contract(self):
        self.fake.contract = None
        self.fake.fail_apply = True
        out = self.runner.plan('provision')
        with self.assertRaises(r.Refused):
            self.runner.apply('provision', out['plan_sha256'])
        self.fake.fail_apply = False
        self.retire()

    def test_retire_after_interrupted_release_can_replan(self):
        self.provision()
        out = self.runner.plan('release')
        self.fake.raise_apply = True
        with self.assertRaises(r.Refused):
            self.runner.apply('release', out['plan_sha256'])
        self.fake.raise_apply = False
        self.retire()

    def test_retire_ignores_expired_deadline_but_not_caller(self):
        self.provision()
        with patch.object(r, 'now', return_value=dt.datetime(2099, 1, 1, tzinfo=dt.timezone.utc)):
            self.assertIn('plan_sha256', self.runner.plan('release'))
            self.fake.arn = 'arn:aws:sts::1:assumed-role/x/y'
            with self.assertRaises(r.Refused):
                self.runner.plan('release')

    def test_nothing_applied_means_nothing_to_retire(self):
        with self.assertRaisesRegex(r.Refused, 'nothing to retire'):
            self.runner.plan('release')

    def test_retirement_closes_forward(self):
        self.provision()
        self.runner.plan('release')
        out = r.read(self.execution / 'release.packet.json')['plan_sha256']
        self.runner.apply('release', out)
        with self.assertRaisesRegex(r.Refused, 'Retirement has started'):
            self.runner.prerequisites()

    def test_destroy_requires_drain_when_a_contract_exists(self):
        self.provision()
        out = self.runner.plan('release')
        self.runner.apply('release', out['plan_sha256'])
        with self.assertRaisesRegex(r.Refused, 'Drain must complete'):
            self.runner.plan('destroy')

    def test_drain_requires_reviewed_ledger(self):
        self.provision()
        out = self.runner.plan('release')
        self.runner.apply('release', out['plan_sha256'])
        self.runner.inventory()
        with self.assertRaisesRegex(r.Refused, 'digest'):
            self.runner.drain('0' * 64)

    def test_untracked_compute_refuses_inventory(self):
        self.provision()
        out = self.runner.plan('release')
        self.runner.apply('release', out['plan_sha256'])
        original = self.fake.aws

        def stray(args):
            if args[5] == 'describe-instances':
                return self.fake.done(args, json.dumps({'Reservations': [{'Instances': [{'InstanceId': 'i-stray', 'State': {'Name': 'running'}}]}]}))
            return original(args)
        self.fake.aws = stray
        with self.assertRaisesRegex(r.Refused, 'Untracked'):
            self.runner.inventory()

    def test_destroy_plan_may_only_delete(self):
        with self.assertRaisesRegex(r.Refused, 'only delete'):
            r.guard_changes('destroy', [{'address': 'a', 'type': 'aws_s3_object', 'action': 'create'}])

    def test_absence_reports_what_remains(self):
        self.provision()
        self.retire()
        self.runner.backups()
        fake = type('M', (), {'check': staticmethod(lambda _l: {'ok': False, 'checks': {'database:db': True, 'role': False}})})
        with patch.dict('sys.modules', {'retirement': fake}):
            result = self.runner.absence()
        self.assertFalse(result['ok'])
        self.assertEqual(result['still_present'], ['role'])
        self.assertEqual(self.runner.status_of('absence'), 'failed')


class Bindings(unittest.TestCase):
    def test_dirty_tree_and_wrong_commit_refuse(self):
        fake = type('R', (), {'v': {'source_sha': 'a' * 40}, 'terraform': 't', 'env': {}, 'variables': __file__})
        with patch.object(r.subprocess, 'check_output', side_effect=['b' * 40]):
            with self.assertRaisesRegex(r.Refused, 'committed inputs'):
                r.Runner.bindings(fake)
        with patch.object(r.subprocess, 'check_output', side_effect=['a' * 40, ' M file\n']):
            with self.assertRaisesRegex(r.Refused, 'Commit all source'):
                r.Runner.bindings(fake)


if __name__ == '__main__':
    unittest.main()
