#!/usr/bin/env python3
"""Explicit synthetic Docker preparation fixture. NO AWS/RDS emulation or guest SQL.

Requires parent's dedicated local context. All credentials are newly generated,
RAM/stdin only. Public source copied with Docker APIs; no host/VM bind mounts.
"""
import argparse
import json
import ipaddress
import os
from pathlib import Path
import secrets
import time
import uuid
from secret_io import run,SecretIoError
import archive_source

NODE='node@sha256:48abc13a19400ca3985071e287bd405a1d99306770eb81d61202fb6b65cf0b57'
PG='postgres@sha256:748a18a54d3842d43bc156f0840d78029b8d349e0feca98c12b9c4ce3404a6b3'

def check(ok,code):
    if not ok:raise SecretIoError(code)

def fixture(source,receipt,context):
    marker=str(uuid.uuid4());prefix='rds-prep-'+marker[:8];pg=prefix+'-pg';node=prefix+'-node';network=prefix+'-net'
    declared={}
    names=[node,pg];env={k:os.environ[k] for k in ['PATH','HOME'] if k in os.environ}
    docker=['docker','--context',context];phase='preflight';checks=[];ids={};clean=False
    result={'ok':False,'scope':'synthetic Linux arm64 installed source/psql17 IO only; no actual RDS SQL/cloud','marker':marker,'images':{'node':NODE,'postgres':PG},'checks':checks,'containers':ids}
    baseline_volumes=None
    owner=secrets.token_urlsafe(32);initial=secrets.token_urlsafe(32);rotated=secrets.token_urlsafe(32)
    def call(*args,input_bytes=b'',timeout=60,allow_failure=False,max_input=131072):
        r=run(docker+list(args),input_bytes=input_bytes,env=env,timeout=timeout,max_input=max_input)
        # Neither these values nor error text goes to command logs/receipts.
        check(not any(s.encode() in r.stdout or s.encode() in r.stderr for s in [owner,initial,rotated]),'plaintext_output_refused')
        if not allow_failure and r.returncode:
            # Reduce known diagnostics to nonsecret classifications in RAM.
            code='docker_or_client_failed'
            if b'password authentication failed' in r.stderr:code='local_psql_auth_refused'
            elif any(x in r.stderr for x in [b'certificate',b'SSL error',b'root.crt']):code='local_psql_tls_refused'
            elif b'Permission denied' in r.stderr:code='local_file_permission_refused'
            elif b'No such file' in r.stderr:code='local_file_missing'
            raise SecretIoError(code)
        return r
    def absent(name):
        r=call('ps','-a','--filter','name=^/'+name+'$','--format','{{.ID}}')
        return not r.stdout.strip()
    def psql(*args,passwords):
        return call('exec','-i','--user','postgres','-e','PGSSLMODE=verify-full','-e','PGSSLROOTCERT=/fixture/server.crt','-e','PGPASSFILE=/dev/null','-e','PGCONNECT_TIMEOUT=5','-e','PGOPTIONS=-c statement_timeout=5000',pg,'psql','-X','-W','-v','ON_ERROR_STOP=1','-A','-t','-h','rds-prep-db','-U','fixture_admin','-d','postgres',*args,input_bytes=('\n'.join(passwords)+'\n').encode())
    def probe(password,ca,wrong=False):
        r=call('exec','-i',node,'node','/guest/local-pg-probe.mjs',input_bytes=json.dumps({'password':password,'ca':ca,'wrongHostname':wrong}).encode())
        return json.loads(r.stdout)
    try:
        check(Path(source).is_dir() and (Path(source)/'archive-manifest.json').is_file(),'prepared_source_required')
        check(call('info','--format','{{.Architecture}}').stdout.strip()==b'aarch64','arm64_daemon_required')
        baseline_volumes=set(call('volume','ls','--format','{{.Name}}').stdout.decode().splitlines())
        check(all(absent(n) for n in names),'container_collision')
        check(not call('network','ls','--filter','name=^'+network+'$','--format','{{.ID}}').stdout.strip(),'network_collision')
        for image in [NODE,PG]:
            meta=json.loads(call('image','inspect',image).stdout)[0]
            check(meta['Architecture']=='arm64' and meta['Os']=='linux','image_architecture_refused')
            declared[image]=set(meta.get('Config',{}).get('Volumes') or {})
            check(declared[image]==({'/var/lib/postgresql/data'} if image==PG else set()),'declared_volume_set_changed')
        result['network_id']=call('network','create','--internal','--label','proof.rds-prep='+marker,network).stdout.decode().strip()
        phase='containers'
        for name,image,mount in [(pg,PG,'/fixture:rw,nosuid,size=256m,mode=1777'),(node,NODE,'/guest:rw,nosuid,size=32m,mode=1777')]:
            args=['create','--name',name,'--label','proof.rds-prep='+marker,'--platform','linux/arm64','--network',network,'--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','--memory','512m','--cpus','1','--pids-limit','128','--log-driver','none','--ulimit','core=0','--tmpfs',mount,'--tmpfs','/tmp:rw,nosuid,size=16m','--entrypoint','sleep']
            if name==pg:args+=['--network-alias','rds-prep-db','--network-alias','rds-prep-wrong']
            for path in sorted(declared[image]):args+=['--tmpfs',path+':rw,nosuid,size=16m']
            ids[name]=call(*args,image,'infinity').stdout.decode().strip()
            mounts=json.loads(call('inspect','--format','{{json .Mounts}}',name).stdout)
            check(all(m['Type']!='volume' for m in mounts),'implicit_volume_refused')
            call('start',name)
        phase='public-source-stream'
        archive=Path(receipt).with_suffix('.tar.gz');archive_source.build(source,archive)
        call('exec','-i',node,'tar','-xzf','-','-C','/guest',input_bytes=archive.read_bytes(),max_input=4*1024*1024)
        call('exec','-i',node,'sh','-c','cat > /guest/local-pg-probe.mjs',input_bytes=Path(__file__).with_name('local-pg-probe.mjs').read_bytes())
        phase='installed-import'
        imported=json.loads(call('exec',node,'node','--experimental-transform-types','--import','/guest/runtime-hook.mjs','/guest/import-check.mjs').stdout)
        check(imported['ok'] and imported['arch']=='arm64' and imported['platform']=='linux' and imported['node'].startswith('v24.'),'installed_import_refused')
        result['installed_import']=imported;checks.append('original_ts_installed_linux_arm64_import')
        result['psql_version']=call('exec',pg,'psql','--version').stdout.decode().strip()
        check(' 17.' in result['psql_version'],'psql17_required')
        phase='synthetic-tls'
        for stem,cn in [('server','rds-prep-db'),('wrong','wrong-ca.invalid')]:
            call('exec','--user','postgres',pg,'openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout','/fixture/'+stem+'.key','-out','/fixture/'+stem+'.crt','-days','1','-subj','/CN='+cn,'-addext','subjectAltName=DNS:'+cn)
        ca=call('exec',pg,'cat','/fixture/server.crt').stdout.decode();wrong_ca=call('exec',pg,'cat','/fixture/wrong.crt').stdout.decode()
        call('exec','-i','--user','postgres',pg,'initdb','-D','/fixture/data','--username','fixture_admin','--auth-host','scram-sha-256','--auth-local','reject','--pwfile=/dev/stdin',input_bytes=(owner+'\n').encode())
        subnet=call('network','inspect','--format','{{(index .IPAM.Config 0).Subnet}}',network).stdout.decode().strip()
        check(ipaddress.ip_network(subnet).is_private,'nonprivate_fixture_network_refused')
        call('exec','-i','--user','postgres',pg,'sh','-c','cat >> /fixture/data/pg_hba.conf',input_bytes=('hostssl all all '+subnet+' scram-sha-256\n').encode())
        call('exec','--detach','--user','postgres',pg,'postgres','-D','/fixture/data','-c','listen_addresses=*','-c','unix_socket_directories=/fixture','-c','ssl=on','-c','ssl_cert_file=/fixture/server.crt','-c','ssl_key_file=/fixture/server.key','-c','ssl_min_protocol_version=TLSv1.2','-c','log_statement=none','-c','log_min_error_statement=panic','-c','log_min_messages=panic','-c','log_connections=off','-c','log_disconnections=off','-c','logging_collector=off','-c','shared_buffers=16MB','-c','max_connections=10')
        for _ in range(40):
            if call('exec','--user','postgres',pg,'pg_isready','-h','rds-prep-db','-U','fixture_admin','-d','postgres',allow_failure=True).returncode==0:break
            time.sleep(.2)
        else:raise SecretIoError('local_postgres_not_ready')
        phase='detached-bootstrap'
        call('exec','-i','--user','postgres',pg,'tee','/fixture/bootstrap.sql',input_bytes=b'CREATE ROLE proof_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;\nSELECT 1;\n')
        check(psql('-f','/fixture/bootstrap.sql',passwords=[owner]).stdout.strip().endswith(b'1'),'detached_file_prompt_failed')
        checks.append('detached_psql17_file_owner_password_stdin')
        phase='initial-password'
        psql('-c','\\password "proof_runtime"',passwords=[owner,initial,initial])
        check(probe(initial,ca).get('authenticated') is True,'initial_tls_authentication_failed');checks.append('initial_fresh_tls_login')
        check(psql('-c',"SELECT rolpassword LIKE 'SCRAM-SHA-256$%' FROM pg_authid WHERE rolname='proof_runtime'",passwords=[owner]).stdout.strip()==b't','client_scram_required');checks.append('psql_password_client_scram')
        phase='rotated-password'
        psql('-c','\\password "proof_runtime"',passwords=[owner,rotated,rotated])
        check(probe(initial,ca)=={'ok':False,'code':'28P01'},'old_password_requires_exact_28P01');checks.append('fresh_old_password_exact_28P01')
        check(probe(rotated,ca).get('authenticated') is True,'rotated_tls_authentication_failed');checks.append('rotated_fresh_tls_login')
        phase='tls-negatives'
        check(probe(rotated,ca,True)=={'ok':False,'code':'ERR_TLS_CERT_ALTNAME_INVALID'},'wrong_hostname_requires_tls_refusal');checks.append('wrong_hostname_refused')
        refused=probe(rotated,wrong_ca)
        check(refused.get('ok') is False and refused.get('code') in ['DEPTH_ZERO_SELF_SIGNED_CERT','SELF_SIGNED_CERT_IN_CHAIN','UNABLE_TO_VERIFY_LEAF_SIGNATURE'],'wrong_ca_requires_tls_refusal');checks.append('wrong_ca_refused')
        result['ok']=True
    except Exception as error:
        result['error_code']=error.code if isinstance(error,SecretIoError) else 'local_preparation_failed'
        result['failed_phase']=phase
    finally:
        # Exact fresh names+label, never another fixture's resource or the VM.
        cleanup={}
        for name in names:
            try:
                if not absent(name):
                    label=call('inspect','--format','{{index .Config.Labels "proof.rds-prep"}}',name).stdout.decode().strip()
                    check(label==marker,'foreign_container_cleanup_refused');call('rm','--force','--volumes',name)
                cleanup[name]=absent(name)
            except Exception:cleanup[name]=False
        try:
            if call('network','ls','--filter','name=^'+network+'$','--format','{{.ID}}').stdout.strip():
                label=call('network','inspect','--format','{{index .Labels "proof.rds-prep"}}',network).stdout.decode().strip()
                check(label==marker,'foreign_network_cleanup_refused');call('network','rm',network)
            cleanup[network]=not call('network','ls','--filter','name=^'+network+'$','--format','{{.ID}}').stdout.strip()
        except Exception:cleanup[network]=False
        if baseline_volumes is not None:
            try:
                after=set(call('volume','ls','--format','{{.Name}}').stdout.decode().splitlines())
                cleanup['no_new_volumes']=not (after-baseline_volumes)
                result['preserved_baseline_volume_count']=len(baseline_volumes)
            except Exception:cleanup['no_new_volumes']=False
        result['cleanup']=cleanup;result['ok']=result['ok'] and all(cleanup.values())
        Path(receipt).write_text(json.dumps(result,indent=2)+'\n');os.chmod(receipt,0o600)
    return result

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--source',required=True);parser.add_argument('--receipt',required=True);parser.add_argument('--context',required=True,choices=['colima-rds2']);a=parser.parse_args()
    r=fixture(a.source,a.receipt,a.context);print(json.dumps(r));raise SystemExit(0 if r['ok'] else 1)
