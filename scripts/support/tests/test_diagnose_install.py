import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('diagnose_install', Path(__file__).parents[1]/'diagnose-install.py')
diag = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(diag)


def options(**kwargs):
    values = dict(context='isolated',namespace='agent-relay',release='agent-relay',
                  timeout=5,ca_file=None,secret_dir=None,secret_manifests=None,scope='all',
                  control_database=None,cast_database=None,hoop_database=None)
    values.update(kwargs)
    return SimpleNamespace(**values)


def url(role, db='custom_cast', host='db.example.test'):
    return 'postgresql://'+role+':p%40ss%3Aword@'+host+':5432/'+db+'?sslmode=verify-full'


class CredentialTests(unittest.TestCase):
    def test_empty_host_database_wrong_role_wrappers_and_tls(self):
        cases = [
            ('postgresql://postgres:password@:5432/?sslmode=verify-full',None,'relaycast_owner','malformed'),
            (url('postgres'),None,'relaycast_owner','wrong-login'),
            (url('relaycast_owner').replace('verify-full','require'),None,'relaycast_owner','tls-verify'),
            (json.dumps({'wrong':url('bulls96_read_api')}),'supabase_url','bulls96_read_api','malformed'),
            (url('relaycast_owner')+'&options=unsafe',None,'relaycast_owner','malformed'),
            (url('relaycast_owner')+'&sslmode=disable',None,'relaycast_owner','malformed'),
            (url('relaycast_owner')+'&sslrootcert=%00',None,'relaycast_owner','malformed'),
        ]
        for value,wrapper,role,reason in cases:
            with self.subTest(reason=reason), self.assertRaisesRegex(diag.DiagnosticError,reason):
                diag.parse_credential(value,wrapper,role)

    def test_percent_encoded_password_and_custom_db(self):
        parsed = diag.parse_credential(url('relaycast_owner','Custom%20DB'),None,'relaycast_owner')
        self.assertEqual(parsed['password'],'p@ss:word')
        self.assertEqual(parsed['database'],'Custom DB')

    def test_malformed_ca_parameter_is_reported_without_stopping_collection(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            secret=root/'agent-relay-secrets'
            secret.mkdir()
            for key,role in (('database-owner-url','relaycast_owner'),
                             ('database-runtime-url','relaycast_runtime')):
                path=secret/key
                path.write_text(url(role)+('&sslrootcert=%00' if role=='relaycast_owner' else ''))
                path.chmod(0o600)
            report=diag.Report()
            credentials=diag.load_credentials(options(secret_dir=root),report)
            self.assertNotIn('cast-owner',credentials)
            self.assertIn('cast-runtime',credentials)
            finding=next(c for c in report.checks if c['check']=='credential.cast-owner')
            self.assertEqual(finding['status'],'FAIL')
            self.assertEqual(finding['detail'],'malformed-url-or-json')

    def test_json_slot(self):
        value=json.dumps({'supabase_url':url('bulls96_read_api')})
        self.assertEqual(diag.parse_credential(value,'supabase_url','bulls96_read_api')['user'],'bulls96_read_api')

    def test_named_secrets_read_once_and_no_values_in_report(self):
        payloads={}
        for slot,(secret,key,wrapper,role,group) in diag.SLOTS.items():
            value=url(role or 'approved_admin',group)
            if wrapper:
                value=json.dumps({wrapper:value})
            payloads.setdefault(secret,{})[key]=base64.b64encode(value.encode()).decode()
        with mock.patch.object(diag,'kube',side_effect=lambda opt,res,name:dict(data=payloads[name])) as kube:
            report=diag.Report()
            credentials=diag.load_credentials(options(),report)
        self.assertEqual(len(credentials),10)
        self.assertEqual(kube.call_count,5)
        self.assertNotIn('p@ss',json.dumps(report.result()))
        self.assertTrue(all(c['status']=='PASS' for c in report.checks))

    def test_secret_manifests_from_examples(self):
        examples = Path(__file__).resolve().parents[3]/'examples'/'aws'/'secrets'
        report = diag.Report()
        credentials = diag.load_credentials(options(secret_manifests=[examples]),report)
        self.assertEqual(set(credentials), set(diag.SLOTS))
        self.assertTrue(all(c['status']=='PASS' for c in report.checks if c['check'].startswith('credential.')))

    def test_secret_manifest_quoting_data_and_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp)/'s.yaml'
            enc = base64.b64encode(url('relaycast_runtime').encode()).decode()
            f.write_text("# c\n---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: agent-relay-secrets\n"
                         "stringData:\n  database-owner-url: '" + url('relaycast_owner') + "'  # note\n"
                         "data:\n  database-runtime-url: " + enc + "\n---\nkind: ConfigMap\nmetadata:\n  name: x\n")
            secrets = diag.load_secret_manifests([f])
            self.assertEqual(secrets['agent-relay-secrets']['database-owner-url'], url('relaycast_owner'))
            self.assertEqual(secrets['agent-relay-secrets']['database-runtime-url'], url('relaycast_runtime'))
            report = diag.Report()
            diag.load_credentials(options(secret_manifests=[f]),report)
            text = json.dumps(report.result())
            self.assertIn('manifest-secret-missing', text)
            self.assertNotIn('p%40ss', text)

    def test_secret_manifest_review_cases(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = base64.b64encode(url('relaycast_owner', db='old_db').encode()).decode()
            new = url('relaycast_owner')
            # ConfigMap with non-base64 data, commented separator, data after stringData.
            (root/'a.yaml').write_text("kind: Secret\nmetadata:\n  name: agent-relay-secrets\n"
                                        "stringData:\n  database-owner-url: '" + new + "'\n"
                                        "data:\n  database-owner-url: " + old + "\n"
                                        "--- # CA bundle\nkind: ConfigMap\nmetadata:\n  name: rds-ca\n"
                                        "data:\n  ca.crt: |\n    -----BEGIN CERTIFICATE-----\n    AAAA\n")
            (root/'b.json').write_text(json.dumps({'kind':'List','items':[
                {'kind':'ConfigMap','metadata':{'name':'x'},'data':{'mode':'production'}},
                {'kind':'Secret','metadata':{'name':'agent-relay-read-api'},'data':{'k':base64.b64encode(b'v').decode()}}]}))
            secrets = diag.load_secret_manifests([root])
            self.assertEqual(secrets['agent-relay-secrets']['database-owner-url'], new)
            self.assertEqual(secrets['agent-relay-read-api']['k'], 'v')
            self.assertNotIn('rds-ca', secrets)
            (root/'b.json').write_text(json.dumps({'kind':'Secret','metadata':{'name':'s'},'data':{'database-url':None}}))
            report = diag.Report()
            diag.load_credentials(options(secret_manifests=[root/'b.json']),report)
            self.assertIn('manifest-invalid-fields', json.dumps(report.result()))
            (root/'b.json').write_text('[1, 2]')
            report = diag.Report()
            diag.load_credentials(options(secret_manifests=[root/'b.json']),report)
            self.assertIn('manifest-invalid-fields', json.dumps(report.result()))

    def test_missing_files_help(self):
        examples = Path(__file__).resolve().parents[3]/'examples'/'aws'
        for with_secrets in (False, True):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                if with_secrets:
                    shutil.copytree(examples/'secrets', root/'secrets')
                    (root/'secrets'/'02-agent-relay-read-api.yaml').unlink()
                cwd = os.getcwd()
                out = io.StringIO()
                try:
                    os.chdir(root)
                    with mock.patch.object(Path, 'home', return_value=root/'nohome'), \
                         mock.patch.object(diag, 'database_checks'), contextlib.redirect_stdout(out), \
                         contextlib.redirect_stderr(io.StringIO()):
                        diag.main(['--scope', 'database'])
                finally:
                    os.chdir(cwd)
                text = out.getvalue()
                self.assertIn('Missing files - how to fix:', text)
                self.assertIn('--values <path>', text)
                if with_secrets:
                    self.assertIn('truststore.pki.rds.amazonaws.com/us-east-1/us-east-1-bundle.pem', text)
                    self.assertIn('not in the YAML files found: agent-relay-read-api', text)
                else:
                    self.assertIn('No database credentials found', text)
                    self.assertIn('/<region>/', text)

    def test_ingest_checks(self):
        cred = {'host':'h','port':'5432','user':'hoopdb_owner','password':'p','database':'hoopdb','params':{}}
        def run_with(results, s3=None):
            report = diag.Report()
            calls = iter(results)
            with mock.patch.object(diag, 'psql', side_effect=lambda *a, **k: next(calls)), \
                 mock.patch.object(diag.subprocess, 'run', side_effect=s3 or (lambda *a, **k: SimpleNamespace(returncode=0, stderr=''))):
                diag.ingest_checks(options(), cred, report)
            return {c['check']: c for c in report.checks}
        none = run_with([{'present': True, 'forced_rls': False}, {'rows': 0, 'pointers': 0, 'latest_age_s': None, 'latest': None}])
        self.assertEqual(none['ingest.pointers']['status'], 'UNKNOWN')
        self.assertIn('No sessions ingested yet', none['ingest.pointers']['detail'])
        latest = {'bucket': 'secret-bucket', 'key': 'org/ws/secret-key.json'}
        ok = run_with([{'present': True, 'forced_rls': False}, {'rows': 3, 'pointers': 3, 'latest_age_s': 120, 'latest': dict(latest)}])
        self.assertEqual(ok['ingest.pointers']['status'], 'PASS'); self.assertIn('2 min', ok['ingest.pointers']['detail'])
        self.assertEqual(ok['ingest.s3-object']['status'], 'PASS')
        self.assertNotIn('secret', json.dumps(ok))
        for err, status in (('An error occurred (404) when calling the HeadObject operation: Not Found', 'FAIL'),
                            ('An error occurred (403) when calling the HeadObject operation: Forbidden', 'UNKNOWN'),
                            ('Unable to locate credentials. You can configure credentials', 'UNKNOWN')):
            r = run_with([{'present': True, 'forced_rls': False}, {'rows': 1, 'pointers': 1, 'latest_age_s': 5, 'latest': dict(latest)}],
                         s3=lambda *a, err=err, **k: SimpleNamespace(returncode=255, stderr=err))
            self.assertEqual(r['ingest.s3-object']['status'], status, err)
        missing = run_with([{'present': False, 'forced_rls': False}])
        self.assertEqual(missing['ingest.pointers']['status'], 'UNKNOWN')
        forced = run_with([{'present': True, 'forced_rls': True}])
        self.assertIn('row-level', forced['ingest.pointers']['detail'])

    def test_secret_manifest_args(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            diag.parse_args(['--scope','database','--secret-dir','a','--secret-manifests','b'])
        o = diag.parse_args(['--scope','database','--secret-manifests','b'])
        self.assertEqual(o.secret_manifests, [Path('b')])

    def test_values_lint_finds_call_mistakes(self):
        import hashlib
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ca = root/'rds-ca.pem'
            ca.write_text('-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n')
            good = hashlib.sha256(ca.read_bytes()).hexdigest()
            values = root/'values-poc.yaml'
            values.write_text('# ar.example.com in a comment is fine\n'
                              'host: https://ar.example.com\n'
                              '      url: vpc-x.us-west-2.es.amazonaws.com\n'
                              '      caSha256: "'+diag.EXAMPLE_CA_SHA+'"\n'
                              '      sha256: "'+'0'*64+'"\n'
                              '      caSha256: "'+good+'"\n'
                              '  digest: sha256:'+'1'*64+'\n')
            report = diag.Report()
            diag.values_checks(SimpleNamespace(values=[values], ca_file=ca), report)
            by = {c['check'].rsplit('.',1)[1]: c for c in report.checks}
            self.assertEqual(by['placeholders']['status'], 'FAIL')
            self.assertIn('line(s) 2.', by['placeholders']['detail'])
            self.assertIn('line(s) 3.', by['opensearch-scheme']['detail'])
            self.assertIn('Example CA hash on line(s) 4.', by['ca-sha256']['detail'])
            self.assertIn('local CA file on line(s) 5.', by['ca-sha256']['detail'])
            values.write_text('url: https://vpc-x.us-west-2.es.amazonaws.com\ncaSha256: "'+good+'"\n')
            report = diag.Report()
            diag.values_checks(SimpleNamespace(values=[values], ca_file=ca), report)
            self.assertTrue(all(c['status']=='PASS' for c in report.checks))

    def test_discover_uses_local_files_without_cluster(self):
        examples = Path(__file__).resolve().parents[3]/'examples'/'aws'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shutil.copytree(examples/'secrets', root/'secrets')
            shutil.copy(examples/'values.yaml', root/'values.yaml')
            (root/'rds-ca.pem').write_text('-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n')
            o = diag.parse_args(['--scope','database'])
            cwd = os.getcwd()
            try:
                os.chdir(root)
                with mock.patch.object(Path, 'home', return_value=root/'nohome'):
                    notes = []
                    diag.discover(o, notes)
            finally:
                os.chdir(cwd)
            self.assertEqual(o.ca_file.name, 'rds-ca.pem')
            self.assertEqual(len(o.secret_manifests), 5)
            self.assertEqual([v.name for v in o.values], ['values.yaml'])
            self.assertTrue(o.output.name.startswith('install-diagnostic-'))

    def test_local_files_private_and_wrong_expected_database(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            path=root/'agent-relay-secrets'/'database-owner-url'
            path.parent.mkdir()
            path.write_text(url('relaycast_owner'))
            path.chmod(0o644)
            report=diag.Report()
            diag.load_credentials(options(secret_dir=root),report)
            self.assertIn('credential-file-permissions',report.checks[2]['detail'])
            path.chmod(0o600)
            report=diag.Report()
            diag.load_credentials(options(secret_dir=root,cast_database='intended_cast'),report)
            self.assertEqual(report.checks[2]['detail'],'wrong-database')

    def test_conflicting_urls_and_shared_database_are_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for slot,(secret,key,wrapper,role,group) in diag.SLOTS.items():
                value=url(role or 'approved_admin','shared')
                if slot=='cast-runtime':
                    value=url(role,'different')
                if wrapper:
                    value=json.dumps({wrapper:value})
                path=root/secret/key
                path.parent.mkdir(exist_ok=True)
                path.write_text(value)
                path.chmod(0o600)
            report=diag.Report()
            diag.load_credentials(options(secret_dir=root),report)
            failures=[c['check'] for c in report.checks if c['status']=='FAIL']
            self.assertIn('credential.cast.same-target',failures)
            self.assertIn('credential.separate-databases.control.hoop',failures)


class ExecutionTests(unittest.TestCase):
    def test_psql_credentials_only_in_environment_and_read_only(self):
        credential=diag.parse_credential(url('relaycast_owner'),None,'relaycast_owner')
        with mock.patch.dict(os.environ,{'PGSERVICE':'unsafe','PGOPTIONS':'unsafe'}), mock.patch.object(diag,'run',return_value={}) as run:
            diag.psql(credential,diag.CAST_SQL,5,Path('/local/ca.pem'))
        argv,timeout=run.call_args.args
        kwargs=run.call_args.kwargs
        self.assertNotIn('p@ss',str(argv))
        self.assertNotIn('PGSERVICE',kwargs['env'])
        self.assertEqual(kwargs['env']['PGSSLROOTCERT'],'/local/ca.pem')
        self.assertIn('default_transaction_read_only=on',kwargs['env']['PGOPTIONS'])
        self.assertTrue(kwargs['sql'].startswith('BEGIN READ ONLY;'))
        self.assertTrue(kwargs['sql'].endswith('ROLLBACK;\n'))
        self.assertIn('-X',argv)
        self.assertIn('-w',argv)

    def test_raw_errors_never_escape(self):
        raw='password authentication failed postgresql://user:VERY_SECRET@db/prod'
        result=subprocess.CompletedProcess(['psql'],1,'',raw)
        with mock.patch.object(diag.subprocess,'run',return_value=result):
            with self.assertRaises(diag.DiagnosticError) as caught:
                diag.run(['psql'],5)
        self.assertEqual(str(caught.exception),'authentication')

    def test_cluster_job_exit_65_and_current_recovery(self):
        def kube(opt,resource,**kwargs):
            if resource=='jobs':
                return {'items':[{'metadata':{'name':'relaycast-migrate-old'},'status':{'conditions':[{'type':'Failed','status':'True'}]}}]}
            if resource=='pods':
                return {'items':[{'metadata':{'name':'relaycast-pod'},'status':{'phase':'Running','conditions':[{'type':'Ready','status':'True'}], 'containerStatuses':[{'state':{'running':{}},'lastState':{'terminated':{'exitCode':65}}}]}}]}
            return {'items':[]}
        report=diag.Report()
        with mock.patch.object(diag,'kube',side_effect=kube):
            diag.cluster_checks(options(),report)
        self.assertEqual(report.checks[0]['status'],'FAIL')
        self.assertEqual(report.checks[0]['resource'],'relaycast-migrate-old')
        self.assertTrue(any(c['status']=='UNKNOWN' and '65' in c['detail'] for c in report.checks))
        self.assertTrue(any(c['status']=='PASS' and c['check'].endswith('ready') for c in report.checks))

    def test_cluster_missing_and_overwritten_rds_ca(self):
        import hashlib
        pem = '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n'
        pod = {'metadata':{'name':'read-api'},'spec':{'volumes':[{'name':'postgres-ca','configMap':{'name':'rds-ca'}},{'name':'x','configMap':{'name':'Bad_Name'}},{'name':'o','configMap':{'name':'opt-cm','optional':True}}]},
               'status':{'phase':'Pending','conditions':[]}}
        def cluster(configmaps):
            def kube(opt,resource,**kwargs):
                if resource=='pods':
                    return {'items':[pod]}
                if resource=='configmaps':
                    return {'items':configmaps}
                return {'items':[]}
            report=diag.Report()
            with mock.patch.object(diag,'kube',side_effect=kube):
                diag.cluster_checks(options(),report)
            return {c['check']:c for c in report.checks if c['check'].startswith('cluster.configmaps')}
        missing = cluster([])
        self.assertEqual(missing['cluster.configmaps.1']['status'],'FAIL')
        self.assertEqual(missing['cluster.configmaps.1']['resource'],'rds-ca')
        self.assertIn('global.rdsCa.bundle', missing['cluster.configmaps.1']['action'])
        self.assertEqual(len(missing),1)  # an invalid name is never echoed or checked
        managed = {'metadata':{'name':'rds-ca','annotations':{'agentworkforce.dev/rds-ca-sha256':hashlib.sha256(pem.encode()).hexdigest()}},'data':{'ca.crt':pem}}
        good = cluster([managed])
        self.assertEqual([c['status'] for c in good.values()],['PASS','PASS'])
        managed['data']['ca.crt'] = pem+pem
        self.assertEqual(cluster([managed])['cluster.configmaps.1.rds-ca-pin']['status'],'FAIL')

    def test_values_lint_global_rds_ca(self):
        with tempfile.TemporaryDirectory() as tmp:
            values = Path(tmp)/'values.yaml'
            values.write_text('global:\n  rdsCa:\n    # region\n    bundle: us-east-1\nworker:\n  postgresCa:\n    sha256: "'+diag.EXAMPLE_CA_SHA+'"\n')
            report = diag.Report()
            diag.values_checks(SimpleNamespace(values=[values], ca_file=None), report)
            by = {c['check'].rsplit('.',1)[1]: c for c in report.checks}
            self.assertEqual(by['rds-ca']['status'], 'PASS')
            self.assertEqual(by['ca-sha256']['status'], 'FAIL')
            self.assertIn('with global.rdsCa.bundle the chart computes them', by['ca-sha256']['action'])
            values.write_text('global:\n  rdsCa:\n    bundle: us_east\n')
            report = diag.Report()
            diag.values_checks(SimpleNamespace(values=[values], ca_file=None), report)
            self.assertEqual({c['check'].rsplit('.',1)[1]: c['status'] for c in report.checks}['rds-ca'], 'FAIL')

    def test_cluster_errors_are_unknown(self):
        report=diag.Report()
        with mock.patch.object(diag,'kube',side_effect=diag.DiagnosticError('permissions')):
            diag.cluster_checks(options(),report)
        self.assertEqual(len(report.checks),4)
        self.assertTrue(all(c['status']=='UNKNOWN' for c in report.checks))

    def test_main_partial_exit_and_private_report_no_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)/'report.json'
            with mock.patch.object(diag,'load_credentials',return_value={}), contextlib.redirect_stdout(io.StringIO()):
                with mock.patch.object(diag,'cluster_checks'):
                    code=diag.main(['--scope','cluster','--context','test','--output',str(output)])
                    self.assertEqual(code,2)
                    self.assertEqual(output.stat().st_mode & 0o777,0o600)
                    with contextlib.redirect_stderr(io.StringIO()):
                        self.assertEqual(diag.main(['--scope','cluster','--context','test','--output',str(output)]),2)


def workload(kind, name, sa, **env):
    pod = {'serviceAccountName': sa, 'containers': [{'name': 'app', 'env': [{'name': k, 'value': v} for k, v in env.items()]}]}
    spec = {'jobTemplate': {'spec': {'template': {'spec': pod}}}} if kind == 'cronjobs' else {'template': {'spec': pod}}
    return {'metadata': {'name': name}, 'spec': spec}


OS_URL = 'https://vpc-relay-search-abcdefghijklmnopqrstuvwxyz.us-west-2.es.amazonaws.com'
# The workloads the eks + eks-native profiles render (chart 0.7.54/0.7.81).
RELEASE = {
    'deployments': [
        workload('deployments', 'relay-control', 'relay-control'),
        workload('deployments', 'agent-relay-worker-session-summary-worker', 'agent-relay-worker', LOCKER_BUCKET='acme-sessions', LOCKER_REGION='us-west-2'),
        workload('deployments', 'agent-relay-ingest-edge', 'agent-relay-session-ingest-api', LOCKER_BUCKET='acme-sessions', LOCKER_PROVIDER='s3'),
        workload('deployments', 'agent-relay-read-api', 'agent-relay-session-read', LOCKER_BUCKET='acme-sessions',
                 SEARCH_INDEX_OPENSEARCH_AUTH='sigv4', SEARCH_INDEX_OPENSEARCH_URL=OS_URL),
        workload('deployments', 'agent-relay-search-indexer', 'agent-relay-search-indexer', LOCKER_BUCKET='acme-sessions',
                 LOCKER_PROVIDER='s3', SEARCH_INDEX_OPENSEARCH_AUTH='sigv4', SEARCH_INDEX_OPENSEARCH_URL=OS_URL),
    ],
    'jobs': [workload('jobs', 'agent-relay-worker-migrate-6ae46510', 'agent-relay-worker', LOCKER_BUCKET='acme-sessions')],
    'statefulsets': [], 'cronjobs': [],
}
ROLE = 'arn:aws:iam::123456789012:role/'


class FakeAws:
    """subprocess.run stand-in for aws and kubectl config view; records every argv."""
    def __init__(self, associations, simulate='allowed', list_error=None, context_cluster='arn:aws:eks:us-west-2:123456789012:cluster/demo',
                 describe_error=None, users=()):
        self.associations, self.simulate, self.list_error, self.context_cluster = associations, simulate, list_error, context_cluster
        self.describe_error, self.users = describe_error, list(users)
        self.calls, self.envs = [], []

    def __call__(self, argv, **kwargs):
        self.calls.append(argv)
        self.envs.append(kwargs.get('env'))
        ok = lambda data: SimpleNamespace(returncode=0, stdout=json.dumps(data), stderr='')
        if argv[:3] == ['kubectl', 'config', 'view']:
            return ok({'clusters': [{'name': self.context_cluster}], 'users': self.users})
        if argv[:3] == ['aws', 'eks', 'list-pod-identity-associations']:
            if self.list_error:
                return SimpleNamespace(returncode=255, stdout='', stderr=self.list_error)
            return ok({'associations': [{'serviceAccount': sa, 'associationId': 'a-'+str(i).zfill(10), 'namespace': 'agent-relay'}
                                        for i, sa in enumerate(self.associations)]})
        if argv[:3] == ['aws', 'eks', 'describe-pod-identity-association']:
            if self.describe_error:
                return SimpleNamespace(returncode=254, stdout='', stderr=self.describe_error)
            aid = argv[argv.index('--association-id')+1]
            sa = list(self.associations)[int(aid[2:])]
            return ok({'association': {'roleArn': ROLE+self.associations[sa]}})
        if argv[:3] == ['aws', 'iam', 'simulate-principal-policy']:
            if self.simulate == 'denied-api':
                return SimpleNamespace(returncode=254, stdout='', stderr='An error occurred (AccessDenied) when calling SimulatePrincipalPolicy')
            role = argv[argv.index('--policy-source-arn')+1]
            actions = argv[argv.index('--action-names')+1:argv.index('--resource-arns')]
            decision = self.simulate(role, actions) if callable(self.simulate) else self.simulate
            return ok({'EvaluationResults': [{'EvalActionName': a, 'EvalDecision': decision} for a in actions]})
        raise AssertionError('unexpected command '+' '.join(argv))


class PodIdentityTests(unittest.TestCase):
    def run_checks(self, fake, release=RELEASE, **kwargs):
        report = diag.Report()
        with mock.patch.object(diag, 'kube', side_effect=lambda opt, res, name=None, selector=False, probe=False: {'items': release[res]}), \
             mock.patch.object(diag.subprocess, 'run', side_effect=fake):
            diag.pod_identity_checks(options(**kwargs), report)
        return {c['check']: c for c in report.checks}

    # The rehearsal: roles for alleyoop, session-ingest-api, search-indexer and
    # session-read, none for the worker.
    REHEARSAL = {'agent-relay-alleyoop': 'alleyoop', 'agent-relay-session-ingest-api': 'session-ingest-api',
                 'agent-relay-search-indexer': 'session-indexer', 'agent-relay-session-read': 'session-read'}

    def test_missing_worker_association_gets_an_exact_fix_line(self):
        fake = FakeAws(self.REHEARSAL)
        checks = self.run_checks(fake)
        worker = checks['podidentity.agent-relay-worker']
        self.assertEqual(worker['status'], 'FAIL')
        self.assertIn('needs S3 read/write', worker['detail'])
        self.assertIn('agent-relay-worker-session-summary-worker', worker['detail'])
        # The reference Terraform gives worker, alleyoop and session-ingest-api one sessions role.
        self.assertIn('aws eks create-pod-identity-association --cluster-name demo --region us-west-2 --namespace agent-relay '
                      '--service-account agent-relay-worker --role-arn '+ROLE+'alleyoop', worker['action'])
        self.assertIn('kubectl --context isolated -n agent-relay rollout restart deployment/agent-relay-worker-session-summary-worker',
                      worker['action'])
        self.assertNotIn('migrate', worker['action'].split('rollout restart')[1])
        for sa in ('agent-relay-session-ingest-api', 'agent-relay-search-indexer', 'agent-relay-session-read'):
            self.assertEqual(checks['podidentity.'+sa]['status'], 'PASS', sa)
        self.assertNotIn('podidentity.relay-control', checks)
        self.assertIn('agent-relay-alleyoop', checks['podidentity.unused']['detail'])
        self.assertIn(['aws', 'eks', 'list-pod-identity-associations', '--cluster-name', 'demo', '--region', 'us-west-2',
                       '--namespace', 'agent-relay', '--output', 'json'], fake.calls)

    def test_access_levels_and_simulated_resources(self):
        fake = FakeAws(dict(self.REHEARSAL, **{'agent-relay-worker': 'session-ingest-api'}))
        checks = self.run_checks(fake)
        self.assertEqual({k: c['status'] for k, c in checks.items() if k.startswith('podidentity.agent-relay-search-indexer')},
                         {'podidentity.agent-relay-search-indexer': 'PASS', 'podidentity.agent-relay-search-indexer.s3-r': 'PASS',
                          'podidentity.agent-relay-search-indexer.os-w': 'PASS'})
        self.assertIn('podidentity.agent-relay-session-read.os-r', checks)
        self.assertIn('podidentity.agent-relay-worker.s3-rw', checks)
        sims = [c for c in fake.calls if c[:3] == ['aws', 'iam', 'simulate-principal-policy']]
        resources = {c[c.index('--resource-arns')+1] for c in sims}
        self.assertEqual(resources, {'arn:aws:s3:::acme-sessions', 'arn:aws:s3:::acme-sessions/*',
                                     'arn:aws:es:us-west-2:123456789012:domain/relay-search/*'})
        writes = [c for c in sims if 's3:PutObject' in c]
        self.assertTrue(writes and all(ROLE+'session-ingest-api' in c for c in writes))

    def test_role_without_the_access_fails_and_unsimulatable_is_unknown(self):
        deny_os = lambda role, actions: 'implicitDeny' if role.endswith('session-read') and actions[0].startswith('es:') else 'allowed'
        checks = self.run_checks(FakeAws(self.REHEARSAL, simulate=deny_os))
        self.assertEqual(checks['podidentity.agent-relay-session-read.os-r']['status'], 'FAIL')
        self.assertIn('OpenSearch read on OpenSearch domain relay-search', checks['podidentity.agent-relay-session-read.os-r']['action'])
        self.assertEqual(checks['podidentity.agent-relay-session-read.s3-r']['status'], 'PASS')
        checks = self.run_checks(FakeAws(self.REHEARSAL, simulate='denied-api'))
        self.assertEqual(checks['podidentity.agent-relay-session-read']['status'], 'PASS')
        self.assertEqual(checks['podidentity.agent-relay-session-read.os-r']['status'], 'UNKNOWN')
        self.assertIn('aws-access-denied', checks['podidentity.agent-relay-session-read.os-r']['detail'])
        checks = self.run_checks(FakeAws(self.REHEARSAL), no_iam_simulate=True)
        self.assertFalse([k for k in checks if k.endswith(('.s3-r', '.s3-rw', '.os-r', '.os-w'))])

    def test_no_credentials_is_unknown_with_the_command_to_run(self):
        checks = self.run_checks(FakeAws({}, list_error='Unable to locate credentials. You can configure credentials by running "aws configure".'))
        sas = sorted(k for k in checks)
        self.assertEqual(sas, ['podidentity.agent-relay-search-indexer', 'podidentity.agent-relay-session-ingest-api',
                               'podidentity.agent-relay-session-read', 'podidentity.agent-relay-worker'])
        for check in checks.values():
            self.assertEqual(check['status'], 'UNKNOWN')
            self.assertIn('no-valid-aws-credentials', check['detail'])
            self.assertIn('aws eks list-pod-identity-associations --cluster-name demo --region us-west-2 --namespace agent-relay', check['action'])
        self.assertNotIn('Unable to locate', json.dumps(checks))

    def test_no_associations_suggests_a_placeholder_role(self):
        checks = self.run_checks(FakeAws({}))
        self.assertIn('--role-arn <ARN of a role with S3 read, OpenSearch write>', checks['podidentity.agent-relay-search-indexer']['action'])
        self.assertTrue(all(c['status'] == 'FAIL' for c in checks.values()))

    def test_static_keys_and_other_providers_need_no_association(self):
        release = dict(RELEASE, deployments=[
            workload('deployments', 'w', 'agent-relay-worker', LOCKER_BUCKET='b1', LOCKER_ACCESS_KEY_ID='AKIA'),
            workload('deployments', 'i', 'agent-relay-session-ingest-api', LOCKER_BUCKET='b1', LOCKER_PROVIDER='gcs')], jobs=[])
        self.assertEqual(self.run_checks(FakeAws({}), release=release), {})

    def test_cluster_from_flags_or_exec_args(self):
        # A non-EKS context (GKE, kind): the section is skipped, not UNKNOWN.
        fake = FakeAws(self.REHEARSAL, context_cluster='gke_project_us-central1_cluster')
        self.assertEqual(self.run_checks(fake), {})
        self.assertFalse([c for c in fake.calls if c[0] == 'aws'])
        checks = self.run_checks(FakeAws(self.REHEARSAL, context_cluster='my-alias'), eks_cluster='prod-1', aws_region='eu-west-1')
        self.assertIn('--cluster-name prod-1 --region eu-west-1', checks['podidentity.agent-relay-worker']['action'])
        config = {'clusters': [{'name': 'alias'}], 'users': [{'name': 'u', 'user': {'exec': {
            'args': ['--region', 'ap-south-1', 'eks', 'get-token', '--cluster-name', 'from-exec'],
            'env': [{'name': 'AWS_PROFILE', 'value': 'customer-admin'}]}}}]}
        opts = options()
        with mock.patch.object(diag.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(config), stderr='')):
            self.assertEqual(diag.eks_target(opts), ('from-exec', 'ap-south-1'))
        self.assertEqual(opts.aws_profile, 'customer-admin')

    def test_the_kube_contexts_profile_wins_over_the_shell(self):
        users = [{'name': 'u', 'user': {'exec': {'args': ['--region', 'us-west-2', 'eks', 'get-token', '--cluster-name', 'demo'],
                                                 'env': [{'name': 'AWS_PROFILE', 'value': 'customer-admin'}]}}}]
        fake = FakeAws({}, users=users)
        with mock.patch.dict(os.environ, {'AWS_PROFILE': 'someone-else'}):
            checks = self.run_checks(fake, eks_cluster='demo', aws_region='us-west-2')
        aws_envs = [e for c, e in zip(fake.calls, fake.envs) if c[0] == 'aws']
        self.assertTrue(aws_envs and all(e['AWS_PROFILE'] == 'customer-admin' for e in aws_envs))
        self.assertIn('create-pod-identity-association --profile customer-admin', checks['podidentity.agent-relay-worker']['action'])
        fake = FakeAws({}, users=users)
        self.run_checks(fake, aws_profile='explicit')
        self.assertTrue(all(e['AWS_PROFILE'] == 'explicit' for c, e in zip(fake.calls, fake.envs) if c[0] == 'aws'))

    def test_unreadable_role_makes_its_access_unknown(self):
        checks = self.run_checks(FakeAws(self.REHEARSAL, describe_error='An error occurred (AccessDeniedException) when calling DescribePodIdentityAssociation'))
        self.assertEqual(checks['podidentity.agent-relay-session-read']['status'], 'PASS')
        for level in ('s3-r', 'os-r'):
            check = checks['podidentity.agent-relay-session-read.'+level]
            self.assertEqual(check['status'], 'UNKNOWN')
            self.assertIn('aws-access-denied', check['detail'])

    def test_direct_uploads_never_share_the_ingest_role(self):
        release = dict(RELEASE, deployments=[
            dict(d, spec={'template': {'spec': dict(d['spec']['template']['spec'], containers=[dict(
                d['spec']['template']['spec']['containers'][0],
                env=d['spec']['template']['spec']['containers'][0]['env']+[{'name': 'HISTORY_UPLOAD_DIRECT', 'value': 'on'}])])}})
            if d['metadata']['name'] == 'agent-relay-ingest-edge' else d for d in RELEASE['deployments']])
        checks = self.run_checks(FakeAws({'agent-relay-session-read': 'session-read', 'agent-relay-search-indexer': 'indexer',
                                          'agent-relay-session-ingest-api': 'upload-consumer'}), release=release)
        self.assertIn('<ARN of a role with S3 read/write>', checks['podidentity.agent-relay-worker']['action'])
        checks = self.run_checks(FakeAws({'agent-relay-worker': 'sessions', 'agent-relay-session-read': 'session-read',
                                          'agent-relay-search-indexer': 'indexer'}), release=release)
        action = checks['podidentity.agent-relay-session-ingest-api']['action']
        self.assertIn('its own upload-consumer role', action)
        self.assertNotIn(ROLE+'sessions', action)

    def test_rearm_sweeper_and_levels_follow_the_workload(self):
        release = dict(RELEASE, cronjobs=[workload('cronjobs', 'agent-relay-rearm', 'agent-relay-rearm-sweeper',
                                                   INGEST_REARM_BUCKET='acme-sessions', INGEST_REARM_CREDENTIALS='podIdentity')],
                       deployments=[workload('deployments', 'agent-relay-read-api', 'agent-relay-session-read', LOCKER_BUCKET='acme-sessions')])
        fake = FakeAws({'agent-relay-session-read': 'session-read'})
        checks = self.run_checks(fake, release=release)
        sweeper = checks['podidentity.agent-relay-rearm-sweeper']
        self.assertEqual(sweeper['status'], 'FAIL')
        self.assertIn('S3 re-arm sweep', sweeper['detail'])
        self.assertNotIn('rollout restart', sweeper['action'])   # a CronJob: the next run picks it up
        # Postgres search, no OpenSearch URL: no OpenSearch check for the reader.
        self.assertIn('podidentity.agent-relay-session-read.s3-r', checks)
        self.assertNotIn('podidentity.agent-relay-session-read.os-r', checks)
        actions = [c for c in fake.calls if c[:3] == ['aws', 'iam', 'simulate-principal-policy']]
        self.assertTrue(all('es:ESHttpGet' not in c for c in actions))

    def test_opensearch_actions_match_the_search_module(self):
        self.assertEqual(diag.ACCESS_ACTIONS['os-r'][0][0], ('es:ESHttpGet', 'es:ESHttpHead', 'es:ESHttpPost'))
        self.assertEqual(set(diag.ACCESS_ACTIONS['os-w'][0][0]),
                         {'es:ESHttpGet', 'es:ESHttpHead', 'es:ESHttpPost', 'es:ESHttpPut', 'es:ESHttpDelete', 'es:ESHttpPatch'})

    def test_main_skips_pod_identity_with_no_aws_or_unreachable_cluster(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(diag, 'pod_identity_checks') as checks, \
             mock.patch.object(diag, 'cluster_checks'), mock.patch.object(diag, 'load_credentials', return_value={}), \
             contextlib.redirect_stdout(io.StringIO()):
            def discover(opts, notes):
                opts.cluster_reachable, opts.missing, opts.no_credentials = True, {}, True
            with mock.patch.object(diag, 'discover', side_effect=discover):
                diag.main(['--scope', 'cluster', '--context', 't', '--values', '--output', directory+'/a.json'])
                self.assertEqual(checks.call_count, 1)
                diag.main(['--scope', 'cluster', '--context', 't', '--values', '--no-aws', '--output', directory+'/b.json'])
                self.assertEqual(checks.call_count, 1)


def b64(text):
    return base64.b64encode(text.encode()).decode()


def probe_log(identity_user='control_owner', extra=(), ca='0'):
    """Probe output: the CA it found, every slot's URL parts (no password) and an identity result."""
    lines = ['psql noise the parser ignores', 'AR\tCA\t'+ca]
    for slot, (secret, key, wrapper, role, group) in diag.SLOTS.items():
        parts = dict(scheme='postgresql', user=role or 'migration_owner', host='db.example.test', port='5432',
                     path='/'+group, query='sslmode=verify-full', fragment=0)
        lines.append('AR\tCRED\t'+slot+'\tOK\t'+b64(json.dumps(parts)))
        ident = dict(user=role or 'migration_owner', database=group, login=True, tls=True, restricted=True,
                     admin_membership=False, database_owner_membership=False, sessions_usage=True,
                     server_version=170004, database_owner=role or 'migration_owner', target=['10.0.0.5', 5432, 1],
                     schema_owners={'sessions': role or 'migration_owner'}, roles={})
        lines.append('AR\tQ\t'+slot+'\tidentity\tOK\t'+b64(json.dumps(ident)))
    lines += list(extra)
    lines.append('AR\tDONE')
    return '\n'.join(lines)+'\n'


class InClusterTests(unittest.TestCase):
    def test_error_rules_keep_the_old_categories(self):
        cases = {'FATAL: role "x" does not exist': 'role-missing',
                 'FATAL: password authentication failed for user "x"': 'authentication',
                 'FATAL: database "hoop" does not exist': 'database-missing',
                 'SSL error: certificate verify failed': 'tls',
                 'could not translate host name "db" to address': 'dns',
                 'connection to server failed: Connection refused': 'network',
                 'ERROR: permission denied for schema sessions': 'permissions',
                 'something else': 'command-failed'}
        for stderr, category in cases.items():
            self.assertEqual(diag.error_category(stderr), category, stderr)

    def test_job_carries_no_credentials_and_is_locked_down(self):
        opts = options(psql_image=diag.PSQL_IMAGE, ca_configmap=None, in_cluster_deadline=300)
        job = diag.in_cluster_job(opts, 'agent-relay-diagnose-db-abc123')
        text = json.dumps(job)
        self.assertNotIn('postgres://', text)
        self.assertNotIn('postgresql://', text)
        pod = job['spec']['template']['spec']
        self.assertFalse(pod['automountServiceAccountToken'])
        self.assertEqual(job['spec']['backoffLimit'], 0)
        self.assertTrue(pod['containers'][0]['securityContext']['readOnlyRootFilesystem'])
        self.assertEqual(pod['containers'][0]['image'], diag.PSQL_IMAGE)
        secrets = {v['secret']['secretName']: [i['key'] for i in v['secret']['items']] for v in pod['volumes'] if 'secret' in v}
        self.assertEqual(secrets['agent-relay-secrets'], ['database-migrations-url', 'database-url', 'database-owner-url',
                                                          'database-runtime-url', 'HOOPDB_MIGRATION_URL', 'HOOPDB_URL'])
        self.assertEqual(set(secrets), {s[0] for s in diag.SLOTS.values()})
        self.assertTrue(all(v['secret']['optional'] for v in pod['volumes'] if 'secret' in v))
        cas = [v['configMap']['name'] for v in pod['volumes'] if 'configMap' in v]
        self.assertEqual(cas, ['rds-ca', 'cloud-sql-ca'])
        self.assertEqual(diag.ca_configmaps(options(ca_configmap='my-ca')), ['my-ca'])
        env = {e['name']: e['value'] for e in pod['containers'][0]['env']}
        self.assertEqual(env['AR_CA_DIRS'], '0,1')
        self.assertEqual(len(env['AR_PLAN'].splitlines()), len(diag.SLOTS))
        self.assertEqual(env['AR_RULES'].splitlines()[0], 'role-missing\trole .+ does not exist')
        self.assertNotIn("'latest'", env['AR_SQL_INGEST'])
        self.assertNotIn('app.kubernetes.io/instance', job['metadata']['labels'])

    def test_probe_output_parsing(self):
        values, results = diag.parse_probe_output(probe_log(extra=[
            'AR\tQ\tcast-owner\tcast\tERR\tauthentication', 'AR\tQ\tcast-owner\tcast\tERR\tNot A Category!',
            'AR\tCRED\tnot-a-slot\tOK\t'+b64('x'), 'AR\tQ\thoop-owner\tdrop-table\tOK\t'+b64('{}')]))
        self.assertEqual(diag.parse_credential(values[('agent-relay-read-api', 'RELAYHISTORY_READ_API_SECRET')],
                                               'supabase_url', 'bulls96_read_api')['password'], 'redacted')
        self.assertEqual(results[('cast-owner', 'cast')], ('err', 'authentication'))
        self.assertNotIn(('hoop-owner', 'drop-table'), results)
        with self.assertRaisesRegex(diag.DiagnosticError, 'in-cluster-output-incomplete'):
            diag.parse_probe_output(probe_log().replace('AR\tDONE\n', ''))
        values, _ = diag.parse_probe_output('AR\tCRED\tcontrol-owner\tERR\tsecret-key-missing\nAR\tDONE\n')
        self.assertEqual(str(values[('agent-relay-secrets', 'database-migrations-url')]), 'secret-key-missing')

    def kubectl(self, states, log, fail_on=None):
        calls = []
        def fake(opts, args, stdin=None, timeout=None):
            calls.append((args, stdin))
            if args[0] == fail_on:
                raise diag.DiagnosticError('permissions')
            if args[0] == 'create':
                return 'job.batch/x'
            if args[:2] == ['get', 'job']:
                return json.dumps({'status': states.pop(0) if len(states) > 1 else states[0]})
            if args[:2] == ['get', 'pods']:
                return json.dumps({'items': [{'status': {'phase': 'Pending', 'containerStatuses': [
                    {'state': {'waiting': {'reason': 'ImagePullBackOff'}}}]}}]})
            if args[0] == 'logs':
                return log
            return ''
        return fake, calls

    def opts(self):
        return options(psql_image=diag.PSQL_IMAGE, ca_configmap=None, in_cluster_deadline=0)

    def test_run_in_cluster_waits_reads_and_always_deletes(self):
        fake, calls = self.kubectl([{'active': 1}, {'succeeded': 1}], probe_log())
        with mock.patch.object(diag, 'kubectl_text', side_effect=fake), mock.patch('time.sleep'):
            opts = self.opts(); opts.in_cluster_deadline = 60
            values, results = diag.run_in_cluster(opts)
        self.assertEqual(results[('control-owner', 'identity')][0], 'ok')
        self.assertEqual([c[0][0] for c in calls], ['create', 'get', 'get', 'logs', 'delete'])
        self.assertEqual(json.loads(calls[0][1])['kind'], 'Job')
        self.assertIn('--ignore-not-found', calls[-1][0])
        # A pod that never pulls its image: a fixed category, and the Job is still deleted.
        fake, calls = self.kubectl([{'failed': 1}], '')
        with mock.patch.object(diag, 'kubectl_text', side_effect=fake), mock.patch('time.sleep'):
            with self.assertRaisesRegex(diag.DiagnosticError, 'in-cluster-image-pull-failed'):
                diag.run_in_cluster(self.opts())
        self.assertEqual(calls[-1][0][0], 'delete')
        # No permission to create Jobs: nothing to delete, category "permissions".
        fake, calls = self.kubectl([{}], '', fail_on='create')
        with mock.patch.object(diag, 'kubectl_text', side_effect=fake):
            with self.assertRaisesRegex(diag.DiagnosticError, 'permissions'):
                diag.run_in_cluster(self.opts())

    def test_in_cluster_results_drive_the_same_checks(self):
        values, results = diag.parse_probe_output(probe_log(extra=['AR\tQ\thoop-owner\thoop\tERR\tpermissions']))
        report = diag.Report()
        with mock.patch.object(diag, 'run_in_cluster', return_value=(values, results)), \
             mock.patch.object(diag, 'psql', side_effect=AssertionError('no local psql')):
            credentials = diag.in_cluster_database_section(self.opts(), report)
        checks = {c['check']: c for c in report.checks}
        self.assertEqual(len(credentials), len(diag.SLOTS))
        self.assertTrue(all(checks['credential.'+slot]['status'] == 'PASS' for slot in diag.SLOTS))
        self.assertEqual(checks['database.control-owner.identity']['status'], 'PASS')
        self.assertEqual(checks['database.hoop-owner']['detail'], 'permissions')
        self.assertEqual(checks['database.in-cluster']['status'], 'PASS')
        self.assertIn('ConfigMap rds-ca', checks['database.in-cluster']['detail'])
        self.assertNotIn('redacted', json.dumps(report.checks))
        # No CA ConfigMap found in the pod: the run says so.
        values, results = diag.parse_probe_output(probe_log(ca='none'))
        report = diag.Report()
        with mock.patch.object(diag, 'run_in_cluster', return_value=(values, results)):
            diag.in_cluster_database_section(self.opts(), report)
        self.assertEqual([c['status'] for c in report.checks if c['check'] == 'database.in-cluster'], ['UNKNOWN'])

    def test_job_failure_is_one_unknown_with_a_next_step(self):
        report = diag.Report()
        with mock.patch.object(diag, 'run_in_cluster', side_effect=diag.DiagnosticError('permissions')):
            self.assertEqual(diag.in_cluster_database_section(self.opts(), report), {})
        self.assertEqual([(c['check'], c['status'], c['detail']) for c in report.checks],
                         [('database.in-cluster', 'UNKNOWN', 'permissions')])
        self.assertIn('--psql-image', report.checks[0]['action'])

    def run_main(self, local_detail, argv=(), reachable=True):
        def discover(opts, notes):
            # As the real discover: --scope database does not probe the cluster.
            opts.cluster_reachable = reachable and (opts.scope != 'database' or opts.in_cluster)
            opts.missing, opts.no_credentials = {}, False
        def local_checks(opts, credentials, report, query=None):
            report.add('database.control-owner', 'UNKNOWN' if local_detail != 'authentication' else 'FAIL', local_detail)
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(diag, 'discover', side_effect=discover), mock.patch.object(diag, 'cluster_checks'), \
             mock.patch.object(diag, 'pod_identity_checks', create=True), \
             mock.patch.object(diag, 'load_credentials', return_value={}), \
             mock.patch.object(diag, 'database_checks', side_effect=local_checks), \
             mock.patch.object(diag, 'find_cluster', return_value=reachable) as find, \
             mock.patch.object(diag, 'can_create_jobs', return_value=reachable), \
             mock.patch.object(diag, 'in_cluster_database_section') as section, contextlib.redirect_stdout(io.StringIO()) as out:
            diag.main(['--context', 't', '--values', '--output', directory+'/r.json', *argv])
            report = json.loads(Path(directory, 'r.json').read_text())
        return section.call_count, find.call_count, out.getvalue(), report

    def test_automatic_fallback_only_when_the_database_is_out_of_reach(self):
        calls, _, out, report = self.run_main('network')
        self.assertEqual(calls, 1)
        self.assertIn('running the database checks inside the cluster', out)
        self.assertFalse([c for c in report['checks'] if c['detail'] == 'network'])
        self.assertEqual(self.run_main('authentication')[0], 0)   # it connected: a real finding
        self.assertEqual(self.run_main('network', ['--no-in-cluster'])[0], 0)
        self.assertEqual(self.run_main('network', reachable=False)[0], 0)
        # --scope database skips the cluster until the database turns out unreachable.
        calls, finds, _, _ = self.run_main('dns', ['--scope', 'database'])
        self.assertEqual((calls, finds), (1, 1))
        calls, finds, _, _ = self.run_main('network', ['--scope', 'cluster'])
        self.assertEqual((calls, finds), (0, 0))

    def test_fallback_keeps_confirmed_failures_and_selected_files(self):
        # A credential FAIL is a finding: the Job must not replace it.
        def discover(opts, notes):
            opts.cluster_reachable, opts.missing, opts.no_credentials = True, {}, False
        def creds(opts, report):
            report.add('credential.cast-owner', 'FAIL', 'wrong-login')
            return {}
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(diag, 'discover', side_effect=discover), mock.patch.object(diag, 'cluster_checks'), \
             mock.patch.object(diag, 'pod_identity_checks', create=True), mock.patch.object(diag, 'load_credentials', side_effect=creds), \
             mock.patch.object(diag, 'database_checks', side_effect=lambda o, c, r, query=None: r.unknown('database.cast-owner', 'network')), \
             mock.patch.object(diag, 'in_cluster_database_section') as section, contextlib.redirect_stdout(io.StringIO()):
            diag.main(['--context', 't', '--values', '--output', directory+'/r.json'])
            self.assertEqual(section.call_count, 0)
            self.assertIn('wrong-login', Path(directory, 'r.json').read_text())
            # Files you selected are what you asked to test: suggest --in-cluster, don't swap them.
            secret_dir = Path(directory)/'s'; secret_dir.mkdir()
            with mock.patch.object(diag, 'load_credentials', return_value={}), contextlib.redirect_stdout(io.StringIO()) as out:
                diag.main(['--context', 't', '--values', '--secret-dir', str(secret_dir), '--output', directory+'/r2.json'])
            self.assertEqual(section.call_count, 0)
            self.assertIn('rerun with --in-cluster', out.getvalue())

    def test_create_timeout_still_cleans_up_and_failed_cleanup_is_reported(self):
        calls = []
        def fake(opts, args, stdin=None, timeout=None):
            calls.append(args[0])
            if args[0] == 'create':
                raise diag.DiagnosticError('timeout')
            return ''
        opts = self.opts()
        with mock.patch.object(diag, 'kubectl_text', side_effect=fake), self.assertRaises(diag.DiagnosticError):
            diag.run_in_cluster(opts)
        self.assertEqual(calls, ['create', 'delete'])
        def fake2(opts, args, stdin=None, timeout=None):
            if args[0] == 'delete':
                raise diag.DiagnosticError('permissions')
            return {'create': 'job.batch/x', 'get': json.dumps({'status': {'succeeded': 1}}), 'logs': probe_log()}[args[0]]
        report = diag.Report()
        with mock.patch.object(diag, 'kubectl_text', side_effect=fake2), contextlib.redirect_stderr(io.StringIO()):
            diag.in_cluster_database_section(self.opts(), report)
        cleanup = [c for c in report.checks if c['check'] == 'database.in-cluster.cleanup']
        self.assertEqual(len(cleanup), 1)
        self.assertIn('delete job agent-relay-diagnose-db-', cleanup[0]['action'])

    def test_credential_parts_rebuild_like_the_secret(self):
        ipv6 = diag.credential_url(dict(scheme='postgresql', user='relaycast_owner', host='[2001:db8::5]', port='', path='/cast',
                                        query='sslmode=verify-full', fragment=0), None)
        self.assertEqual(diag.parse_credential(ipv6, None, 'relaycast_owner')['host'], '2001:db8::5')
        wrapped = diag.credential_url(dict(scheme='postgresql', user='bulls96_read_api', host='db', port='5432', path='/hoop',
                                           query='sslmode=require', fragment=0), 'supabase_url')
        with self.assertRaisesRegex(diag.DiagnosticError, 'tls-verify-full-required'):
            diag.parse_credential(wrapped, 'supabase_url', 'bulls96_read_api')
        self.assertEqual(diag.error_category('connect: Network is unreachable'), 'network')
        base = dict(scheme='postgresql', user='relaycast_owner', host='db', port='', path='/cast', fragment=0)
        for parts in (dict(base, query='sslmode=verify-full', password=0),                  # empty password
                      dict(base, query='sslmode=verify-full&unsupported=1', password=1)):   # a parameter the probe withheld
            with self.assertRaisesRegex(diag.DiagnosticError, 'malformed'):
                diag.parse_credential(diag.credential_url(parts, None), None, 'relaycast_owner')
        with self.assertRaisesRegex(diag.DiagnosticError, 'malformed'):  # a fragment stays an error
            diag.parse_credential(diag.credential_url(dict(scheme='postgresql', user='relaycast_owner', host='db', port='',
                                  path='/cast', query='sslmode=verify-full', fragment=1), None), None, 'relaycast_owner')

    def test_explicit_in_cluster_skips_local_credentials(self):
        calls, _, _, report = self.run_main('network', ['--scope', 'database', '--in-cluster'])
        self.assertEqual(calls, 1)
        self.assertNotIn('ca', report['missingInputs'])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            diag.parse_args(['--in-cluster', '--secret-dir', '/tmp'])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            diag.parse_args(['--in-cluster', '--no-in-cluster'])
        self.assertEqual(diag.parse_args([]).psql_image, os.environ.get('PSQL_IMAGE') or diag.PSQL_IMAGE)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            diag.parse_args(['--psql-image', 'ghcr.io/cloudnative-pg/postgresql:17'])   # a tag can be swapped


class PostgreSQLCatalogTests(unittest.TestCase):
    """Isolated local Postgres only; never uses the developer's current database."""
    @classmethod
    def setUpClass(cls):
        psql=shutil.which('psql')
        if not psql:
            raise unittest.SkipTest('local PostgreSQL binaries unavailable')
        cls.bin=Path(psql).resolve().parent
        if not (cls.bin/'initdb').exists() or os.getuid()==0:
            raise unittest.SkipTest('initdb unavailable or running as root')
        cls.tmp=tempfile.TemporaryDirectory(prefix='install-diagnostic-test-')
        cls.root=Path(cls.tmp.name)
        cls.env={k:v for k,v in os.environ.items() if not k.startswith('PG')}
        try:
            subprocess.run([str(cls.bin/'initdb'),'-D',str(cls.root/'data'),'-A','trust','--no-locale'],check=True,capture_output=True,env=cls.env)
            cls.tls = bool(shutil.which('openssl'))
            server_options = "-F -c listen_addresses='' -k "+str(cls.root)
            if cls.tls:
                with socket.socket() as listener:
                    listener.bind(('127.0.0.1',0))
                    cls.port=listener.getsockname()[1]
                cls.cert=cls.root/'server.crt'
                key=cls.root/'server.key'
                subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1',
                                '-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost',
                                '-keyout',str(key),'-out',str(cls.cert)],check=True,capture_output=True)
                key.chmod(0o600)
                server_options = '-F -k '+str(cls.root)+' -p '+str(cls.port)+' -c listen_addresses=localhost -c ssl=on -c ssl_cert_file='+str(cls.cert)+' -c ssl_key_file='+str(key)
            subprocess.run([str(cls.bin/'pg_ctl'),'-D',str(cls.root/'data'),'-l',str(cls.root/'server.log'),'-o',server_options,'-w','start'],check=True,capture_output=True,env=cls.env)
            hba=cls.root/'data'/'pg_hba.conf'
            hba.write_text(''.join(line.replace('trust','scram-sha-256') if line.startswith('host') else line for line in hba.read_text().splitlines(keepends=True)))
            subprocess.run([str(cls.bin/'pg_ctl'),'-D',str(cls.root/'data'),'reload'],check=True,capture_output=True,env=cls.env)
            cls.query("""
CREATE ROLE relaycast_owner LOGIN PASSWORD 'p@ss:word';
CREATE ROLE relaycast_runtime LOGIN PASSWORD 'p@ss:word';
ALTER SCHEMA public OWNER TO relaycast_owner;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO relaycast_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO relaycast_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public GRANT SELECT,USAGE,UPDATE ON SEQUENCES TO relaycast_runtime;
REVOKE TEMP,CREATE ON DATABASE postgres FROM PUBLIC;
GRANT TEMP ON DATABASE postgres TO relaycast_owner;
GRANT CONNECT ON DATABASE postgres TO relaycast_owner,relaycast_runtime;
SET ROLE relaycast_owner;
CREATE TABLE public.diagnostic_fixture (id bigserial PRIMARY KEY);
RESET ROLE;
""")
        except Exception:
            cls.stop()
            raise

    @classmethod
    def query(cls,sql,role=None):
        argv=[str(cls.bin/'psql'),'-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-h',str(cls.root),'-d','postgres']
        if cls.tls:
            argv+=['-p',str(cls.port)]
        if role:
            argv+=['-U',role]
        return subprocess.run(argv,input=sql,text=True,capture_output=True,check=True,env=cls.env).stdout.strip()

    @classmethod
    def stop(cls):
        subprocess.run([str(cls.bin/'pg_ctl'),'-D',str(cls.root/'data'),'-m','immediate','stop'],capture_output=True,env=cls.env)
        cls.tmp.cleanup()

    @classmethod
    def tearDownClass(cls):
        cls.stop()

    def catalog(self):
        return json.loads(self.query('BEGIN READ ONLY;'+diag.CAST_SQL+'ROLLBACK;',role='relaycast_owner'))

    def test_good_and_broken_privileges(self):
        good=self.catalog()
        self.assertEqual(good['objects'],2)
        for key,value in good.items():
            if key=='objects':
                continue
            self.assertEqual(value,0 if key in ('wrong_owners','missing_table_grants','missing_sequence_grants') else True,key)
        mutations=[
            ('REVOKE SELECT ON public.diagnostic_fixture FROM relaycast_runtime;', 'missing_table_grants',1,
             'GRANT SELECT ON public.diagnostic_fixture TO relaycast_runtime;'),
            ('REVOKE USAGE ON SEQUENCE public.diagnostic_fixture_id_seq FROM relaycast_runtime;', 'missing_sequence_grants',1,
             'GRANT USAGE ON SEQUENCE public.diagnostic_fixture_id_seq TO relaycast_runtime;'),
            ('GRANT TEMP ON DATABASE postgres TO PUBLIC;', 'runtime_no_temp',False,
             'REVOKE TEMP ON DATABASE postgres FROM PUBLIC;'),
            ('GRANT CREATE ON DATABASE postgres TO relaycast_owner;', 'owner_no_db_create',False,
             'REVOKE CREATE ON DATABASE postgres FROM relaycast_owner;'),
            ('GRANT relaycast_owner TO relaycast_runtime;', 'runtime_no_owner_membership',False,
             'REVOKE relaycast_owner FROM relaycast_runtime;'),
            ('ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public REVOKE UPDATE ON TABLES FROM relaycast_runtime;', 'table_defaults',False,
             'ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public GRANT UPDATE ON TABLES TO relaycast_runtime;'),
        ]
        for change,key,expected,restore in mutations:
            with self.subTest(key=key):
                self.query(change)
                try:
                    self.assertEqual(self.catalog()[key],expected)
                finally:
                    self.query(restore)

    def test_migration_login_must_not_own_database(self):
        original_owner=self.query('SELECT current_user')
        self.query('ALTER DATABASE postgres OWNER TO relaycast_owner;')
        try:
            self.assertFalse(self.catalog()['owner_no_db_create'])
            identity=json.loads(self.query('BEGIN READ ONLY;'+diag.IDENTITY_SQL+'ROLLBACK;',role='relaycast_owner'))
            report=diag.Report()
            with mock.patch.object(diag,'psql',side_effect=[identity,self.catalog()]):
                diag.database_checks(options(),{'cast-owner':{'user':'relaycast_owner','database':'postgres'}},report)
            failures={c['check'] for c in report.checks if c['status']=='FAIL'}
            self.assertIn('database.cast-owner.no-database-owner-membership',failures)
            self.assertIn('cast.owner_no_db_create',failures)
        finally:
            quoted_owner='"'+original_owner.replace('"','""')+'"'
            self.query('ALTER DATABASE postgres OWNER TO '+quoted_owner+';')
            self.query('GRANT TEMP ON DATABASE postgres TO relaycast_owner;')

    def test_real_tls_and_read_only_client(self):
        if not self.tls:
            self.skipTest('openssl unavailable')
        credential=diag.parse_credential(url('relaycast_owner','postgres','localhost').replace(':5432/',':'+str(self.port)+'/'),None,'relaycast_owner')
        result=diag.psql(credential,diag.IDENTITY_SQL,5,self.cert)
        self.assertTrue(result['tls'])
        report=diag.Report()
        diag.database_checks(options(ca_file=self.cert),{'cast-owner':credential},report)
        self.assertFalse([c for c in report.checks if c['status']=='FAIL'])
        self.assertTrue(any(c['check']=='cast.table_defaults' and c['status']=='PASS' for c in report.checks))
        bad=dict(credential,password='intentionally-wrong-fixture')
        with self.assertRaisesRegex(diag.DiagnosticError,'authentication'):
            diag.psql(bad,diag.IDENTITY_SQL,5,self.cert)
        readonly=diag.psql(credential,"SELECT json_build_object('read_only',current_setting('transaction_read_only'));",5,self.cert)
        self.assertEqual(readonly['read_only'],'on')
        with self.assertRaises(diag.DiagnosticError):
            diag.psql(credential,'CREATE TABLE public.should_never_exist (id int);',5,self.cert)
        self.assertEqual(self.query("SELECT count(*) FROM pg_class WHERE relname='should_never_exist'"),'0')

    def test_identity_query_as_runtime(self):
        identity=json.loads(self.query('BEGIN READ ONLY;'+diag.IDENTITY_SQL+'ROLLBACK;',role='relaycast_runtime'))
        self.assertEqual(identity['user'],'relaycast_runtime')
        self.assertTrue(identity['restricted'])
        self.assertFalse(identity['admin_membership'])
        self.assertIn('relaycast_owner',identity['roles'])


if __name__=='__main__':
    unittest.main()
