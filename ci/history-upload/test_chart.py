"""Direct-upload authority is API-only and strictly opt-in."""
from pathlib import Path
import hashlib
import json
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
        self.assertEqual(hashlib.sha256(data).hexdigest(), '54438c939e85b11d255e25f80c0257994c54d5de5f8cf73adf9450aba94723c3')

    def test_compatible_contract_vector_is_presigned_without_kms(self):
        vector=json.loads((ROOT/'ci/history-upload/relay-upload-inbox-v1.vectors.json').read_text())['credentials']['presignedSelfhost']
        self.assertEqual(vector['kind'],'presigned')
        self.assertIsNone(vector['kmsKeyId'])
        self.assertEqual(vector['endpoint'],'https://objects.example.test:9000/relayhistory')
        self.assertNotIn('credentials',vector)
        self.assertTrue(vector['urls'][0]['url'].startswith(vector['endpoint']+'/'))

    def test_default_off_has_no_upload_secret(self):
        pod = next(d for d in self.render() if d['kind'] == 'Deployment')['spec']['template']['spec']
        env = {v['name']: v for v in pod['containers'][0]['env']}
        self.assertFalse(any(e.startswith('SELFHOST_HISTORY_UPLOAD_') for e in env))
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

class CompatibleUpload(unittest.TestCase):
    render = HistoryUpload.render
    def values(self, **changes):
        return {**UPLOAD, 'roleArn':'', 'kmsKeyArn':'',
                'publicEndpoint':'https://objects.selfhost.example/',
                'internalEndpoint':'http://session-object-storage.ci.svc.cluster.local:9000',
                'credentials':dict(existingSecret='minio-upload-issuer', accessKeyIdKey='id', secretAccessKeyKey='secret'), **changes}

    def test_compatible_credentials_are_api_only_scoped_files(self):
        docs=self.render(self.values())
        pod=next(d for d in docs if d['kind']=='Deployment')['spec']['template']['spec']
        c=pod['containers'][0]; env={e['name']:e for e in c['env']}
        self.assertEqual(env['SELFHOST_HISTORY_UPLOAD_PUBLIC_ENDPOINT']['value'],'https://objects.selfhost.example')
        self.assertEqual(env['SELFHOST_HISTORY_UPLOAD_INTERNAL_ENDPOINT']['value'],'http://session-object-storage.ci.svc.cluster.local:9000')
        self.assertNotIn('SELFHOST_HISTORY_UPLOAD_ROLE_ARN',env)
        self.assertNotIn('SELFHOST_HISTORY_UPLOAD_KMS_KEY_ARN',env)
        self.assertFalse(any(e.startswith('AWS_') for e in env))
        self.assertEqual(env['SELFHOST_HISTORY_UPLOAD_ACCESS_KEY_ID_FILE']['value'],'/var/run/agent-relay/history-upload-store/access-key-id')
        self.assertEqual(env['SELFHOST_HISTORY_UPLOAD_SECRET_ACCESS_KEY_FILE']['value'],'/var/run/agent-relay/history-upload-store/secret-access-key')
        volume=next(v for v in pod['volumes'] if v['name']=='history-upload-store')
        self.assertEqual(volume['secret'],dict(secretName='minio-upload-issuer',defaultMode=288,items=[dict(key='id',path='access-key-id'),dict(key='secret',path='secret-access-key')]))
        self.assertTrue(next(m for m in c['volumeMounts'] if m['name']=='history-upload-store')['readOnly'])
        job=next(d for d in docs if d['kind']=='Job')['spec']['template']
        base_job=next(d for d in self.render() if d['kind']=='Job')['spec']['template']
        self.assertEqual(job,base_job)
        check=subprocess.run(['kubeconform','-strict','-summary'],input=yaml.safe_dump_all(docs),capture_output=True,text=True)
        self.assertEqual(check.returncode,0,check.stdout+check.stderr)

    def test_opaque_kms_id_is_optional_only_for_compatible_store(self):
        for key in ['kes/tenant-key','k'*2048]:
            docs=self.render(self.values(kmsKeyArn=key))
            env={e['name']:e for d in docs if d['kind']=='Deployment' for e in d['spec']['template']['spec']['containers'][0]['env']}
            self.assertEqual(env['SELFHOST_HISTORY_UPLOAD_KMS_KEY_ARN']['value'],key)
        for key in ['bad key','k'*2049]:
            self.render(self.values(kmsKeyArn=key),failure='key ID without whitespace')
        self.render({**UPLOAD,'kmsKeyArn':''},failure='customer-managed KMS')
        self.render({**UPLOAD,'kmsKeyArn':'kes/tenant-key'},failure='customer-managed KMS')
        self.render(self.values(roleArn=UPLOAD['roleArn']),failure='roleArn must be empty')

    def test_endpoint_validation_and_dedicated_credentials(self):
        for url in ['http://objects.example','https://objects.example/path','https://user:password@objects.example','https://objects.example?x=y','https://objects.example#x','https://objects.example:0','https://objects.example:65536','https://objects.example//']:
            self.render(self.values(publicEndpoint=url),failure='historyUpload.publicEndpoint')
        self.render(self.values(internalEndpoint='http://unrelated.example:9000'),failure='internalEndpoint')
        self.render(self.values(credentials=dict(existingSecret='')),failure='credentials.existingSecret')
        self.render({**UPLOAD,'internalEndpoint':'https://private.example'},failure='internalEndpoint requires')
        self.render({**UPLOAD,'credentials':dict(existingSecret='minio-upload-issuer')},failure='credentials requires')

    def test_upload_credentials_do_not_override_other_aws_features(self):
        other=[dict(name='AWS_ACCESS_KEY_ID',valueFrom=dict(secretKeyRef=dict(name='separate-feed-aws',key='id')))]
        docs=self.render(self.values(),extra=dict(extraEnv=other))
        env={e['name']:e for d in docs if d['kind']=='Deployment' for e in d['spec']['template']['spec']['containers'][0]['env']}
        self.assertEqual(env['AWS_ACCESS_KEY_ID']['valueFrom']['secretKeyRef']['name'],'separate-feed-aws')
        self.assertIn('SELFHOST_HISTORY_UPLOAD_ACCESS_KEY_ID_FILE',env)

    def test_issuer_cannot_mount_owner_key_or_duplicate_keys(self):
        self.render(self.values(credentials=dict(existingSecret='relay-cloud-api',accessKeyIdKey='database-migrations-url',secretAccessKeyKey='secret')),failure='migration credential')
        self.render(self.values(credentials=dict(existingSecret='minio-upload-issuer',accessKeyIdKey='same',secretAccessKeyKey='same')),failure='distinct access and secret')

    def test_off_does_not_project_preconfigured_issuer_credentials(self):
        docs=self.render(self.values(mode='off'))
        pod=next(d for d in docs if d['kind']=='Deployment')['spec']['template']['spec']
        self.assertFalse(any(v['name']=='history-upload-store' for v in pod['volumes']))
        self.assertFalse(any(e['name'].startswith('SELFHOST_HISTORY_UPLOAD_') for e in pod['containers'][0]['env']))

    def test_endpoint_and_issuer_env_cannot_bypass_chart_values(self):
        for name in ['SELFHOST_HISTORY_UPLOAD_PUBLIC_ENDPOINT','SELFHOST_HISTORY_UPLOAD_INTERNAL_ENDPOINT','SELFHOST_HISTORY_UPLOAD_ACCESS_KEY_ID','SELFHOST_HISTORY_UPLOAD_SECRET_ACCESS_KEY_FILE']:
            self.render(extra=dict(extraEnv=[dict(name=name,value='unsafe')]),failure='managed by historyUpload')

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

class BundledMinio(unittest.TestCase):
    def test_public_ingress_exposes_only_the_s3_api_with_tls(self):
        p=subprocess.run(['helm','template','test',str(ROOT/'charts/sessions-pipeline'),'-n','ci',
            '-f',str(ROOT/'charts/sessions-pipeline/ci/ingest-edge-values.yaml'),
            '-f',str(ROOT/'ci/history-upload/fixtures/minio-storage-values.yaml')],capture_output=True,text=True)
        self.assertEqual(p.returncode,0,p.stderr)
        docs=[d for d in yaml.safe_load_all(p.stdout) if d]
        ingress=next(d for d in docs if d['kind']=='Ingress' and d['metadata']['name']=='session-object-storage')
        self.assertEqual(ingress['spec']['ingressClassName'],'nginx')
        self.assertEqual(ingress['spec']['tls'],[dict(hosts=['objects.selfhost.example'],secretName='minio-public-tls')])
        self.assertEqual(ingress['spec']['rules'][0]['host'],'objects.selfhost.example')
        path=ingress['spec']['rules'][0]['http']['paths'][0]
        self.assertEqual(path['path'],'/')
        self.assertEqual(path['backend']['service'],dict(name='session-object-storage',port=dict(number=9000)))
        self.assertFalse(any('rewrite' in k for k in ingress['metadata'].get('annotations',{})))
        self.assertFalse(any('console' in d['metadata']['name'] for d in docs if d['kind']=='Ingress'))
        check=subprocess.run(['kubeconform','-strict','-summary'],input=yaml.safe_dump(ingress),capture_output=True,text=True)
        self.assertEqual(check.returncode,0,check.stdout+check.stderr)

if __name__ == '__main__':
    unittest.main()
