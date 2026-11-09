"""Typed native model worker admission and component-only network/secret/CA contract."""
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT=Path(__file__).resolve().parents[2]
CHART='charts/sessions-pipeline-worker'

class NativeBrief(unittest.TestCase):
    def render(self,values,refuses=None):
        with tempfile.TemporaryDirectory() as t:
            f=Path(t)/'values.json';f.write_text(json.dumps(values))
            r=subprocess.run(['helm','template','proof',CHART,'-n','agent-relay','-f',CHART+'/ci/default-values.yaml','-f',str(f)],cwd=ROOT,text=True,capture_output=True)
        if refuses:
            self.assertNotEqual(r.returncode,0);self.assertIn(refuses.lower(),r.stderr.lower());return []
        self.assertEqual(r.returncode,0,r.stderr)
        return [d for d in yaml.safe_load_all(r.stdout) if d]

    def selected(self):
        return {'migrations':{'enabled':False},'components':{'session-brief':{'enabled':True},'hoopdb-indexer':{'enabled':False},'referee':{'enabled':False},'bob-costas':{'enabled':False}},'nativeBrief':{'enabled':True,'image':{'repository':'agentworkforce/native-services','digest':'sha256:'+'b'*64},'workspaceIds':['default-workspace'],'openaiSecret':{'name':'brief-model-key'},'openaiEgress':{'enabled':True,'to':[{'ipBlock':{'cidr':'203.0.113.0/24'}}]}},'postgresCa':{'enabled':True,'configMap':'public-pg-ca','sha256':'a'*64},'networkPolicy':{'enabled':True,'dns':{'to':[{'namespaceSelector':{'matchLabels':{'kubernetes.io/metadata.name':'kube-system'}}}]},'database':{'to':[{'podSelector':{'matchLabels':{'app':'postgres'}}}]},'objectStorage':{'to':[{'podSelector':{'matchLabels':{'app':'locker'}}}]}}}

    def brief(self,docs):
        return next(d for d in docs if d['kind']=='Deployment' and d['spec']['template']['metadata']['labels']['app.kubernetes.io/component']=='session-brief')['spec']['template']['spec']

    def test_default_has_no_brief_resources_or_model_secret(self):
        docs=self.render({});s=json.dumps(docs)
        self.assertNotIn('SESSION_BRIEF_CANONICAL_INPUT',s);self.assertNotIn('OPENAI_API_KEY',s)
        self.assertFalse(any(d['metadata']['name'].endswith('-brief-openai') for d in docs))
        self.render({'extraEnv':[{'name':'SESSION_BRIEF_CANONICAL_INPUT','value':'true'}]},'use nativeBrief.enabled')
        self.render({'components':{'session-brief':{'enabled':True}}},'requires nativeBrief.enabled')
        self.assertFalse(any(d.get('spec',{}).get('template',{}).get('metadata',{}).get('labels',{}).get('app.kubernetes.io/component')=='session-brief' for d in docs))

    def test_native_env_secret_ca_health_and_egress_are_component_scoped(self):
        docs=self.render(self.selected());pod=self.brief(docs);main=pod['containers'][0]
        env={e['name']:e for e in main['env']};self.assertEqual(len(env),len(main['env']))
        self.assertEqual(env['SESSION_BRIEF_WORKSPACE_IDS']['value'],'default-workspace')
        self.assertEqual(env['SESSION_BRIEF_BATCH']['value'],'1');self.assertEqual(env['SESSION_BRIEF_GLOBAL_DAILY_CAP']['value'],'20');self.assertEqual(env['SESSION_BRIEF_SESSION_DAILY_CAP']['value'],'3');self.assertEqual(env['PIPELINE_KEY_PREFIX']['value'],'96bulls');self.assertEqual(env['PIPELINE_ORG_FROM_PREFIX']['value'],'true')
        self.assertEqual(env['OPENAI_API_KEY']['valueFrom']['secretKeyRef'],{'name':'brief-model-key','key':'OPENAI_API_KEY'})
        self.assertIn('readinessProbe',main)
        init=pod['initContainers'][0];self.assertEqual(init['command'],['bun','-e']);self.assertEqual(init['image'],main['image']);self.assertTrue(main['image'].endswith('@sha256:'+'b'*64))
        self.assertNotIn('OPENAI_API_KEY',json.dumps(init));self.assertTrue(init['volumeMounts'][0]['readOnly']);self.assertEqual(init['volumeMounts'][0]['mountPath'],'/var/run/native-brief-ca-source');self.assertEqual(next(m for m in main['volumeMounts'] if m['name']=='native-brief-verified-ca')['readOnly'],True);self.assertNotIn('postgres-ca',[m['name'] for m in main['volumeMounts']])
        self.assertEqual(next(v for v in pod['volumes'] if v['name']=='postgres-ca')['configMap']['name'],'public-pg-ca')
        policy=next(d for d in docs if d['kind']=='NetworkPolicy' and d['metadata']['name'].endswith('-brief-openai'))
        self.assertEqual(policy['spec']['podSelector']['matchLabels']['app.kubernetes.io/component'],'session-brief')
        self.assertEqual(policy['spec']['egress'][0]['ports'],[{'protocol':'TCP','port':443}])
        for d in docs:
            if d['kind'] not in ('Deployment','Job'):continue
            p=d['spec']['template']['spec']
            if p is pod:continue
            self.assertNotIn('brief-model-key',json.dumps(p));self.assertNotIn('SESSION_BRIEF_CANONICAL_INPUT',json.dumps(p))

    def test_refuses_unbounded_selection_layout_key_and_image(self):
        for field,value,message in [('workspaceIds',[],'workspaceIds'),('workspaceIds',['*'],'workspaceIds'),('workspaceIds',['same','same'],'workspaceIds'),('keyPrefix','96bulls/org','bare writer root'),('model','bad model','model'),('sweepSeconds',0,'sweepSeconds'),('batch',0,'batch'),('batch',101,'batch'),('globalDailyCap',0,'globalDailyCap'),('globalDailyCap',1.5,'globalDailyCap'),('sessionDailyCap',10001,'sessionDailyCap'),('enabled','false','boolean')]:
            s=self.selected();s['nativeBrief'][field]=value;self.render(s,message)
        s=self.selected();s['nativeBrief']['image']['digest']='';self.render(s,'immutable')
        s=self.selected();s['nativeBrief']['openaiSecret']={'name':''};self.render(s,'openaiSecret')
        s=self.selected();s['components']['session-brief']['enabled']=False;self.render(s,'components.session-brief')

    def test_active_siblings_and_migrator_require_matching_generation_image(self):
        s=self.selected();s['components']['referee']={'enabled':True};self.render(s,'same qualified image')
        s=self.selected();s['migrations']['enabled']=True;self.render(s,'migration Job image')
        s['image']=deepcopy(s['nativeBrief']['image']);s['components']['referee']={'enabled':True}
        docs=self.render(s);brief=self.brief(docs)
        referee=next(d for d in docs if d['kind']=='Deployment' and d['spec']['template']['metadata']['labels']['app.kubernetes.io/component']=='session-status-worker')['spec']['template']['spec']
        self.assertEqual(brief['containers'][0]['image'],referee['containers'][0]['image'])
        self.assertNotIn('brief-model-key',json.dumps(referee))

    def test_refuses_ca_conflicts_and_env_overrides(self):
        for change,message in [({'enabled':False},'postgresCa'),({'sha256':'bad'},'sha256'),({'configMap':'','secret':'private-key'},'ConfigMap')]:
            s=self.selected();s['postgresCa'].update(change);self.render(s,message)
        for name in ['HOOPDB_URL','OPENAI_API_KEY','OPENAI_BASE_URL','SESSION_BRIEF_WORKSPACE_IDS','PIPELINE_KEY_PREFIX','NODE_TLS_REJECT_UNAUTHORIZED','NODE_EXTRA_CA_CERTS','SESSION_BRIEF_BATCH','SESSION_BRIEF_GLOBAL_DAILY_CAP','SESSION_BRIEF_SESSION_DAILY_CAP']:
            s=self.selected();s['components']['session-brief']['env']=[{'name':name,'value':'override'}];self.render(s,'manages' if name!='NODE_EXTRA_CA_CERTS' else 'manages')
        s=self.selected();s['extraEnv']=[{'name':'SESSION_BRIEF_ENABLED','value':'true'}];self.render(s,'manages')
        s=self.selected();s['podLabels']={'app.kubernetes.io/component':'unselected'};self.render(s,'selector labels')

    def test_openai_policy_refuses_disabled_or_empty_wildcard_rules(self):
        for peers in [[],[{}],[{'namespaceSelector':{}}],[{'namespaceSelector':{'matchLabels':{}}}],[{'ports':[443]}]]:
            s=self.selected();s['nativeBrief']['openaiEgress']['to']=peers;self.render(s,'openaiEgress')
        s=self.selected();s['networkPolicy']['enabled']=False;self.render(s,'networkPolicy.enabled')
        s=self.selected();s['nativeBrief']['openaiEgress']['enabled']=False;self.render(s,'openaiEgress')

    def test_actual_preflight_accepts_pinned_public_ca_and_refuses_url_hash_and_private_key(self):
        script=self.brief(self.render(self.selected()))['initContainers'][0]['args'][0]
        # Public certificates from the installed Node trust set: no private key is created.
        cert=subprocess.check_output(['node','-e',"const t=require('node:tls'),c=require('node:crypto');console.log(t.rootCertificates.find(p=>{const x=new c.X509Certificate(p);return x.ca&&Date.parse(x.validFrom)<Date.now()&&Date.parse(x.validTo)>Date.now()}))"],text=True)
        with tempfile.TemporaryDirectory()as t:
            f=Path(t)/'verified-ca.crt';source=Path(t)/'source-ca.crt';source.write_text(cert)
            env={**os.environ,'NATIVE_BRIEF_CA_FILE':str(f),'NATIVE_BRIEF_CA_SOURCE':str(source),'NATIVE_BRIEF_CA_SHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'HOOPDB_URL':f'postgresql://reader@postgres/hoopdb?sslmode=verify-full&sslrootcert={f}'}
            def execute(e,clear=True):
                if clear:f.unlink(missing_ok=True)
                return subprocess.run(['node','-e',script],env=e,capture_output=True,text=True)
            self.assertEqual(execute(env).returncode,0);self.assertEqual(f.read_bytes(),source.read_bytes());self.assertEqual(f.stat().st_mode&0o777,0o440)
            self.assertEqual(execute(env,clear=False).returncode,0) # ordinary same-Pod init retry
            f.unlink();f.write_text('divergent');self.assertNotEqual(execute(env,clear=False).returncode,0);self.assertEqual(f.read_text(),'divergent')
            f.unlink();f.symlink_to(source);self.assertNotEqual(execute(env,clear=False).returncode,0);self.assertTrue(f.is_symlink());f.unlink()
            self.assertEqual(execute(env).returncode,0)
            original=f.read_bytes();source.write_text('not a certificate');self.assertEqual(f.read_bytes(),original);source.write_text(cert)
            for delta in [{'NATIVE_BRIEF_CA_SHA256':'0'*64},{'HOOPDB_URL':env['HOOPDB_URL'].replace('verify-full','require')},{'HOOPDB_URL':env['HOOPDB_URL']+'&sslmode=disable'},{'HOOPDB_URL':env['HOOPDB_URL']+'&uselibpqcompat=true'},{'HOOPDB_URL':env['HOOPDB_URL'].replace(str(f),'/other/ca.crt')}]:
                r=execute({**env,**delta});self.assertNotEqual(r.returncode,0);self.assertNotIn(env['HOOPDB_URL'],r.stderr);self.assertFalse(f.exists())
            raw=bytearray(cert.encode('ascii'));offset=raw.index(b'\n')+1;raw[offset]|=128;source.write_bytes(raw)
            self.assertNotEqual(execute({**env,'NATIVE_BRIEF_CA_SHA256':hashlib.sha256(source.read_bytes()).hexdigest()}).returncode,0)
            source.write_text(cert+'-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----\n')
            r=execute({**env,'NATIVE_BRIEF_CA_SHA256':hashlib.sha256(source.read_bytes()).hexdigest()});self.assertNotEqual(r.returncode,0)

if __name__=='__main__':unittest.main()
