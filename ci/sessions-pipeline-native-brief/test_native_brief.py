"""Typed native model worker admission and component-only network/secret/CA contract."""
from copy import deepcopy
import hashlib
import json
import os
import shutil
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

    def analytics_selected(self):
        values = self.selected()
        values['nativeBrief']['analytics'] = {
            'enabled': True, 'deploymentId': 'test-install',
            'collectorUrl': 'https://collector.agent-relay.svc:8443/v1/events',
            'existingSecret': 'brief-producer', 'caConfigMap': 'collector-ca',
            'egress': {'to': [{'podSelector': {'matchLabels': {'app': 'telemetry-collector'}}}]},
        }
        return values

    def test_brief_analytics_is_off_by_default_and_scoped_when_enabled(self):
        self.assertNotIn('ANALYTICS_', json.dumps(self.render(self.selected())))
        values = self.analytics_selected()
        values['image'] = deepcopy(values['nativeBrief']['image'])
        values['components']['referee']['enabled'] = True
        docs = self.render(values)
        pod = self.brief(docs)
        main = pod['containers'][0]
        env = {entry['name']: entry for entry in main['env']}
        self.assertEqual(len(env), len(main['env']))
        self.assertEqual(env['ANALYTICS_SINK']['value'], 'collector')
        self.assertEqual(env['ANALYTICS_COLLECTOR_TOKEN']['valueFrom']['secretKeyRef'], {
            'name': 'brief-producer', 'key': 'token',
        })
        self.assertEqual(env['NODE_EXTRA_CA_CERTS']['value'], '/etc/postgres-ca/ca.crt')
        self.assertEqual(env['ANALYTICS_COLLECTOR_CA_FILE']['value'], '/etc/brief-analytics-ca/ca.crt')
        self.assertIn({'name': 'brief-analytics-ca', 'mountPath': '/etc/brief-analytics-ca', 'readOnly': True},
                      main['volumeMounts'])
        self.assertEqual(next(v for v in pod['volumes'] if v['name'] == 'brief-analytics-ca')['configMap']['name'],
                         'collector-ca')
        for resource in docs:
            if resource['kind'] not in ('Deployment', 'Job'):
                continue
            template = resource['spec']['template']
            if template['spec'] is pod:
                self.assertEqual(template['metadata']['labels']['agentworkforce.dev/analytics-producer'], 'true')
                self.assertNotIn('ANALYTICS_', json.dumps(pod['initContainers']))
            else:
                self.assertNotIn('agentworkforce.dev/analytics-producer', template['metadata']['labels'])
                self.assertNotIn('brief-producer', json.dumps(template))
        policy = next(d for d in docs if d['metadata']['name'].endswith('-brief-analytics'))
        self.assertEqual(policy['spec']['podSelector']['matchLabels']['app.kubernetes.io/component'], 'session-brief')
        self.assertEqual(policy['spec']['egress'], [{
            'to': values['nativeBrief']['analytics']['egress']['to'],
            'ports': [{'protocol': 'TCP', 'port': 8443}],
        }])

    def test_brief_analytics_refuses_unmanaged_and_unbounded_configuration(self):
        for overrides, reason in [
            ({'existingSecret': ''}, 'existingSecret is required'),
            ({'enabled': 'true'}, 'enabled must be a boolean'),
            ({'collectorUrl': 'https://collector:8443/v1/events?token=hidden'}, 'HTTPS collector URL'),
            ({'egress': {'to': []}}, 'must list collector peers'),
            ({'egress': {'to': [{'podSelector': {}}]}}, 'match explicit labels'),
            ({'egress': {'port': 65536}}, 'port must be an integer'),
        ]:
            with self.subTest(overrides=overrides):
                values = self.analytics_selected()
                if 'egress' in overrides:
                    overrides = {**overrides, 'egress': {
                        **values['nativeBrief']['analytics']['egress'], **overrides['egress'],
                    }}
                values['nativeBrief']['analytics'].update(overrides)
                self.render(values, reason)
        values = self.analytics_selected()
        values['extraEnv'] = [{'name': 'ANALYTICS_SINK', 'value': 'posthog'}]
        self.render(values, 'managed brief analytics')

    def test_default_has_no_brief_resources_or_model_secret(self):
        docs=self.render({});s=json.dumps(docs)
        self.assertNotIn('SESSION_BRIEF_CANONICAL_INPUT',s);self.assertNotIn('OPENAI_API_KEY',s)
        self.assertFalse(any(d['metadata']['name'].endswith('-brief-openai') for d in docs))
        self.render({'extraEnv':[{'name':'SESSION_BRIEF_CANONICAL_INPUT','value':'true'}]},'use nativeBrief.enabled')
        self.render({'components':{'session-brief':{'enabled':True}}},'requires nativeBrief.enabled')
        self.assertFalse(any(d.get('spec',{}).get('template',{}).get('metadata',{}).get('labels',{}).get('app.kubernetes.io/component')=='session-brief' for d in docs))

    def test_null_optional_environment_preserves_disabled_and_native_rendering(self):
        self.render({'extraEnv':None,'components':{'session-brief':{'env':None}}})
        selected=self.selected();selected['extraEnv']=None;selected['components']['session-brief']['env']=None
        self.assertEqual(self.brief(self.render(selected))['containers'][0]['env'][0]['name'],'SERVICE')

    def test_siblings_cannot_select_the_native_worker_but_indexer_wakeups_remain_supported(self):
        for entry in [{'name':'SERVICE','value':'session-brief'}, {'name':'SERVICE','valueFrom':{'secretKeyRef':{'name':'selection','key':'service'}}}, {'name':'SESSION_BRIEF_CANONICAL_INPUT','value':'true'}]:
            self.render({'components':{'referee':{'enabled':True,'env':[entry]}}},'managed' if entry['name']=='SERVICE' else 'nativeBrief.enabled')
        self.render({'components':{'hoopdb-indexer':{'enabled':True,'env':[{'name':'SESSION_BRIEF_ENABLED','value':'true'}]}}})

    def test_native_component_name_override_reaches_the_deployment(self):
        selected=self.selected();selected['components']['session-brief']['fullnameOverride']='explicit-native-brief'
        docs=self.render(selected)
        deployment=next(d for d in docs if d['kind']=='Deployment' and d['spec']['template']['metadata']['labels']['app.kubernetes.io/component']=='session-brief')
        self.assertEqual(deployment['metadata']['name'],'explicit-native-brief')

    def test_each_worker_start_rechecks_rotated_url_before_the_entrypoint(self):
        pod=self.brief(self.render(self.selected()));main=pod['containers'][0]
        self.assertEqual(main['command'],['/bin/sh','-ec']);self.assertEqual(main['args'][2],'/entrypoint.sh')
        cert=subprocess.check_output(['node','-e',"const t=require('node:tls'),c=require('node:crypto');console.log(t.rootCertificates.find(p=>{const x=new c.X509Certificate(p);return x.ca&&Date.parse(x.validFrom)<Date.now()&&Date.parse(x.validTo)>Date.now()}))"],text=True)
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);source=root/'source.crt';verified=root/'verified.crt';source.write_text(cert)
            marker=root/'entrypoint-ran';entry=root/'entry point.sh';entry.write_text('#!/bin/sh\nprintf started > "$TEST_ENTRYPOINT_MARKER"\n');entry.chmod(0o700)
            # The rendered JS uses Node-compatible APIs; production Bun is qualified separately.
            binaries=root/'bin';binaries.mkdir();(binaries/'bun').symlink_to(shutil.which('node'))
            env={**os.environ,'PATH':str(binaries)+os.pathsep+os.environ['PATH'],'NATIVE_BRIEF_CA_SOURCE':str(source),'NATIVE_BRIEF_CA_FILE':str(verified),'NATIVE_BRIEF_CA_SHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'HOOPDB_URL':f'postgresql://test-only@postgres/hoopdb?sslmode=verify-full&sslrootcert={verified}','TEST_ENTRYPOINT_MARKER':str(marker)}
            admitted=subprocess.run(['node','-e',pod['initContainers'][0]['args'][0]],env=env,capture_output=True,text=True)
            self.assertEqual(admitted.returncode,0,admitted.stderr)
            env['NATIVE_BRIEF_CA_SOURCE']=str(verified)
            def start(url):
                marker.unlink(missing_ok=True)
                return subprocess.run(main['command']+[main['args'][0],main['args'][1],str(entry)],env={**env,'HOOPDB_URL':url},capture_output=True,text=True)
            self.assertEqual(start(env['HOOPDB_URL']).returncode,0);self.assertTrue(marker.exists())
            for changed in [env['HOOPDB_URL'].replace('verify-full','require'),env['HOOPDB_URL'].replace(str(verified),'/other/ca.crt')]:
                result=start(changed);self.assertNotEqual(result.returncode,0);self.assertFalse(marker.exists());self.assertNotIn(changed,result.stderr)
            self.assertEqual(start(env['HOOPDB_URL'].replace('test-only@','rotated-test-only@')).returncode,0);self.assertTrue(marker.exists())

    def test_native_env_secret_ca_health_and_egress_are_component_scoped(self):
        docs=self.render(self.selected());pod=self.brief(docs);main=pod['containers'][0]
        env={e['name']:e for e in main['env']};self.assertEqual(len(env),len(main['env']))
        self.assertNotIn('READER_MAX_RULESET',env)
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

    def test_reader_ruleset_ceiling_is_exact_managed_and_reader_scoped(self):
        for ceiling in [8,9,10]:
            with self.subTest(ceiling=ceiling):
                selected=self.selected();selected['nativeBrief']['readerMaxRuleset']=ceiling
                env={e['name']:e for e in self.brief(self.render(selected))['containers'][0]['env']}
                self.assertEqual(env['READER_MAX_RULESET']['value'],str(ceiling))
        for ceiling in [7,11,'09',' 8',8.5,True]:
            with self.subTest(ceiling=ceiling):
                selected=self.selected();selected['nativeBrief']['readerMaxRuleset']=ceiling
                self.render(selected,'readerMaxRuleset')
        selected=self.selected();selected['nativeBrief']['readerMaxRuleset']=None
        self.assertEqual(self.render(selected),self.render(self.selected()))
        for target in ['extraEnv','component']:
            selected=self.selected();entry={'name':'READER_MAX_RULESET','value':'10'}
            if target=='extraEnv':selected['extraEnv']=[entry]
            else:selected['components']['session-brief']['env']=[entry]
            self.render(selected,'use global.scrubEngine')

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

    def env_of(self,pod):
        env=pod['containers'][0]['env'];names=[e['name'] for e in env]
        self.assertEqual(len(names),len(set(names)),'a duplicate env name breaks server-side apply')
        return {e['name']:e.get('value') for e in env}

    def test_base_url_defaults_leave_the_worker_on_the_hosted_endpoint(self):
        env=self.env_of(self.brief(self.render(self.selected())))
        self.assertNotIn('OPENAI_BASE_URL',env);self.assertEqual(env['ALLOW_IN_CLUSTER_HTTP'],'false')

    def test_base_url_and_in_cluster_http_render_on_session_brief_only(self):
        s=self.selected();s['nativeBrief'].update(baseUrl='http://llm-gateway.ai.svc:4000/v1',allowInClusterHttp=True)
        s['image']=deepcopy(s['nativeBrief']['image']);s['components']['referee']={'enabled':True}
        docs=self.render(s);pod=self.brief(docs);env=self.env_of(pod)
        self.assertEqual(env['OPENAI_BASE_URL'],'http://llm-gateway.ai.svc:4000/v1');self.assertEqual(env['ALLOW_IN_CLUSTER_HTTP'],'true')
        self.assertNotIn('OPENAI_BASE_URL',json.dumps(pod['initContainers']))
        checked=0
        for d in docs:
            if d['kind'] not in ('Deployment','Job') or d['spec']['template']['metadata']['labels'].get('app.kubernetes.io/component')=='session-brief':continue
            sibling=self.env_of(d['spec']['template']['spec']);checked+=1
            self.assertNotIn('OPENAI_BASE_URL',sibling);self.assertEqual(sibling['ALLOW_IN_CLUSTER_HTTP'],'false')
        self.assertGreater(checked,0)

    def test_top_level_in_cluster_http_keeps_applying_to_session_brief(self):
        s=self.selected();s['allowInClusterHttp']=True;s['nativeBrief']['baseUrl']='http://llm-gateway.ai.svc.cluster.local/v1'
        env=self.env_of(self.brief(self.render(s)))
        self.assertEqual(env['ALLOW_IN_CLUSTER_HTTP'],'true');self.assertEqual(env['OPENAI_BASE_URL'],'http://llm-gateway.ai.svc.cluster.local/v1')

    def test_https_base_url_needs_no_in_cluster_flag(self):
        for url in ['https://llm.example.com/v1','https://llm.example.com:8443/openai/v1/','https://gateway.ai.svc:8443/v1']:
            s=self.selected();s['nativeBrief']['baseUrl']=url
            env=self.env_of(self.brief(self.render(s)));self.assertEqual(env['OPENAI_BASE_URL'],url);self.assertEqual(env['ALLOW_IN_CLUSTER_HTTP'],'false')

    def test_refuses_base_urls_the_worker_would_refuse(self):
        for url,allow,message in [
            ('http://llm-gateway.ai.svc:4000/v1',False,'allowInClusterHttp'),
            ('http://llm.example.com/v1',True,'svc'),
            ('http://llm-gateway/v1',True,'svc'),
            ('http://llm-gateway.ai/v1',True,'svc'),
            ('http://a.b.c.svc/v1',True,'svc'),
            ('http://llm-gateway.ai.svc.evil.example/v1',True,'svc'),
            ('http://10.0.0.1:4000/v1',True,'svc'),
            ('http://localhost:4000/v1',True,'svc'),
            ('http://llm-gateway.ai.svc:99999/v1',True,'svc'),
            ('http://u:p@llm-gateway.ai.svc:4000/v1',True,'svc'),
            ('http://llm-gateway.ai.svc:4000/v1?x=1',True,'svc'),
            ('https://u:p@llm.example.com/v1',False,'credentials'),
            ('https://llm.example.com/v1?x=1',False,'credentials'),
            ('https://llm.example.com/v1#frag',False,'credentials'),
            ('https://llm.example.com:0/v1',False,'credentials'),
            ('https://llm.example.com/v1 ',False,'credentials'),
            ('ftp://llm.example.com/v1',False,'absolute'),
            ('llm.example.com/v1',False,'absolute'),
            ('HTTPS://llm.example.com/v1',False,'absolute'),
            (42,False,'must be a string')]:
            s=self.selected();s['nativeBrief'].update(baseUrl=url,allowInClusterHttp=allow);self.render(s,message)
        s=self.selected();s['nativeBrief']['allowInClusterHttp']='true';self.render(s,'must be a boolean')

    def test_base_url_settings_require_the_native_worker(self):
        self.render({'nativeBrief':{'baseUrl':'https://llm.example.com/v1'}},'requires nativeBrief.enabled')
        self.render({'nativeBrief':{'allowInClusterHttp':True}},'requires nativeBrief.enabled')

    def test_in_cluster_http_flag_cannot_be_set_through_env(self):
        s=self.selected();s['components']['session-brief']['env']=[{'name':'ALLOW_IN_CLUSTER_HTTP','value':'true'}];self.render(s,'must not set ALLOW_IN_CLUSTER_HTTP')
        s=self.selected();s['extraEnv']=[{'name':'ALLOW_IN_CLUSTER_HTTP','value':'true'}];self.render(s,'must not set ALLOW_IN_CLUSTER_HTTP')

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
