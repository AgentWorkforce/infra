"""Direct-upload authority is API-only and strictly opt-in."""
from pathlib import Path
import hashlib
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
UPLOAD = dict(mode="allowlist", allowlist=["test_user"], bucket="test-relay-sessions", region="us-west-2",
              roleArn="arn:aws:iam::111111111111:role/desktop-upload",
              kmsKeyArn="arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000",
              witness=dict(existingSecret="test-upload-witness", key="key"))

class HistoryUpload(unittest.TestCase):
    def render(self, upload=None, extra=None, failure=None):
        v = yaml.safe_load((ROOT / 'charts/relay-control/ci/default-values.yaml').read_text())
        if upload is not None:
            v['historyUpload'] = upload
        if extra:
            v.update(extra)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'values.yaml'
            path.write_text(yaml.safe_dump(v))
            p = subprocess.run(['helm', 'template', 'test', str(ROOT / 'charts/relay-control'), '-f', str(path)], text=True, capture_output=True)
        if failure:
            self.assertNotEqual(p.returncode, 0)
            self.assertIn(failure, p.stderr)
            return []
        self.assertEqual(p.returncode, 0, p.stderr)
        return [d for d in yaml.safe_load_all(p.stdout) if d]

    def test_frozen_contract_vector_pin(self):
        data=(ROOT/'ci/history-upload/relay-upload-inbox-v1.vectors.json').read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), '0753bf6f4111c03233d8defcb553e5d0783e101b04a402b079398d28a6bd901a')

    def test_default_off_has_no_upload_secret(self):
        pod = next(d for d in self.render() if d['kind'] == 'Deployment')['spec']['template']['spec']
        env = {v['name']: v for v in pod['containers'][0]['env']}
        self.assertEqual(env['SELFHOST_HISTORY_UPLOAD_DIRECT']['value'], 'off')
        self.assertFalse(any('WITNESS' in e for e in env))
        self.assertFalse(any(v['name'] == 'history-upload' for v in pod['volumes']))

    def test_witness_is_file_mounted_only_in_api(self):
        docs = self.render(UPLOAD)
        pod = next(d for d in docs if d['kind'] == 'Deployment')['spec']['template']['spec']
        api = pod['containers'][0]
        env = {v['name']: v for v in api['env']}
        self.assertEqual(env['SELFHOST_HISTORY_UPLOAD_MAX_OBJECT_BYTES']['value'], '2097152')
        self.assertEqual(env['SELFHOST_HISTORY_UPLOAD_WITNESS_KEY_FILE']['value'], '/var/run/agent-relay/history-upload/witness')
        self.assertEqual(next(v for v in pod['volumes'] if v['name'] == 'history-upload')['secret'], dict(secretName='test-upload-witness', defaultMode=288, items=[dict(key='key', path='witness')]))
        job = next(d for d in docs if d['kind'] == 'Job')['spec']['template']['spec']
        self.assertFalse(any(v['name'] == 'history-upload' for v in job['volumes']))
        self.assertFalse(any(e['name'].startswith('SELFHOST_HISTORY_UPLOAD_') for c in job['containers'] for e in c.get('env', [])))

    def test_missing_inputs_refuse(self):
        for field, value in [('allowlist', []), ('bucket', ''), ('roleArn', ''), ('kmsKeyArn', ''), ('witness', dict(existingSecret='', key='key'))]:
            with self.subTest(field=field):
                self.render({**UPLOAD, field: value}, failure='historyUpload')

    def test_extra_env_cannot_override_guard_or_leak_witness(self):
        for name in ['SELFHOST_HISTORY_UPLOAD_DIRECT', 'SELFHOST_HISTORY_UPLOAD_WITNESS_KEY', 'SELFHOST_HISTORY_UPLOAD_WITNESS_KEY_FILE']:
            self.render(extra=dict(extraEnv=[dict(name=name, value='unsafe')]), failure='managed by historyUpload')

class UploadConsumer(unittest.TestCase):
    def render(self, mode='allowlist', admission='async', allowlist=None, failure=None):
        v = {'ingestEdge': {'createServiceAccount': True, 'admission': {'mode': admission}, 'uploadDirect': dict(mode=mode,
            allowlist=['org:test_org'] if allowlist is None else allowlist, scanBatch=16,
            witness=dict(existingSecret='test-upload-witness', key='key'))}}
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'values.yaml'; path.write_text(yaml.safe_dump(v))
            p=subprocess.run(['helm','template','test',str(ROOT/'charts/sessions-pipeline'),'-n','ci',
                '-f',str(ROOT/'charts/sessions-pipeline/ci/ingest-edge-pod-identity-values.yaml'),'-f',str(path)],capture_output=True,text=True)
        if failure:
            self.assertNotEqual(p.returncode,0); self.assertIn(failure,p.stderr); return []
        self.assertEqual(p.returncode,0,p.stderr)
        return [d for d in yaml.safe_load_all(p.stdout) if d]

    def test_async_scan_and_witness_use_existing_secret(self):
        docs=self.render()
        sa=next(d for d in docs if d['kind']=='ServiceAccount' and d['metadata']['name']=='agent-relay-ingest')
        self.assertFalse(sa['automountServiceAccountToken'])
        pod=next(d for d in docs if d['kind']=='Deployment' and d['metadata']['name']=='test-ingest-edge')['spec']['template']['spec']
        env={e['name']:e for e in pod['containers'][0]['env']}
        self.assertEqual(env['HISTORY_UPLOAD_DIRECT']['value'],'allowlist')
        self.assertEqual(env['HISTORY_UPLOAD_DIRECT_ALLOWLIST']['value'],'org:test_org')
        self.assertEqual(env['SELFHOST_INGEST_ADMISSION']['value'],'async')
        self.assertEqual(env['UPLOAD_WITNESS_KEY']['valueFrom']['secretKeyRef'],dict(name='test-upload-witness',key='key'))
        self.assertIn('exec',pod['containers'][0]['readinessProbe'])
        check=subprocess.run(['kubeconform','-strict','-summary'],input=yaml.safe_dump_all(docs),capture_output=True,text=True)
        self.assertEqual(check.returncode,0,check.stdout+check.stderr)
        self.assertFalse(any('UPLOAD_WITNESS_KEY'==e['name'] for d in docs if d['kind']=='Job' for c in d['spec']['template']['spec']['containers'] for e in c.get('env',[])))

    def test_off_does_not_receive_witness(self):
        docs=self.render(mode='off',admission='sync')
        pod=next(d for d in docs if d['kind']=='Deployment' and d['metadata']['name']=='test-ingest-edge')['spec']['template']['spec']
        self.assertFalse(any(e['name']=='UPLOAD_WITNESS_KEY' for e in pod['containers'][0]['env']))

    def test_sync_and_drain_cannot_accidentally_restore_sql_on_the_hot_path(self):
        for mode in ['sync','drain']:
            self.render(admission=mode,failure='admission.mode=async')

    def test_empty_or_malformed_consumer_allowlist_refuses(self):
        for entries in [[],['user:test'],['org:.hidden'],['ws:a,b']]:
            self.render(allowlist=entries,failure='uploadDirect.allowlist')

if __name__ == '__main__':
    unittest.main()
