import io
import inspect
import json
import os
import signal
import time
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from contract import ADDRESSES, CONTEXT_KEYS, DOMAIN, POLICY, MARKER, canonical, caller, digest, domain_name, expected_tags, identities
from files import save, sha
import runner as r
from test_contract import create_plan, destroy_plan, inherited, inputs, packet

class RunnerGuards(unittest.TestCase):
    def setUp(self):
        scratch=r.MODULE/'.terraform';scratch.mkdir(exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=scratch);self.root=Path(self.temp.name)
        self.v=inputs();self.variables=self.root/'inputs.json';save(self.variables,self.v)
        self.config=self.root/'aws-config';self.config.write_text('[profile pippen-sandbox]\nregion = us-west-2\ncredential_process = /usr/bin/env "synthetic-never-executed"\n')
        self.env={'AWS_PROFILE':'pippen-sandbox','AWS_CONFIG_FILE':str(self.config),'AWS_SHARED_CREDENTIALS_FILE':'/dev/null','AWS_EC2_METADATA_DISABLED':'true'}
        self.calls=[]
        def transport(args,**kwargs):
            self.calls.append(args)
            if 'get-caller-identity' in args:
                return SimpleNamespace(returncode=0,stdout=json.dumps({'Account':self.v['account_id'],'Arn':identities(self.v)['control']}))
            raise AssertionError('Unexpected synthetic boundary: '+str(args))
        self.subject=r.Runner(self.root/'execution',self.variables,'/usr/bin/true',env=self.env,transport=transport)
    def tearDown(self):self.temp.cleanup()

    def test_context_survives_for_refresh_and_fresh_sts_is_used(self):
        original=packet();raw=json.dumps(inherited(self.v,original));self.subject.env['PIPPEN_SANDBOX_CAPABILITY_CONTEXT']=raw
        _,who=self.subject.authority(original, initial=True)
        self.assertEqual(who['Arn'],identities(self.v)['control'])
        self.assertEqual(self.subject.env['PIPPEN_SANDBOX_CAPABILITY_CONTEXT'],raw)
        self.assertEqual(len(self.calls),1);self.assertIn('get-caller-identity',self.calls[0])
        self.assertFalse(any('credentials-process' in args for args in self.calls))

    def test_context_tamper_blocks_before_any_cli_call(self):
        self.subject.env['PIPPEN_SANDBOX_CAPABILITY_CONTEXT']=json.dumps({**inherited(self.v,packet()),'inputs_sha256':'f'*64})
        with self.assertRaises(RuntimeError):self.subject.authority(packet())
        self.assertEqual(self.calls,[])

    def seal(self, original=None):
        original=original or packet();cap=inherited(self.v,original)
        save(self.subject.path('original-capability-context.json'),cap)
        fingerprint=sha(self.subject.path('original-capability-context.json'))
        save(self.subject.path('phase.json'),{'status':'captured','context_sha256':fingerprint})
        return cap,fingerprint

    def test_every_context_field_is_frozen_before_fresh_selected_io(self):
        original=packet();cap,_=self.seal(original)
        for key in CONTEXT_KEYS:
            changed={**cap,key:cap[key]+'different'}
            if key=='approval_id':changed[key]='22222222-2222-4222-8222-222222222222'
            if key=='approval_fingerprint':changed[key]='b'*64
            if key=='profile_expires_at':changed[key]='2099-02-01T00:00:00.000Z'
            self.subject.env['PIPPEN_SANDBOX_CAPABILITY_CONTEXT']=json.dumps(changed)
            with self.subTest(key=key),self.assertRaises((RuntimeError,ValueError)):
                self.subject.authority(original)
        self.assertEqual(self.calls,[])
        self.subject.env['PIPPEN_SANDBOX_CAPABILITY_CONTEXT']=json.dumps(cap)
        self.subject.authority(original)
        self.assertEqual(len(self.calls),1)

    def test_selected_phases_require_seal_and_captured_hash(self):
        original=packet();self.subject.env['PIPPEN_SANDBOX_CAPABILITY_CONTEXT']=json.dumps(inherited(self.v,original))
        with self.assertRaisesRegex(RuntimeError,'Missing original'):self.subject.authority(original)
        cap,fingerprint=self.seal(original)
        for name in ['phase.json','created.json','destroy.packet.json']:
            save(self.subject.path(name),{'context_sha256':'f'*64})
            with self.subTest(name=name),self.assertRaisesRegex(RuntimeError,'seal differs'):self.subject.authority(original)
            save(self.subject.path(name),{'context_sha256':fingerprint})
        cap['approval_id']='22222222-2222-4222-8222-222222222222'
        save(self.subject.path('original-capability-context.json'),cap)
        with self.assertRaisesRegex(RuntimeError,'seal differs'):self.subject.authority(original)
        self.assertEqual(self.calls,[])

    def test_expired_seal_is_readable_provenance_but_not_selected_authority(self):
        original=packet();cap,fingerprint=self.seal(original)
        cap['profile_expires_at']='2000-01-01T00:00:00.000Z'
        save(self.subject.path('original-capability-context.json'),cap)
        fingerprint=sha(self.subject.path('original-capability-context.json'))
        save(self.subject.path('phase.json'),{'context_sha256':fingerprint})
        self.assertEqual(self.subject.sealed_context(original),(cap,fingerprint))
        self.subject.env['PIPPEN_SANDBOX_CAPABILITY_CONTEXT']=json.dumps(cap)
        with self.assertRaisesRegex(RuntimeError,'expired'):self.subject.authority(original)
        self.assertEqual(self.calls,[])

    def staged_create(self, fail=False):
        plan=create_plan(self.v);saved=self.subject.path('create.tfplan');saved.write_text('synthetic plan')
        original={**packet(),'plan_sha256':sha(saved),'plan_json_sha256':digest(canonical(plan)), 'search_mode_history':'fresh'}
        save(self.subject.path('create.packet.json'),original)
        save(self.subject.path('network-before.json'),{'observed_at':__import__('time').time(),'inputs_sha256':sha(self.variables)})
        cap=inherited(self.v,original);self.subject.env['PIPPEN_SANDBOX_CAPABILITY_CONTEXT']=json.dumps(cap)
        self.subject.immutable=Mock(return_value={'backend_state_sha256':original['backend_state_sha256']})
        self.subject.native_domain=Mock(return_value={'DomainId':'synthetic-domain-id'})
        self.subject.aws=Mock(return_value=SimpleNamespace(returncode=1,stderr='An error occurred (ResourceNotFoundException) when calling the DescribeDomain operation'))
        self.subject.identity=Mock(return_value={'Account':self.v['account_id'],'Arn':identities(self.v)['control']})
        def run(args,**kwargs):
            if 'show' in args:return SimpleNamespace(stdout=json.dumps(plan))
            if 'apply' in args:
                self.assertEqual(json.loads(self.subject.path('original-capability-context.json').read_text()),cap)
                phase=json.loads(self.subject.path('phase.json').read_text())
                self.assertEqual(phase['status'],'pending')
                self.assertEqual(phase['context_sha256'],sha(self.subject.path('original-capability-context.json')))
                if fail:raise RuntimeError('synthetic partial apply')
                return SimpleNamespace(stdout='')
            if 'output' in args:return SimpleNamespace(stdout=json.dumps({'domain_name':domain_name(self.v['pippen']['session_id']),'domain_arn':'arn:aws:es:us-west-2:111111111111:domain/'+domain_name(self.v['pippen']['session_id'])}))
            raise AssertionError(args)
        self.subject.run=run
        return original,cap

    def test_history_gate_rejects_before_creation_packet(self):
        plan=create_plan(self.v)
        next(r for r in plan['resource_changes'] if r['address']==MARKER)['change']['after']['input']=False
        self.subject.bindings=Mock(return_value={})
        self.subject.identity=Mock()
        def run(args,**kwargs):
            if 'plan' in args:self.subject.path('create.tfplan').write_text('synthetic plan')
            return SimpleNamespace(stdout=json.dumps(plan) if 'show' in args else '')
        self.subject.run=run
        with self.assertRaisesRegex(RuntimeError,'mode mismatch'):self.subject.prepare()
        self.assertFalse(self.subject.path('create.packet.json').exists())
        self.assertFalse(self.subject.path('phase.json').exists())

    def test_history_gate_rejects_even_exact_hash_review_before_apply(self):
        original,_=self.staged_create()
        plan=create_plan(self.v)
        next(r for r in plan['resource_changes'] if r['address']==MARKER)['change']['after']['input']=False
        original['plan_json_sha256']=digest(canonical(plan))
        save(self.subject.path('create.packet.json'),original)
        self.subject.run=lambda args,**kwargs:SimpleNamespace(stdout=json.dumps(plan)) if 'show' in args else self.fail('No mutation before history admission')
        with self.assertRaisesRegex(RuntimeError,'mode mismatch'):self.subject.apply(original['plan_sha256'],sha(self.subject.path('create.packet.json')))
        self.subject.aws.assert_not_called()
        self.assertFalse(self.subject.path('phase.json').exists())

    def test_original_context_is_durable_before_apply_and_survives_capture(self):
        original,cap=self.staged_create()
        self.subject.apply(original['plan_sha256'],sha(self.subject.path('create.packet.json')))
        fingerprint=sha(self.subject.path('original-capability-context.json'))
        for name in ['candidate-contract.json','created.json','phase.json']:
            self.assertEqual(json.loads(self.subject.path(name).read_text())['context_sha256'],fingerprint)
        self.assertEqual(json.loads(self.subject.path('original-capability-context.json').read_text()),cap)
        self.assertEqual(self.subject.sealed_context(original),(cap,fingerprint))

    def test_destroy_and_native_absence_keep_original_context_seal(self):
        original,cap=self.staged_create()
        self.subject.apply(original['plan_sha256'],sha(self.subject.path('create.packet.json')))
        fingerprint=sha(self.subject.path('original-capability-context.json'))
        save(self.subject.path('network-created.json'),{'context_sha256':fingerprint})
        ledger=json.loads(self.subject.path('created.json').read_text())
        plan=destroy_plan(self.v,ledger)
        saved=self.subject.path('destroy.tfplan');saved.write_text('synthetic delete plan')
        destruction={**original,'plan_sha256':sha(saved),'plan_json_sha256':digest(canonical(plan)),'context_sha256':fingerprint,'original_packet_sha256':sha(self.subject.path('create.packet.json')),'created_sha256':sha(self.subject.path('created.json')),'network_created_sha256':sha(self.subject.path('network-created.json')), 'search_mode_history':'destroy'}
        save(self.subject.path('destroy.packet.json'),destruction)
        def run(args,**kwargs):
            if 'show' in args:return SimpleNamespace(stdout=json.dumps(plan))
            self.assertIn('apply',args)
            phase=json.loads(self.subject.path('phase.json').read_text())
            self.assertEqual((phase['operation'],phase['status'],phase['context_sha256']),('destroy','pending',fingerprint))
            return SimpleNamespace(stdout='')
        self.subject.run=run
        self.subject.apply(destruction['plan_sha256'],sha(self.subject.path('destroy.packet.json')),destroy=True)
        self.assertEqual(json.loads(self.subject.path('phase.json').read_text())['context_sha256'],fingerprint)
        self.subject.domain_absence()
        self.assertEqual(json.loads(self.subject.path('domain-absence.json').read_text())['context_sha256'],fingerprint)
        self.assertEqual(json.loads(self.subject.path('original-capability-context.json').read_text()),cap)

    def test_partial_apply_retains_original_context_and_pending_record(self):
        original,cap=self.staged_create(fail=True)
        with self.assertRaisesRegex(RuntimeError,'synthetic partial'):self.subject.apply(original['plan_sha256'],sha(self.subject.path('create.packet.json')))
        self.assertEqual(json.loads(self.subject.path('original-capability-context.json').read_text()),cap)
        self.assertEqual(json.loads(self.subject.path('phase.json').read_text())['status'],'pending')
        self.assertFalse(self.subject.path('created.json').exists())

    def test_pending_creation_is_never_blindly_retried(self):
        save(self.subject.path('phase.json'),{'status':'pending'})
        with self.assertRaisesRegex(RuntimeError,'cannot be retried'):self.subject.apply('a'*64,'b'*64)
        self.assertEqual(self.calls,[])

    def test_static_credentials_or_backend_override_are_refused(self):
        for delta in [{'AWS_ACCESS_KEY_ID':'synthetic'},{'TF_DATA_DIR':'synthetic-other-backend'},{'TF_WORKSPACE':'other'}]:
            with self.subTest(delta=delta),self.assertRaises(RuntimeError):r.Runner(self.root/'other',self.variables,'/usr/bin/true',env={**self.env,**delta},transport=Mock())

    def test_unrelated_existing_execution_directory_is_untouched(self):
        other=self.root/'unrelated';other.mkdir(mode=0o700);evidence=other/'preserve.json';evidence.write_text('synthetic old evidence')
        with self.assertRaisesRegex(RuntimeError,'unrelated execution'):r.Runner(other,self.variables,'/usr/bin/true',env=self.env,transport=Mock())
        self.assertEqual({p.name for p in other.iterdir()},{'preserve.json'})
        self.assertEqual(evidence.read_text(),'synthetic old evidence')

    def test_selector_changed_before_credential_use_is_refused(self):
        self.subject.transport=None;self.config.write_text('changed selector')
        with self.assertRaisesRegex(RuntimeError,'selector changed'):self.subject.run(['synthetic'])

    def test_normal_child_environment_keeps_context_without_launching_process(self):
        original=packet();raw=json.dumps(inherited(self.v,original));self.subject.env['PIPPEN_SANDBOX_CAPABILITY_CONTEXT']=raw
        self.subject.transport=None
        fake=SimpleNamespace(pid=123456789,returncode=0,wait=lambda **k:None,poll=lambda:0)
        with patch.object(r.subprocess,'Popen',return_value=fake) as launch,patch.object(r.os,'killpg',side_effect=ProcessLookupError):
            self.subject.run(['synthetic'])
        self.assertEqual(launch.call_args.kwargs['env']['PIPPEN_SANDBOX_CAPABILITY_CONTEXT'],raw)
        self.assertTrue(launch.call_args.kwargs['start_new_session'])

    def test_interrupted_group_cannot_proceed_to_apply(self):
        self.subject.settled=False
        with self.assertRaisesRegex(RuntimeError,'Unsettled'):self.subject.apply('a'*64,'b'*64)
        self.assertEqual(self.calls,[])

    def test_inert_timeout_preserves_partial_logs_and_reaps_group(self):
        self.subject.transport=None
        code='import subprocess,sys,time;subprocess.Popen([sys.executable,"-c","import time;time.sleep(60)"]);print("synthetic partial",flush=True);time.sleep(60)'
        with self.assertRaises(subprocess.TimeoutExpired):self.subject.run([sys.executable,'-c',code],timeout=.3)
        records=list(self.subject.path('commands').glob('*.json'));self.assertEqual(len(records),1)
        record=json.loads(records[0].read_text());self.assertEqual(record['outcome'],'interrupted');self.assertTrue(record['process_group_absent'])
        self.assertIn('synthetic partial',records[0].with_suffix('.stdout').read_text())
        with self.assertRaises(ProcessLookupError):r.os.killpg(record['pgid'],0)

    def test_first_signal_at_exception_entry_cannot_skip_settlement_or_evidence(self):
        self.subject.transport=None
        lines,start=inspect.getsourcelines(r.Runner.run)
        boundary=start+next(i for i,line in enumerate(lines) if "metadata.update(outcome='interrupted'" in line)
        injected=False
        def trace(frame,event,arg):
            nonlocal injected
            if event=='line' and frame.f_code is r.Runner.run.__code__ and frame.f_lineno==boundary and not injected:
                injected=True;signal.raise_signal(signal.SIGTERM)
                # CPython3.9 writes the trace-local snapshot back on return.
                # Refresh it from the actual handler-updated cells, without
                # assigning an invented signal or changing this boundary.
                frame.f_locals
            return trace
        fake=SimpleNamespace(pid=123456789,returncode=None,wait=Mock(side_effect=RuntimeError('synthetic wait error')),poll=Mock(return_value=None))
        previous=sys.gettrace()
        try:
            with patch.object(r.subprocess,'Popen',return_value=fake),patch.object(r.os,'killpg',side_effect=ProcessLookupError) as groups:
                sys.settrace(trace)
                with self.assertRaisesRegex(RuntimeError,'synthetic wait error'):self.subject.run(['inert'])
                self.assertGreater(groups.call_count,0)
        finally:sys.settrace(previous)
        self.assertTrue(injected)
        record=json.loads(next(self.subject.path('commands').glob('*.json')).read_text())
        self.assertEqual(record['outcome'],'interrupted');self.assertEqual(record['signal'],signal.SIGTERM)
        self.assertTrue(record['process_group_absent']);self.assertTrue(self.subject.settled)

    def test_bounded_wait_slices_preserve_one_total_timeout(self):
        self.subject.transport=None
        clock=[0.0];waits=[]
        def wait(*,timeout):
            waits.append(timeout);clock[0]+=timeout
            raise subprocess.TimeoutExpired(['inert'],timeout)
        fake=SimpleNamespace(pid=123456789,returncode=None,wait=wait,poll=Mock(return_value=None))
        with patch.object(r.subprocess,'Popen',return_value=fake),patch.object(r.os,'killpg',side_effect=ProcessLookupError),patch.object(r.time,'monotonic',side_effect=lambda:clock[0]):
            with self.assertRaises(subprocess.TimeoutExpired) as raised:self.subject.run(['inert'],timeout=.25)
        self.assertEqual(raised.exception.timeout,.25)
        self.assertEqual(len(waits),3);self.assertTrue(all(0<n<=.1 for n in waits));self.assertAlmostEqual(sum(waits),.25)
        record=json.loads(next(self.subject.path('commands').glob('*.json')).read_text())
        self.assertEqual(record['outcome'],'interrupted');self.assertTrue(record['process_group_absent'])

    def test_recorded_wait_signal_is_checked_before_another_slice(self):
        self.subject.transport=None
        def wait(*,timeout):
            signal.raise_signal(signal.SIGTERM)
            raise subprocess.TimeoutExpired(['inert'],timeout)
        fake=SimpleNamespace(pid=123456789,returncode=None,wait=Mock(side_effect=wait),poll=Mock(return_value=None))
        with patch.object(r.subprocess,'Popen',return_value=fake),patch.object(r.os,'killpg',side_effect=ProcessLookupError):
            with self.assertRaises(r.CommandInterrupted):self.subject.run(['inert'])
        self.assertEqual(fake.wait.call_count,1)
        record=json.loads(next(self.subject.path('commands').glob('*.json')).read_text())
        self.assertEqual(record['signal'],signal.SIGTERM);self.assertTrue(record['process_group_absent'])

    def test_spawn_assignment_signal_is_deferred_until_owned_pid_known(self):
        self.subject.transport=None
        original={sig:signal.getsignal(sig) for sig in [signal.SIGTERM,signal.SIGHUP,signal.SIGINT]}
        fake=SimpleNamespace(pid=123456789,returncode=0,wait=Mock(),poll=Mock(return_value=0))
        def launch(*args,**kwargs):
            signal.raise_signal(signal.SIGTERM)
            return fake
        with patch.object(r.subprocess,'Popen',side_effect=launch),patch.object(r.os,'killpg',side_effect=ProcessLookupError):
            with self.assertRaises(r.CommandInterrupted):self.subject.run(['inert'])
        fake.wait.assert_not_called()
        record=json.loads(next(self.subject.path('commands').glob('*.json')).read_text())
        self.assertEqual(record['pid'],fake.pid);self.assertEqual(record['signal'],signal.SIGTERM)
        self.assertEqual(record['outcome'],'interrupted');self.assertTrue(record['process_group_absent'])
        self.assertEqual({sig:signal.getsignal(sig) for sig in original},original)

    def test_transient_group_permission_denial_is_retried_until_exact_absence(self):
        self.subject.transport=None
        fake=SimpleNamespace(pid=123456789,returncode=0,wait=Mock(),poll=Mock(return_value=0))
        def launch(*args,**kwargs):
            signal.raise_signal(signal.SIGTERM)
            return fake
        responses=[None,PermissionError('synthetic probe denied'),ProcessLookupError()]
        with patch.object(r.subprocess,'Popen',side_effect=launch),patch.object(r.os,'killpg',side_effect=responses) as groups,patch.object(r.time,'sleep'):
            with self.assertRaises(r.CommandInterrupted):self.subject.run(['inert'])
        self.assertEqual(groups.call_count,3)
        record=json.loads(next(self.subject.path('commands').glob('*.json')).read_text())
        self.assertEqual(record['outcome'],'interrupted');self.assertEqual(record['signal'],signal.SIGTERM)
        self.assertTrue(record['process_group_absent']);self.assertTrue(self.subject.settled)

    def test_persistent_group_permission_denial_records_unsettled_and_never_advances(self):
        self.subject.transport=None
        fake=SimpleNamespace(pid=123456789,returncode=0,wait=Mock(),poll=Mock(return_value=0))
        def launch(*args,**kwargs):
            signal.raise_signal(signal.SIGTERM)
            return fake
        ticks=iter(range(0,100,3))
        with patch.object(r.subprocess,'Popen',side_effect=launch),patch.object(r.os,'killpg',side_effect=PermissionError('synthetic denied')),patch.object(r.time,'monotonic',side_effect=lambda:next(ticks)),patch.object(r.time,'sleep'):
            with self.assertRaises(r.CommandInterrupted):self.subject.run(['inert'])
        self.assertGreaterEqual(fake.poll.call_count,2)
        record=json.loads(next(self.subject.path('commands').glob('*.json')).read_text())
        self.assertEqual(record['outcome'],'interrupted');self.assertEqual(record['signal'],signal.SIGTERM)
        self.assertFalse(record['process_group_absent']);self.assertFalse(self.subject.settled)
        with self.assertRaisesRegex(RuntimeError,'Unsettled'):self.subject.apply('a'*64,'b'*64)

    def test_prelaunch_signal_does_not_spawn_and_restores_handlers(self):
        self.subject.transport=None
        original={sig:signal.getsignal(sig) for sig in [signal.SIGTERM,signal.SIGHUP,signal.SIGINT]}
        chmod=r.os.chmod
        def interrupt_before_launch(*args,**kwargs):
            chmod(*args,**kwargs)
            if str(args[0]).endswith('.stdout'):signal.raise_signal(signal.SIGHUP)
        with patch.object(r.os,'chmod',side_effect=interrupt_before_launch),patch.object(r.subprocess,'Popen') as launch:
            with self.assertRaises(r.CommandInterrupted):self.subject.run(['inert'])
        launch.assert_not_called()
        record=json.loads(next(self.subject.path('commands').glob('*.json')).read_text())
        self.assertEqual(record['signal'],signal.SIGHUP);self.assertTrue(record['process_group_absent'])
        self.assertEqual({sig:signal.getsignal(sig) for sig in original},original)

    def test_inert_sigterm_and_repeated_hup_reap_owned_group_without_advancing_pending(self):
        self.subject.execution=self.root/'signal-execution' # Fresh owner, including original-source red replay.
        child_code='''import json,os,signal,subprocess,sys,time
grand=subprocess.Popen([sys.executable,"-c","import time;time.sleep(60)"])
def stop(signum,frame):
 time.sleep(.3)
 grand.wait(timeout=3)
 sys.exit(0)
signal.signal(signal.SIGTERM,stop)
print(json.dumps({"pid":os.getpid(),"grandchild":grand.pid}),flush=True)
while True:time.sleep(1)
'''
        source=str(getattr(self,'runner_source',Path(r.__file__)))
        report=self.root/'signal-report.json'
        code=f'''import importlib.util,json,signal,sys
sys.path.insert(0,{str(Path(__file__).parent)!r})
spec=importlib.util.spec_from_file_location("inert_runner",{source!r});module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
from files import save
subject=module.Runner({str(self.subject.execution)!r},{str(self.variables)!r},"/usr/bin/true",env={self.env!r})
previous={{sig:signal.getsignal(sig) for sig in [signal.SIGTERM,signal.SIGHUP,signal.SIGINT]}}
save(subject.path("phase.json"),{{"status":"pending"}})
try:
 subject.run([sys.executable,"-c",{child_code!r}],timeout=15)
 save(subject.path("phase.json"),{{"status":"captured"}})
finally:
 save(__import__("pathlib").Path({str(report)!r}),{{"restored":all(signal.getsignal(sig)==handler for sig,handler in previous.items()),"settled":subject.settled}})
'''
        wrapper=subprocess.Popen([sys.executable,'-c',code],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        owned=None
        try:
            end=time.monotonic()+8
            while time.monotonic()<end:
                logs=list(self.subject.path('commands').glob('*.stdout'))
                if logs and logs[0].read_text().strip():
                    owned=json.loads(logs[0].read_text().splitlines()[0]);break
                if wrapper.poll() is not None:break
                time.sleep(.02)
            self.assertIsNotNone(owned,'Inert owned group did not start')
            os.kill(wrapper.pid,signal.SIGTERM)
            for _ in range(2):
                time.sleep(.04)
                try:os.kill(wrapper.pid,signal.SIGHUP)
                except ProcessLookupError:break
            wrapper_stdout,wrapper_stderr=wrapper.communicate(timeout=8)
            records=list(self.subject.path('commands').glob('*.json'));self.assertEqual(len(records),1)
            record=json.loads(records[0].read_text())
            diagnostics=json.dumps({'wrapper_returncode':wrapper.returncode,'wrapper_stdout':wrapper_stdout,'wrapper_stderr':wrapper_stderr,'child_stdout':records[0].with_suffix('.stdout').read_text(),'child_stderr':records[0].with_suffix('.stderr').read_text(),'record':record,'finally_report':report.read_text() if report.exists() else None},sort_keys=True)
            self.assertEqual(record['outcome'],'interrupted',diagnostics);self.assertEqual(record['signal'],signal.SIGTERM,diagnostics)
            self.assertEqual(record['pgid'],owned['pid']);self.assertTrue(record['process_group_absent'])
            self.assertEqual(json.loads(report.read_text()),{'restored':True,'settled':True})
            self.assertEqual(json.loads(self.subject.path('phase.json').read_text()),{'status':'pending'})
            for pid in [owned['pid'],owned['grandchild']]:
                with self.assertRaises(ProcessLookupError):os.kill(pid,0)
            with self.assertRaises(ProcessLookupError):os.killpg(owned['pid'],0)
        finally:
            # The original-red runner dies without settlement. Always retire
            # ONLY this test's recorded group, including after an assertion.
            if owned:
                for sig in [signal.SIGTERM,signal.SIGKILL]:
                    try:os.killpg(owned['pid'],sig)
                    except ProcessLookupError:break
                    end=time.monotonic()+2
                    while time.monotonic()<end:
                        try:os.killpg(owned['pid'],0)
                        except ProcessLookupError:break
                        time.sleep(.02)
            if wrapper.poll() is None:wrapper.kill()
            wrapper.communicate(timeout=5)
            if owned:
                with self.assertRaises(ProcessLookupError):os.killpg(owned['pid'],0)

if __name__ == '__main__':unittest.main()
