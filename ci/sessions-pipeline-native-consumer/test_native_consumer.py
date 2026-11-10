"""Native consumer admission, credential separation and causal contract/probe tests."""
import copy
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'charts/sessions-pipeline/ci/native-consumer-values.yaml'
FILES = ROOT / 'charts/sessions-pipeline/files/native-consumer'

class Consumer(unittest.TestCase):
    def render(self, overlay=None, fail=False, defaults=False, all_docs=False):
        values = yaml.safe_load(FIXTURE.read_text())
        if defaults:
            values.pop('nativeConsumer')
        def merge(a, b):
            for k,v in b.items():
                if isinstance(v,dict) and isinstance(a.get(k),dict): merge(a[k],v)
                else: a[k]=v
        merge(values, overlay or {})
        with tempfile.TemporaryDirectory(prefix='native-consumer-render-') as folder:
            f=Path(folder)/'values.yaml';f.write_text(yaml.safe_dump(values))
            result=subprocess.run(['helm','template','test',str(ROOT/'charts/sessions-pipeline'),'-n','ci','--is-upgrade','-f',str(f),
                '--set','worker.acknowledgeWorkloadRename=true','--set','acknowledgeStorageRename=true'],capture_output=True,text=True)
        if fail:
            self.assertNotEqual(result.returncode,0)
            return result.stderr
        self.assertEqual(result.returncode,0,result.stderr)
        docs=[d for d in yaml.safe_load_all(result.stdout) if d]
        return docs if all_docs else [d for d in docs if d.get('metadata',{}).get('labels',{}).get('app.kubernetes.io/name')=='session-pipeline-consumer']
    def pod(self, docs, kind='Deployment'):
        return next(d['spec']['template']['spec'] for d in docs if d['kind']==kind)
    def env(self,c): return {e['name']:e for e in c['env']}
    def native(self, **kwargs): return {'nativeConsumer':kwargs}
    def boot(self, phase='prepare'):
        return self.native(bootstrap={'enabled':True,'existingSecret':'consumer-owner','ownerRole':'hoop','phase':phase})
    def test_parallel_search_indexer_refuses(self):
        self.assertIn("searchIndexer.enabled=false",self.render({'searchIndexer':yaml.safe_load(ROOT.joinpath('charts/sessions-pipeline/ci/search-indexer-values.yaml').read_text())['searchIndexer']},fail=True))
    def test_default_off_and_boolean_selection(self):
        self.assertEqual(self.render(defaults=True),[])
        for value in ['true',1,None]:
            with self.subTest(value=value): self.render(self.native(enabled=value),fail=True)
    def test_managed_runtime_is_single_writer_and_has_no_owner_credentials(self):
        docs=self.render();self.assertEqual({d['kind'] for d in docs},{'Deployment','ConfigMap'})
        d=next(d for d in docs if d['kind']=='Deployment');self.assertEqual(d['spec']['replicas'],1);self.assertEqual(d['spec']['strategy'],{'type':'Recreate'})
        p=self.pod(docs);self.assertFalse(p['automountServiceAccountToken'])
        self.assertEqual(p['securityContext']['runAsUser'],1000)
        for c in p['containers']+p['initContainers']:
            env=self.env(c);self.assertEqual(env['RELAYHISTORY_PIPELINE_CONSUMER_SECRET']['valueFrom']['secretKeyRef'],{'name':'consumer-runtime','key':'RELAYHISTORY_PIPELINE_CONSUMER_SECRET'})
            self.assertNotIn('HOOPDB_URL',env)
            self.assertEqual(env['PIPELINE_FANOUT']['value'],'off')
            self.assertEqual(env['READER_MAX_RULESET']['value'],'8')
            self.assertEqual(env['PIPELINE_KEY_PREFIX']['value'],'96bulls')
            self.assertEqual(env['SEARCH_INDEX_BACKEND']['value'],'postgres')
            self.assertEqual(env['SESSION_POSTGRES_TLS_PROFILE']['value'],'custom-ca')
            self.assertTrue(c['securityContext']['readOnlyRootFilesystem'])
        runtime_ca=next(m for m in p['containers'][0]['volumeMounts'] if m['name']=='postgres-ca')
        self.assertTrue(runtime_ca['readOnly'])
        self.assertNotIn('postgres-ca-source',[m['name'] for m in p['containers'][0]['volumeMounts']])
        init_ca=next(m for m in p['initContainers'][0]['volumeMounts'] if m['name']=='postgres-ca')
        self.assertFalse(init_ca.get('readOnly',False))
        self.assertTrue(next(m for m in p['initContainers'][0]['volumeMounts'] if m['name']=='postgres-ca-source')['readOnly'])
        self.assertEqual(next(v for v in p['volumes'] if v['name']=='postgres-ca')['emptyDir'],{'medium':'Memory','sizeLimit':'256Ki'})
        ca=next(v for v in p['volumes'] if v['name']=='postgres-ca-source')['configMap']
        self.assertEqual(ca['items'],[{'key':'ca.crt','path':'ca.crt'}]);self.assertEqual(ca['defaultMode'],292)
        self.assertEqual(self.env(p['containers'][0])['SERVICE']['value'],'session-pipeline-consumer')
    def test_reader_ruleset_ceiling_is_exact_and_does_not_enable_the_consumer(self):
        for ceiling in [8,9,10]:
            with self.subTest(ceiling=ceiling):
                docs=self.render(self.native(readerMaxRuleset=ceiling))
                for container in self.pod(docs)['containers']+self.pod(docs)['initContainers']:
                    self.assertEqual(self.env(container)['READER_MAX_RULESET']['value'],str(ceiling))
        for ceiling in [7,11,'padded',' 8',8.5,None,True]:
            with self.subTest(ceiling=ceiling):
                self.assertIn('readerMaxRuleset',self.render(self.native(enabled=False,readerMaxRuleset=ceiling),fail=True))
        self.assertEqual(self.render(self.native(enabled=False,readerMaxRuleset=10)),[])
    def test_native_slot_renders_under_umbrella_scope(self):
        values=yaml.safe_load(FIXTURE.read_text())
        image=values['nativeConsumer']['image'];ca={'enabled':True,'configMap':'postgres-ca','key':'ca.crt','secret':''}
        values['nativeConsumer']['legacyRuntimesQualified']=True
        values['worker']['image']=copy.deepcopy(image);values['worker']['postgresCa']=copy.deepcopy(ca)
        values['worker']['components']['referee']['replicas']=1
        values['alleyoop']['image']=copy.deepcopy(image);values['alleyoop']['postgresCa']=copy.deepcopy(ca);values['alleyoop']['ingest']['replicas']=1
        with tempfile.TemporaryDirectory(prefix='native-consumer-umbrella-') as folder:
            f=Path(folder)/'values.yaml'
            f.write_text(yaml.safe_dump({'components':{'telemetryCollector':False,'relaycast':False,'relayauth':False,'sessionsPipeline':True,'relayhistory':False,'control':False,'webapp':False,'relayflows':False,'durableActors':False,'relayfile':False,'relayChief':False},'sessions-pipeline':values}))
            result=subprocess.run(['helm','template','test',str(ROOT/'charts/agent-relay'),'-f',str(f)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            docs=list(yaml.safe_load_all(result.stdout))
            self.assertTrue(any(d and d['kind']=='Deployment' and d['metadata']['labels'].get('app.kubernetes.io/name')=='session-pipeline-consumer' for d in docs))
    def test_public_ca_is_frozen_across_source_updates_and_init_retries(self):
        with tempfile.TemporaryDirectory(prefix='public-ca-freeze-') as folder:
            target=Path(folder)/'ca.crt'
            code="""import {freezePublicCa} from %s; import {readFileSync} from 'node:fs';
            const p=process.argv[1]; freezePublicCa('validated-public-ca-a',p); freezePublicCa('validated-public-ca-a',p);
            let refused=false;try{freezePublicCa('changed-public-ca-b',p)}catch{refused=true}
            if(!refused||readFileSync(p,'utf8')!=='validated-public-ca-a')process.exit(1);""" % json.dumps((FILES/'preflight.mjs').as_uri())
            result=subprocess.run(['node','--input-type=module','-e',code,str(target)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(target.stat().st_mode & 0o777,0o444)
    def test_bootstrap_is_owner_only_prepare_then_serve_and_has_no_hooks(self):
        docs=self.render(self.boot());self.assertEqual({d['kind'] for d in docs},{'Job','ConfigMap'})
        job=next(d for d in docs if d['kind']=='Job');self.assertEqual(job['spec']['backoffLimit'],0)
        self.assertEqual(job['spec']['template']['spec']['restartPolicy'],'Never');self.assertNotIn('helm.sh/hook',job['metadata'].get('annotations',{}))
        p=self.pod(docs,'Job')
        for c in p['containers']+p['initContainers']:
            env=self.env(c);self.assertEqual(env['RELAYHISTORY_PIPELINE_CONSUMER_SECRET']['valueFrom']['secretKeyRef']['name'],'consumer-owner')
            self.assertEqual(env['SERVICE']['value'],'session-pipeline-consumer-bootstrap')
            self.assertNotIn('READER_MAX_RULESET',env)
            self.assertNotIn('LOCKER_SECRET_ACCESS_KEY',env)
        served=self.render(self.boot('serve'));self.assertIn('Deployment',{d['kind'] for d in served})
        self.assertEqual(job['metadata']['name'],next(d['metadata']['name'] for d in served if d['kind']=='Job'))
        for c in self.pod(served)['containers']+self.pod(served)['initContainers']:
            self.assertNotIn('consumer-owner',json.dumps(c))
        self.render(self.native(bootstrap={'enabled':True,'ownerRole':'hoop','existingSecret':'consumer-runtime'}),fail=True)
        self.render(self.native(bootstrap={'enabled':True,'ownerRole':'hoop','existingSecret':'consumer-store'}),fail=True)
        self.render(self.native(bootstrap={'enabled':True,'ownerRole':'hoop','existingSecret':'pull-owner'},imagePullSecrets=[{'name':'pull-owner'}]),fail=True)
    def test_bootstrap_name_changes_with_actual_job_inputs(self):
        base=self.boot();name=next(d['metadata']['name'] for d in self.render(base) if d['kind']=='Job')
        changes=[{'bootstrap':{'existingSecret':'new-owner'}},{'bootstrap':{'key':'another-key'}},{'postgres':{'caSha256':'b'*64}},
                 {'image':{'digest':'sha256:'+'e'*64}},{'backendId':'other-id'},{'completeSince':'2026-11-09T00:00:00Z'},
                 {'postgres':{'database':'otherdb'}},{'bootstrap':{'activeDeadlineSeconds':1000}}]
        for change in changes:
            overlay=copy.deepcopy(base)
            for k,v in change.items():
                if isinstance(v,dict):overlay['nativeConsumer'].setdefault(k,{}).update(v)
                else:overlay['nativeConsumer'][k]=v
            with self.subTest(change=change):self.assertNotEqual(name,next(d['metadata']['name'] for d in self.render(overlay) if d['kind']=='Job'))
        # Reader compatibility is a runtime setting; it must never recreate the
        # privileged owner bootstrap Job whose name hashes its Pod spec.
        raised=self.boot();raised['nativeConsumer']['readerMaxRuleset']=10
        self.assertEqual(name,next(d['metadata']['name'] for d in self.render(raised) if d['kind']=='Job'))
    def test_bad_image_ca_target_and_layout_inputs_refuse(self):
        for change in [{'image':{'digest':''}},{'image':{'digest':'latest'}},{'image':{'repository':'image:latest'}},{'image':{'tag':'latest'}},
                       {'postgres':{'caSha256':'A'*64}},{'postgres':{'caConfigMap':''}},{'postgres':{'caKey':'a'*254}},{'postgres':{'host':'127.0.0.1'}},
                       {'postgres':{'database':''}},{'postgres':{'port':65536}},{'config':{'existingSecret':''}},
                       {'backendId':''},{'completeSince':''},{'completeSince':'2026-02-31T00:00:00Z'},{'keyPrefix':'96bulls/org_ci'},
                       {'replicas':2},{'port':443},{'reconcileEveryMinutes':30},{'preflight':{'timeoutSeconds':0}},
                       {'bootstrap':{'phase':'auto'}},{'locker':{'bucket':' sessions'}},{'locker':{'credentials':{'mode':'gcs'}}}]:
            with self.subTest(change=change):self.render(self.native(**change),fail=True)
    def test_no_env_or_command_escape_and_old_indexer_is_disabled_and_drained(self):
        for name in ['extraEnv','envFrom','command','extraVolumes','extraVolumeMounts']:
            with self.subTest(name=name):self.render(self.native(**{name:[]}),fail=True)
        self.render({'worker':{'components':{'hoopdb-indexer':{'enabled':True}}}},fail=True)
        self.render(self.native(legacyIndexerDrained=False),fail=True)
    def test_old_migrator_and_unqualified_active_legacy_runtimes_refuse(self):
        self.render({'worker':{'migrations':{'enabled':True}}},fail=True)
        self.render(self.native(migrationDriverVerified=False),fail=True)
        for entry in [{'worker':{'components':{'referee':{'replicas':1}}}},{'alleyoop':{'ingest':{'replicas':1}}}]:
            self.render(entry,fail=True)
        image=yaml.safe_load(FIXTURE.read_text())['nativeConsumer']['image']
        ca={'enabled':True,'configMap':'postgres-ca','key':'ca.crt','secret':''}
        good={'worker':{'components':{'referee':{'replicas':1}},'image':image,'postgresCa':ca},
              'alleyoop':{'ingest':{'replicas':1},'image':image,'postgresCa':ca},'nativeConsumer':{'legacyRuntimesQualified':True}}
        self.render(good)
        for key in ['worker','alleyoop']:
            bad=copy.deepcopy(good);bad[key]['image']['digest']='';bad[key]['image']['tag']='latest';self.render(bad,fail=True)
            bad=copy.deepcopy(good);bad[key]['postgresCa']['configMap']='wrong-ca';self.render(bad,fail=True)
            bad=copy.deepcopy(good);bad['nativeConsumer']['legacyRuntimesQualified']=False;self.render(bad,fail=True)
        # Relative repositories resolve through the actual child helper/global registry.
        relative=copy.deepcopy(good)
        relative['nativeConsumer']['image']=copy.deepcopy(image)
        relative['nativeConsumer']['image']['repository']='ghcr.io/agentworkforce/qualified-services'
        for key in ['worker','alleyoop']:relative[key]['image']['repository']='agentworkforce/qualified-services'
        self.render(relative)
    def test_secret_and_pod_identity_are_mutually_exclusive(self):
        overlay=self.native(serviceAccountName='consumer-role',locker={'credentials':{'mode':'podIdentity'},'existingSecret':'','endpoint':''})
        p=self.pod(self.render(overlay));env=self.env(p['containers'][0])
        self.assertNotIn('LOCKER_ACCESS_KEY_ID',env);self.assertNotIn('LOCKER_SECRET_ACCESS_KEY',env)
        self.assertEqual(p['serviceAccountName'],'consumer-role')
        overlay['nativeConsumer']['locker']['existingSecret']='static-too';self.render(overlay,fail=True)
        overlay['nativeConsumer']['locker']['existingSecret']='';overlay['nativeConsumer']['serviceAccountName']='';self.render(overlay,fail=True)
    def composition(self):
        c=yaml.safe_load(FIXTURE.read_text())['nativeConsumer']
        extra={'LOCKER_BUCKET':c['locker']['bucket'],
               'LOCKER_ENDPOINT':c['locker']['endpoint'],'LOCKER_REGION':'us-east-1','PIPELINE_KEY_PREFIX':'96bulls','PIPELINE_ORG_FROM_PREFIX':'true'}
        return {'sessionReadApi':{'enabled':True,'image':c['image'],'origin':'https://history.kind.agentrelay.com:8443','completeSince':c['completeSince'],
            'search':{'backend':'postgres','backendId':c['backendId']},'postgres':{'tlsProfile':'custom-ca'},'postgresCa':{'enabled':True,'configMap':c['postgres']['caConfigMap'],'key':c['postgres'].get('caKey','ca.crt'),'sha256':c['postgres']['caSha256']},'directoryWorkspaces':'workspace-ci','allowInClusterHttp':True,'config':{'existingSecret':'reader-config'},'auth':{'mode':'relaycontrol_only','relaycontrol':{
            'enabled':True,'url':'http://relay-control.ci.svc.cluster.local','existingSecret':'introspect'}},'extraEnv':[{'name':k,'value':v} for k,v in extra.items()]}}
    def test_standalone_reader_renders_control_only_canonical_contract(self):
        good=self.composition();good['sessionReadApi']['login']={'advertisesSync':True}
        docs=self.render(good,all_docs=True)
        reader=next(d for d in docs if d['kind']=='Deployment' and d['metadata']['name']=='test-read-api')
        pod=reader['spec']['template']['spec'];container=pod['containers'][0];env=self.env(container)
        c=yaml.safe_load(FIXTURE.read_text())['nativeConsumer']
        for name,value in {'SERVICE':'session-read-api','RELAYHISTORY_SELFHOST_READ_API':'true','READ_API_AUTH_MODE':'relaycontrol_only',
            'RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS':'true','RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC':'true',
            'READ_API_ORIGIN':'https://history.kind.agentrelay.com:8443','SEARCH_INDEX_BACKEND':'postgres','SEARCH_INDEX_POSTGRES_BACKEND_ID':c['backendId'],
            'READ_API_COMPLETE_SINCE':c['completeSince'],'SESSION_POSTGRES_TLS_PROFILE':'custom-ca','SESSION_POSTGRES_CA_SHA256':c['postgres']['caSha256'],
            'LOCKER_BUCKET':c['locker']['bucket'],'PIPELINE_KEY_PREFIX':'96bulls','PIPELINE_ORG_FROM_PREFIX':'true'}.items():
            self.assertEqual(env[name]['value'],value,name)
        self.assertEqual(container['image'],c['image']['repository']+'@'+c['image']['digest'])
        self.assertEqual(env['RELAYHISTORY_READ_API_SECRET']['valueFrom']['secretKeyRef']['name'],'reader-config')
        self.assertEqual(env['RELAYCONTROL_INTROSPECT_SECRET']['valueFrom']['secretKeyRef']['name'],'introspect')
        self.assertNotIn('READ_API_INTERNAL_SECRET',env);self.assertNotIn('RELAYAUTH_ISSUER',env);self.assertNotIn('RELAYAUTH_JWKS_URL',env)
        self.assertEqual(next(v for v in pod['volumes']if v['name']=='postgres-ca')['configMap']['name'],c['postgres']['caConfigMap'])
        for change in [{'auth':{'relayauth':{'issuer':'https://legacy.example.com'}}},{'postgresCa':{'sha256':'f'*64}},{'postgresCa':{'configMap':'other-ca'}}]:
            bad=copy.deepcopy(good)
            def merge(a,b):
                for k,v in b.items():
                    if isinstance(v,dict) and isinstance(a.get(k),dict):merge(a[k],v)
                    else:a[k]=v
            merge(bad['sessionReadApi'],change);self.render(bad,fail=True)
    def test_reader_composition_requires_same_image_backend_floor_and_literal_layout(self):
        good=self.composition();self.render(good)
        for change in [{'search':{'backend':'postgres','backendId':'wrong'}},{'completeSince':'epoch'},{'search':{'backend':'clickhouse'}},{'image':{'digest':'sha256:'+'e'*64}}]:
            bad=copy.deepcopy(good);bad['sessionReadApi'].update(change)
            with self.subTest(change=change):self.render(bad,fail=True)
        for name in ['LOCKER_BUCKET','PIPELINE_KEY_PREFIX','PIPELINE_ORG_FROM_PREFIX','LOCKER_ENDPOINT']:
            bad=copy.deepcopy(good);next(e for e in bad['sessionReadApi']['extraEnv'] if e['name']==name)['value']='wrong'
            with self.subTest(name=name):self.render(bad,fail=True)
        bad=copy.deepcopy(good);bad['sessionReadApi']['extraEnv'][0]={'name':'LOCKER_BUCKET','valueFrom':{'configMapKeyRef':{'name':'opaque','key':'id'}}};self.render(bad,fail=True)
    def test_owner_secret_cannot_reach_enabled_reader_by_any_runtime_reference(self):
        good=self.composition();good.update(self.boot('serve'));self.render(good)
        refs=[{'config':{'existingSecret':'consumer-owner','key':'RELAYHISTORY_PIPELINE_CONSUMER_SECRET'}},
              {'auth':{'relaycontrol':{'existingSecret':'consumer-owner'}}},
              {'imagePullSecrets':[{'name':'consumer-owner'}]},
              {'extraVolumes':[{'name':'owner','secret':{'secretName':'consumer-owner'}}]},
              {'extraVolumes':[{'name':'owner','projected':{'sources':[{'secret':{'name':'consumer-owner'}}]}}]}]
        for env_name in ['COPIED_OWNER_JSON','HOOPDB_URL']:
            refs.append({'extraEnv':good['sessionReadApi']['extraEnv']+[{'name':env_name,'valueFrom':{'secretKeyRef':{'name':'consumer-owner','key':'RELAYHISTORY_PIPELINE_CONSUMER_SECRET'}}}]})
        for job_enabled in [True,False]:
            for ref in refs:
                with self.subTest(job_enabled=job_enabled,ref=ref):
                    bad=copy.deepcopy(good);bad['nativeConsumer']['bootstrap']['enabled']=job_enabled
                    def merge(a,b):
                        for k,v in b.items():
                            if isinstance(v,dict) and isinstance(a.get(k),dict):merge(a[k],v)
                            else:a[k]=copy.deepcopy(v)
                    merge(bad['sessionReadApi'],ref)
                    self.assertIn('owner bootstrap Secret must not be referenced by runtime',self.render(bad,fail=True))
        # Same key in a dedicated runtime Secret is supported; the owner object is Job-only.
        good['sessionReadApi']['extraEnv'].append({'name':'READER_JSON','valueFrom':{'secretKeyRef':{'name':'reader-runtime','key':'RELAYHISTORY_PIPELINE_CONSUMER_SECRET'}}})
        self.render(good)
        disabled=copy.deepcopy(good);disabled['sessionReadApi']['enabled']=False;disabled['sessionReadApi']['config']['existingSecret']='consumer-owner'
        self.render(disabled)

    def test_owner_secret_is_not_a_native_ingest_or_post_prepare_consumer_credential(self):
        base=yaml.safe_load(ROOT.joinpath('charts/sessions-pipeline/ci/ingest-edge-values.yaml').read_text())['ingestEdge']
        c=yaml.safe_load(FIXTURE.read_text())['nativeConsumer'];base['image']=c['image'];base['locker']=c['locker']
        good={'ingestEdge':base};good.update(self.boot('serve'));self.render(good)
        for field in ['config','locker']:
            bad=copy.deepcopy(good);bad['ingestEdge'][field]['existingSecret']='consumer-owner'
            self.assertIn('owner bootstrap Secret must not be referenced by runtime',self.render(bad,fail=True))
        bad=self.native(config={'existingSecret':'consumer-owner'},bootstrap={'enabled':False,'existingSecret':'consumer-owner','phase':'serve'})
        self.assertIn('owner bootstrap Secret must not be referenced by runtime',self.render(bad,fail=True))

    def test_native_ingest_must_share_store_and_qualified_image(self):
        base=yaml.safe_load(ROOT.joinpath('charts/sessions-pipeline/ci/ingest-edge-values.yaml').read_text())['ingestEdge']
        c=yaml.safe_load(FIXTURE.read_text())['nativeConsumer'];base['image']=c['image'];base['locker']=c['locker']
        self.render({'ingestEdge':base})
        for key in ['bucket','endpoint','region']:
            bad=copy.deepcopy(base);bad['locker'][key]='other' if key!='endpoint' else 'https://other.agentrelay.com'
            with self.subTest(key=key):self.render({'ingestEdge':bad},fail=True)
    def test_rendered_native_objects_are_schema_valid(self):
        docs=self.render(self.boot('serve'))
        p=subprocess.run(['kubeconform','-strict','-summary'],input=yaml.safe_dump_all(docs),capture_output=True,text=True)
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
    def test_runtime_url_contract_refuses_wrong_role_target_or_worker_pool_tls(self):
        code="""import {validateTarget} from %s; const env=JSON.parse(process.env.FIXTURE_ENV); try{validateTarget(process.env.FIXTURE_SECRET,env);process.exit(0)}catch{console.error('contract_refused');process.exit(1)}""" % json.dumps((FILES/'preflight.mjs').as_uri())
        env={'NATIVE_CONSUMER_PREFLIGHT_MODE':'runtime','NATIVE_CONSUMER_EXPECTED_DATABASE':'hoopdb','NATIVE_CONSUMER_EXPECTED_HOST':'postgres.ci.svc.cluster.local','NATIVE_CONSUMER_EXPECTED_PORT':'5432','SESSION_POSTGRES_CA_FILE':'/etc/native-consumer-postgres/ca.crt'}
        good='postgresql://search_consumer_runtime:fixture-not-a-secret@postgres.ci.svc.cluster.local:5432/hoopdb?sslmode=verify-full&sslrootcert=%2Fetc%2Fnative-consumer-postgres%2Fca.crt'
        def check(url,ok):
            p=subprocess.run(['node','--input-type=module','-e',code],env={**os.environ,'FIXTURE_ENV':json.dumps(env),'FIXTURE_SECRET':json.dumps({'hoopdb_url':url})},capture_output=True,text=True)
            self.assertEqual(p.returncode==0,ok,p.stderr);self.assertNotIn('fixture-not-a-secret',p.stdout+p.stderr)
        check(good,True)
        for bad in [good.replace('search_consumer_runtime','postgres'),good.replace('verify-full','disable'),good.replace('verify-full','require'),
                    good.replace('/hoopdb?','/wrong?'),good.replace('postgres.ci','wrong.ci'),good.replace(':5432/',':5433/'),
                    good+'&options=-crole=postgres',good+'&sslmode=verify-full',good.replace('sslrootcert=','other='),good.replace('consumer-postgres','wrong-ca')]:
            with self.subTest(url=bad):check(bad,False)
    def test_real_probe_refuses_dormant_off_and_owned_failure_marker(self):
        state={'body':{'ok':True},'status':200,'calls':0}
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                state['calls']+=1;self.send_response(state['status']);self.end_headers();self.wfile.write(json.dumps(state['body']).encode())
            def log_message(self,*args):pass
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix='native-consumer-probe-',dir='/tmp') as folder:
                marker=Path(folder)/'unhealthy';env={**os.environ,'RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER':'true','WORKER_HEALTH_PORT':str(server.server_port),'CONSUMER_UNHEALTHY_FILE':str(marker)}
                def probe(mode='ready'):
                    return subprocess.run(['node',str(FILES/'probe.mjs'),mode],env=env,capture_output=True,text=True).returncode
                self.assertEqual(probe(),0);self.assertEqual(probe('live'),0)
                for body in [{'ok':True,'dormant':True},{'ok':True,'enabled':False},{'ok':False}]:
                    state['body']=body;self.assertNotEqual(probe(),0)
                state['body']={'ok':True};before=state['calls'];env['RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER']='false';self.assertNotEqual(probe(),0);self.assertEqual(state['calls'],before)
                env['RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER']='true';marker.write_text('failed');self.assertNotEqual(probe(),0);self.assertEqual(state['calls'],before)
        finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main()
