#!/usr/bin/env python3
"""Opt-in disposable native PG17 proof of the managed two-pool init contract.
No live kubeconfig, cloud API, registry push/pull or project credentials. Requires cached images.
Private fixture keys are generated inside tmpfs and destroyed with the owned container.
"""
import argparse,hashlib,json,os,pathlib,re,secrets,shutil,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--image',required=True);p.add_argument('--docker',default=shutil.which('docker') or '/Applications/Docker.app/Contents/Resources/bin/docker');p.add_argument('--receipt',required=True);a=p.parse_args()
if not re.fullmatch(r'(?:[a-z0-9./_-]+@)?sha256:[a-f0-9]{64}',a.image):raise SystemExit('immutable cached native services image required')
host=os.environ.get('DOCKER_HOST')
if not host:host=subprocess.check_output([a.docker,'context','inspect','--format','{{.Endpoints.docker.Host}}'],text=True).strip()
if not host.startswith('unix://'):raise SystemExit('local unix Docker socket required')
D=[a.docker,'--host',host]
PG='pgvector/pgvector:pg17@sha256:7d0a41464797aeb9862dfdc0bbf1526b82cfd324cdd8036df19e3545f4a9ccb8'
def run(argv,env=None,check=True):
 r=subprocess.run(argv,capture_output=True,text=True,env=env)
 if check and r.returncode:raise RuntimeError('fixture command failed; output withheld')
 return r
for image in [a.image,PG]:run(D+['image','inspect',image])
name='native-consumer-tls-'+secrets.token_hex(6);root_password=secrets.token_hex(32);writer_password=secrets.token_hex(32)
fixture_env={**os.environ,'POSTGRES_PASSWORD':root_password,'POSTGRES_DB':'hoopdb','POSTGRES_HOST_AUTH_METHOD':'scram-sha-256','POSTGRES_INITDB_ARGS':'--auth-host=scram-sha-256 --auth-local=trust','PGDATA':'/var/lib/postgresql/data/pgdata'}
cert_script='''set -eu
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=native-consumer-fixture-ca -addext basicConstraints=critical,CA:TRUE -keyout /run/native-tls/ca.key -out /run/native-tls/ca.crt >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -subj /CN=postgres.native.fixture -addext subjectAltName=DNS:postgres.native.fixture -keyout /run/native-tls/server.key -out /run/native-tls/server.csr >/dev/null 2>&1
openssl x509 -req -in /run/native-tls/server.csr -CA /run/native-tls/ca.crt -CAkey /run/native-tls/ca.key -CAcreateserial -days 1 -copy_extensions copy -out /run/native-tls/server.crt >/dev/null 2>&1
chown -R postgres:postgres /run/native-tls
chmod 600 /run/native-tls/*.key
exec docker-entrypoint.sh postgres -c cluster_name=native-consumer-contract-fixture -c ssl=on -c ssl_cert_file=/run/native-tls/server.crt -c ssl_key_file=/run/native-tls/server.key
'''
common={};created=False
try:
 run(D+['run','--detach','--rm','--pull=never','--name',name,'--network','none','--add-host','postgres.native.fixture:127.0.0.1','--add-host','wrong.native.fixture:127.0.0.1','--memory','768m','--tmpfs','/var/lib/postgresql/data:rw,size=512m','--tmpfs','/run/native-tls:rw,mode=700','-e','POSTGRES_PASSWORD','-e','POSTGRES_DB','-e','POSTGRES_HOST_AUTH_METHOD','-e','POSTGRES_INITDB_ARGS','-e','PGDATA','--entrypoint','sh',PG,'-ec',cert_script],env=fixture_env);created=True
 for _ in range(60):
  if run(D+['exec',name,'pg_isready','-U','postgres','-d','hoopdb'],check=False).returncode==0:break
  time.sleep(1)
 else:raise RuntimeError('fixture Postgres did not become ready')
 public_ca=run(D+['exec',name,'cat','/run/native-tls/ca.crt']).stdout
 with tempfile.TemporaryDirectory(prefix='native-consumer-public-ca-') as folder:
  ca=pathlib.Path(folder)/'ca.crt';ca.write_text(public_ca)
  from urllib.parse import quote
  def url(role,password,hostname='postgres.native.fixture'):
   return 'postgresql://'+role+':'+password+'@'+hostname+':5432/hoopdb?sslmode=verify-full&sslrootcert='+quote('/etc/native-consumer-postgres/ca.crt',safe='')
  common={'RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER':'true','HOOPDB_DB_MODE':'selfhosted','SEARCH_INDEX_BACKEND':'postgres','SEARCH_INDEX_POSTGRES_BACKEND_ID':'native-contract-fixture','READ_API_COMPLETE_SINCE':'2026-11-08T00:00:00Z','PIPELINE_KEY_PREFIX':'96bulls','PIPELINE_ORG_FROM_PREFIX':'true','PIPELINE_FANOUT':'off','PIPELINE_RUNTIME':'workers','SESSION_POSTGRES_TLS_PROFILE':'custom-ca','SESSION_POSTGRES_CA_FILE':'/etc/native-consumer-postgres/ca.crt','NATIVE_CONSUMER_CA_SOURCE_FILE':'/var/run/native-consumer-ca-source/ca.crt','SESSION_POSTGRES_CA_SHA256':hashlib.sha256(public_ca.encode()).hexdigest(),'NATIVE_CONSUMER_EXPECTED_HOST':'postgres.native.fixture','NATIVE_CONSUMER_EXPECTED_PORT':'5432','NATIVE_CONSUMER_EXPECTED_DATABASE':'hoopdb','NATIVE_CONSUMER_PREFLIGHT_TIMEOUT_SECONDS':'30','NATIVE_FIXTURE_PASSWORD':root_password,'NATIVE_FIXTURE_WRITER_PASSWORD':writer_password}
  def image_command(env,entry,args,ca_file=None):
   ca_file=ca_file or ca
   variables={**common,**env};cli=D+['run','--rm','--pull=never','--network','container:'+name,'--read-only','--tmpfs','/tmp:rw,mode=1777,size=128m','--cap-drop','ALL','--security-opt','no-new-privileges']
   for key in variables:cli+=['-e',key]
   preflight=args==['/etc/native-consumer-contract/preflight.mjs']
   if preflight:cli+=['--tmpfs','/etc/native-consumer-postgres:rw,mode=1777,size=256k','--mount','type=bind,source='+str(ca_file)+',target=/var/run/native-consumer-ca-source/ca.crt,readonly']
   else:cli+=['--mount','type=bind,source='+str(ca_file)+',target=/etc/native-consumer-postgres/ca.crt,readonly']
   cli+=['--mount','type=bind,source='+str(ROOT/'charts/sessions-pipeline/files/native-consumer/preflight.mjs')+',target=/etc/native-consumer-contract/preflight.mjs,readonly']
   if entry:cli+=['--entrypoint',entry]
   return run(cli+[a.image,*args],env={**os.environ,**variables},check=False)
  setup='''import pg from "pg";import{readFileSync}from"node:fs";import{postgresTlsOptions}from"./src/shared/postgres-tls.ts";import{runMigrations}from"./src/hoopdb/migrate.ts";
const c=new pg.Client({host:"postgres.native.fixture",database:"hoopdb",user:"postgres",password:process.env.NATIVE_FIXTURE_PASSWORD,ssl:postgresTlsOptions()});await c.connect();
try{if((await c.query("SHOW cluster_name")).rows[0].cluster_name!=="native-consumer-contract-fixture")throw Error("foreign_fixture");if((await c.query("SELECT to_regnamespace('sessions') AS n")).rows[0].n!==null)throw Error("nonempty_fixture");await c.query("CREATE EXTENSION pg_trgm; CREATE EXTENSION btree_gin; CREATE ROLE fixture_runtime NOLOGIN NOINHERIT; REVOKE TEMPORARY ON DATABASE hoopdb FROM PUBLIC; GRANT CONNECT ON DATABASE hoopdb TO fixture_runtime; ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC");await runMigrations({query:async(text,params)=>(await c.query(text,params))},{profile:{mode:"selfhosted",shim:true,bootstrap:true,verify:true,runtimeRole:"fixture_runtime",runtimeLogin:false,functionBoundary:"global-default-revoke"}});}finally{await c.end();}'''
  if image_command({},'bun',['-e',setup]).returncode:raise RuntimeError('source migration fixture failed')
  owner={'RELAYHISTORY_PIPELINE_CONSUMER_SECRET':json.dumps({'hoopdb_url':url('postgres',root_password)}),'NATIVE_CONSUMER_PREFLIGHT_MODE':'bootstrap','NATIVE_CONSUMER_EXPECTED_ROLE':'postgres'}
  if image_command(owner,'bun',['/etc/native-consumer-contract/preflight.mjs']).returncode:raise RuntimeError('owner two-pool TLS preflight failed')
  if image_command({**owner,'SERVICE':'session-pipeline-consumer-bootstrap'},None,[]).returncode:raise RuntimeError('official consumer bootstrap failed')
  password='''import pg from"pg";import{postgresTlsOptions}from"./src/shared/postgres-tls.ts";const c=new pg.Client({host:"postgres.native.fixture",database:"hoopdb",user:"postgres",password:process.env.NATIVE_FIXTURE_PASSWORD,ssl:postgresTlsOptions()});await c.connect();try{const r=await c.query("SELECT format('ALTER ROLE search_consumer_runtime PASSWORD %L',$1::text) AS sql",[process.env.NATIVE_FIXTURE_WRITER_PASSWORD]);await c.query(r.rows[0].sql);}finally{await c.end();}'''
  if image_command({},'bun',['-e',password]).returncode:raise RuntimeError('runtime credential provisioning failed')
  runtime={'RELAYHISTORY_PIPELINE_CONSUMER_SECRET':json.dumps({'hoopdb_url':url('search_consumer_runtime',writer_password)}),'NATIVE_CONSUMER_PREFLIGHT_MODE':'runtime','NATIVE_CONSUMER_EXPECTED_ROLE':'search_consumer_runtime'}
  good=image_command(runtime,'bun',['/etc/native-consumer-contract/preflight.mjs'])
  if good.returncode:raise RuntimeError('runtime two-pool TLS/schema preflight failed')
  bad={**runtime,'NATIVE_CONSUMER_EXPECTED_HOST':'wrong.native.fixture','RELAYHISTORY_PIPELINE_CONSUMER_SECRET':json.dumps({'hoopdb_url':url('search_consumer_runtime',writer_password,'wrong.native.fixture')})}
  if image_command(bad,'bun',['/etc/native-consumer-contract/preflight.mjs']).returncode==0:raise RuntimeError('wrong certificate hostname was accepted')
  bad={**runtime,'SESSION_POSTGRES_CA_SHA256':'0'*64}
  if image_command(bad,'bun',['/etc/native-consumer-contract/preflight.mjs']).returncode==0:raise RuntimeError('wrong CA pin was accepted')
  # A correctly pinned but unrelated CA must still fail certificate verification.
  wrong_ca=run(D+['exec',name,'sh','-ec','openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=untrusted-fixture-ca -addext basicConstraints=critical,CA:TRUE -keyout /run/native-tls/wrong-ca.key -out /run/native-tls/wrong-ca.crt >/dev/null 2>&1; cat /run/native-tls/wrong-ca.crt']).stdout
  wrong_ca_file=pathlib.Path(folder)/'wrong-ca.crt';wrong_ca_file.write_text(wrong_ca)
  bad={**runtime,'SESSION_POSTGRES_CA_SHA256':hashlib.sha256(wrong_ca.encode()).hexdigest()}
  if image_command(bad,'bun',['/etc/native-consumer-contract/preflight.mjs'],wrong_ca_file).returncode==0:raise RuntimeError('untrusted certificate root was accepted')
  receipt={'scope':'disposable native PostgreSQL17 fixture; no live cluster or object store','image':a.image,'preflightSha256':hashlib.sha256((ROOT/'charts/sessions-pipeline/files/native-consumer/preflight.mjs').read_bytes()).hexdigest(),'checks':{'ownerBothPoolsVerifiedTls':True,'officialBootstrap':True,'runtimeBothPoolsVerifiedTlsAndSourceGates':True,'wrongHostnameRefused':True,'wrongCaPinRefused':True,'untrustedCaRefused':True},'credentials':'synthetic only, memory/environment; private CA keys stayed in container tmpfs'}
  pathlib.Path(a.receipt).write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({'nativeTlsProof':'PASS','checks':receipt['checks']}))
finally:
 if created:run(D+['stop',name],check=False)
