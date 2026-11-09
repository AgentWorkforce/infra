/** Trusted IO adapter for rds-activation/v1. The reviewed driver and migrator run unchanged, as child processes. */
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {readFile} from 'node:fs/promises';
import readline from 'node:readline';
import tls from 'node:tls';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {expectedSchema,generation} from './source/src/hoopdb/migrate.ts';
import {schemaVerdict} from './source/src/shared/db.ts';
const require=createRequire(import.meta.url);const {Client}=require('pg');
const write=process.stdout.write.bind(process.stdout);
// Original application telemetry is discarded, not forwarded through the control
// protocol or persisted. Foreign error text is never an admissible receipt.
process.stdout.write=(_chunk,encoding,callback)=>{if(typeof encoding==='function')encoding();else if(typeof callback==='function')callback();return true;};
process.stderr.write=process.stdout.write;
const CONTRACT='rds-activation/v1';
const HOOK=fileURLToPath(new URL('./runtime-hook.mjs',import.meta.url));
const DRIVER=fileURLToPath(new URL('./source/src/hoopdb/rds-activation.ts',import.meta.url));
const MIGRATOR=fileURLToPath(new URL('./source/src/hoopdb/migrate.ts',import.meta.url));
const CA_FILE=fileURLToPath(new URL('./assets/rds-ca.pem',import.meta.url));
const SOURCE=fileURLToPath(new URL('./source/',import.meta.url));
const reader=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
const iterator=reader[Symbol.asyncIterator]();let sequence=0;let cfg;let step='start';const checks=[];
const requireOk=(value)=>{if(!value)throw new Error('guest_transport_refused');};
const sha=(value)=>createHash('sha256').update(value).digest('hex');
async function readFrame(){const {value,done}=await iterator.next();requireOk(!done&&typeof value==='string'&&Buffer.byteLength(value)<=65536);return JSON.parse(value);}
function send(value){write(JSON.stringify({format:'actual-rds-io-v2',sequence:++sequence,...value})+'\n');}
async function request(value){send(value);const answer=await readFrame();requireOk(answer.format==='actual-rds-io-v2'&&answer.sequence===sequence&&answer.ok===true);return answer;}
function deadline(){requireOk(Date.now()<Date.parse(cfg.scope.deadline));}
async function connect(role,password,database,negative){
 deadline();const ssl={ca:negative==='ca'?cfg.wrongCa:cfg.ca,rejectUnauthorized:true};
 if(negative==='hostname')ssl.checkServerIdentity=(_host,cert)=>tls.checkServerIdentity('refused.invalid',cert);
 const client=new Client({host:cfg.scope.endpoint,port:5432,database,user:role,password,ssl,connectionTimeoutMillis:5000,query_timeout:10000,statement_timeout:10000,application_name:'rds-activation-proof'});
 try{await client.connect();deadline();return client;}catch(error){await client.end().catch(()=>{});throw error;}
}
async function refused(role,password,database,mode,allowed){
 let client;
 try{client=await connect(role,password,database,mode);}catch(error){requireOk(allowed.includes(error.code));return;}
 try{await client.end();}finally{throw new Error('negative_connection_succeeded');}
}
async function readiness(password){
 deadline();const client=await connect(cfg.scope.runtimeRole,password,cfg.scope.database);
 try{
  const row=(await client.query('SELECT session_user AS login,current_user AS role,current_database() AS database,coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),false) AS tls')).rows[0];
  // SET ROLE / role=... substitution: the authenticated LOGIN must itself be the runtime.
  requireOk(row.login===cfg.scope.runtimeRole&&row.role===cfg.scope.runtimeRole&&row.database===cfg.scope.database&&row.tls===true);
  process.env.HOOPDB_DB_MODE='rds';const expected=await expectedSchema();requireOk(expected.generation===cfg.scope.generation&&expected.dbMode==='rds');
  const verdict=await schemaVerdict(expected,async work=>{await client.query('BEGIN');try{const value=await work(client);await client.query('COMMIT');return value;}catch(error){await client.query('ROLLBACK').catch(()=>{});throw error;}});
  requireOk(verdict.ok);deadline();
 }finally{await client.end();}
}
// The driver's only machine interface: secrets on stdin, one JSON result on fd 3.
function driver(command,secrets,extra=[]){
 deadline();
 // The driver uses TypeScript parameter properties, which plain Node type stripping refuses.
 const args=['--experimental-transform-types','--import',HOOK,DRIVER,command,'--host',cfg.scope.endpoint,'--tls','verify-full','--ca-file',CA_FILE,'--result-fd','3','--secrets-stdin',...extra];
 if(command!=='rotate-self')args.push('--provisioner',cfg.scope.provisioner);
 return new Promise((resolve,reject)=>{
  const child=spawn(process.execPath,args,{cwd:SOURCE,env:{PATH:process.env.PATH},stdio:['pipe','ignore','ignore','pipe']});
  const chunks=[];child.stdio[3].on('data',chunk=>chunks.push(chunk));child.on('error',reject);
  child.stdin.on('error',()=>{});child.stdin.end(JSON.stringify(secrets));
  child.on('close',code=>{try{
   const result=JSON.parse(Buffer.concat(chunks).toString('utf8'));
   requireOk(result.contract===CONTRACT&&result.artifact_sha256===cfg.scope.artifactSha256&&result.exit_code===code);
   resolve(result);
  }catch{reject(new Error('driver_result_refused'));}});
 });
}
const roleSecrets=(passwords)=>({provisioner_password:cfg.provisionerPassword,role_passwords:passwords});
function requireEmptyGraph(result){requireOk(result.graph&&Array.isArray(result.graph.edges)&&result.graph.edges.length===0&&result.graph.helper_present===false&&result.database.name===cfg.scope.database&&result.database.owner===cfg.scope.owner);}
function migrate(password){
 deadline();
 const url=`postgres://${encodeURIComponent(cfg.scope.owner)}:${encodeURIComponent(password)}@${cfg.scope.endpoint}:5432/${encodeURIComponent(cfg.scope.database)}?sslmode=verify-full&sslrootcert=${encodeURIComponent(CA_FILE)}`;
 return new Promise((resolve,reject)=>{
  const child=spawn(process.execPath,['--import',HOOK,MIGRATOR],{cwd:SOURCE,stdio:['ignore','ignore','ignore','pipe'],env:{PATH:process.env.PATH,HOOPDB_URL_FD:'3',HOOPDB_DB_MODE:'rds',HOOPDB_RDS_LAYOUT:'separate-database',HOOPDB_SUPABASE_SHIM:'false',HOOPDB_RUNTIME_ROLE:cfg.scope.runtimeRole,HOOPDB_RUNTIME_ROLE_LOGIN:'true',HOOPDB_FUNCTION_BOUNDARY_MODE:'global-default-revoke'}});
  // The URL holds the owner password: a private pipe, never the child's environment or argv.
  child.stdio[3].on('error',()=>{});child.stdio[3].end(url);
  child.on('error',reject);child.on('close',code=>code===0?resolve():reject(new Error('migrate_failed')));
 });
}
function passwordMap(value){requireOk(value&&typeof value==='object'&&Object.keys(value).sort().join()===[...cfg.scope.loginRoles].sort().join()&&Object.values(value).every(p=>typeof p==='string'&&p.length>=32&&!/[\r\n\0]/.test(p)));return value;}
let complete=false;
try{
 cfg=await readFrame();requireOk(cfg.format==='actual-rds-io-v2'&&cfg.sequence===0&&Object.keys(cfg).sort().join(',')==='ca,format,priorPasswords,provisionerPassword,scope,sequence,sources,wrongCa');
 requireOk(typeof cfg.provisionerPassword==='string'&&cfg.provisionerPassword.length>0&&!/[\r\n\0]/.test(cfg.provisionerPassword));
 requireOk(cfg.scope.contract===CONTRACT&&cfg.scope.provisioner!==cfg.scope.owner&&cfg.scope.provisioner!==cfg.scope.runtimeRole&&!cfg.scope.loginRoles.includes(cfg.scope.provisioner)&&cfg.scope.loginRoles.includes(cfg.scope.owner)&&cfg.scope.loginRoles.includes(cfg.scope.runtimeRole));
 deadline();requireOk(sha(JSON.stringify(cfg.sources))===cfg.scope.sourceManifestSha256);
 requireOk(cfg.scope.phase==='fresh'?cfg.priorPasswords===null:cfg.scope.phase==='restored');
 const installed=JSON.parse(await readFile(new URL('./guest-sources.json',import.meta.url),'utf8'));requireOk(sha(JSON.stringify(installed))===cfg.scope.sourceManifestSha256);
 requireOk(installed.artifactSha256===cfg.scope.artifactSha256&&installed.contract===CONTRACT&&await generation()===cfg.scope.generation);
 // These are actual TLS errors against the same endpoint/certificate. The hostname
 // negative runs Node's default checker with a deliberately wrong host; pg replaces
 // ssl.servername, so changing that option alone is insufficient.
 step='tls_negative';const maintenance=cfg.scope.maintenanceDatabase;
 await refused(cfg.scope.provisioner,cfg.provisionerPassword,maintenance,'hostname',['ERR_TLS_CERT_ALTNAME_INVALID']);checks.push('wrong_hostname_tls_refused');
 await refused(cfg.scope.provisioner,cfg.provisionerPassword,maintenance,'ca',['DEPTH_ZERO_SELF_SIGNED_CERT','SELF_SIGNED_CERT_IN_CHAIN','UNABLE_TO_VERIFY_LEAF_SIGNATURE','UNABLE_TO_GET_ISSUER_CERT_LOCALLY']);checks.push('wrong_ca_tls_refused');
 const chain=async()=>{step='bootstrap_chain';for(const path of cfg.sources.bootstrapChain){deadline();await request({operation:'bootstrap',file:{path,sha256:cfg.sources.files[path]}});}checks.push('committed_bootstraps');};
 const migrations=async(password)=>{step='migrate';await migrate(password);await migrate(password);checks.push('migrate_and_idempotent_rerun');};
 let passwords,secretRef;
 if(cfg.scope.phase==='fresh'){
  step='credentials';const credentials=await request({operation:'credentials'});passwords=passwordMap(credentials.passwords);secretRef=credentials.secretRef;
  step='activation_run';const run=await driver('run',roleSecrets(passwords));requireOk(run.status==='activated'&&run.exit_code===0);requireEmptyGraph(run);checks.push('activation_run');
  await chain();await migrations(passwords[cfg.scope.owner]);
 }else{
  const prior=passwordMap(cfg.priorPasswords);
  step='restored_readiness';await readiness(prior[cfg.scope.runtimeRole]);checks.push('seed_version_fresh_tls_readiness_BEFORE_bootstrap_or_rotation');
  await request({operation:'restored-auth'});
  step='activation_run';const run=await driver('run',roleSecrets(prior));requireOk(run.status==='already_activated'&&run.exit_code===0);requireEmptyGraph(run);checks.push('activation_already_activated');
  await chain();await migrations(prior[cfg.scope.owner]);
  step='credentials';const credentials=await request({operation:'credentials'});passwords=passwordMap(credentials.passwords);secretRef=credentials.secretRef;
  const next=passwords[cfg.scope.runtimeRole],old=prior[cfg.scope.runtimeRole];requireOk(next!==old);
  step='rotate_self';const rotated=await driver('rotate-self',{current_password:old,new_password:next,role_passwords:{}},['--role',cfg.scope.runtimeRole]);requireOk(rotated.status==='rotated'&&rotated.exit_code===0);checks.push('rotate_self');
  await refused(cfg.scope.runtimeRole,old,cfg.scope.database,undefined,['28P01']);checks.push('old_runtime_password_exact_28P01');
 }
 step='driver_verify';const verified=await driver('verify',roleSecrets(passwords));requireOk(verified.status==='verified'&&verified.exit_code===0);requireEmptyGraph(verified);checks.push('driver_verify');
 // The persisted Secrets Manager version, read back by the host, is what logs in here.
 step='runtime_readiness';await readiness(passwords[cfg.scope.runtimeRole]);checks.push('exact_persisted_version_fresh_tls_readiness');
 const evidence={contract:verified.contract,artifact_sha256:verified.artifact_sha256,migration_generation:verified.migration_generation,database:{name:verified.database.name,owner:verified.database.owner},graph:verified.graph};
 const receipt={format:'rds-activation-guest-v1',scope:cfg.scope,ok:true,phase:'sql_verified_awaiting_parent_retirement',checks,errorCodes:[],evidenceSha256:sha(JSON.stringify(evidence)),infrastructureRetired:false,requiresInstanceRetirement:true};
 send({operation:'result',ok:true,receipt,checks,secretRef});complete=true;
}catch{
 send({operation:'result',ok:false,code:'guest_transport_failed',step,checks});
}finally{
 reader.close();process.stdin.pause();
}
if(!complete)process.exitCode=1;
