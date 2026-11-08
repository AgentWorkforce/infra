/** Trusted IO adapter only. Exact original guest library/SQL remains untouched. */
import {readFile} from 'node:fs/promises';
import readline from 'node:readline';
import tls from 'node:tls';
import {createRequire} from 'node:module';
import {runActualRdsGuest,validateGuestScope,sourceManifestSha256} from './source/scripts/pg-proof/actual-rds-guest.ts';
import {plan} from './source/src/hoopdb/migrate.ts';
import {schemaVerdict} from './source/src/shared/db.ts';
const require=createRequire(import.meta.url);const {Client}=require('pg');
const write=process.stdout.write.bind(process.stdout);
// Original application telemetry is discarded, not forwarded through the control
// protocol or persisted. Foreign error text is never an admissible receipt.
process.stdout.write=(_chunk,encoding,callback)=>{if(typeof encoding==='function')encoding();else if(typeof callback==='function')callback();return true;};
process.stderr.write=process.stdout.write;
const reader=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
const iterator=reader[Symbol.asyncIterator]();let sequence=0;let cfg;const checks=[];
const requireOk=(value)=>{if(!value)throw new Error('guest_transport_refused');};
async function readFrame(){const {value,done}=await iterator.next();requireOk(!done&&typeof value==='string'&&Buffer.byteLength(value)<=65536);return JSON.parse(value);}
function send(value){write(JSON.stringify({format:'actual-rds-io-v1',sequence:++sequence,...value})+'\n');}
async function request(value){send(value);const answer=await readFrame();requireOk(answer.format==='actual-rds-io-v1'&&answer.sequence===sequence&&answer.ok===true);return answer;}
function deadline(){requireOk(Date.now()<Date.parse(cfg.scope.deadline));}
async function connect(role,password,negative){
 deadline();const ssl={ca:negative==='ca'?cfg.wrongCa:cfg.ca,rejectUnauthorized:true};
 if(negative==='hostname')ssl.checkServerIdentity=(_host,cert)=>tls.checkServerIdentity('refused.invalid',cert);
 const client=new Client({host:cfg.scope.endpoint,port:5432,database:cfg.scope.database,user:role,password,ssl,connectionTimeoutMillis:5000,query_timeout:10000,statement_timeout:10000,application_name:'actual-rds-proof'});
 try{await client.connect();deadline();return client;}catch(error){await client.end().catch(()=>{});throw error;}
}
async function refused(role,password,mode,allowed){
 let client;
 try{client=await connect(role,password,mode);}catch(error){requireOk(allowed.includes(error.code));return;}
 try{await client.end();}finally{throw new Error('negative_connection_succeeded');}
}
async function readiness(client){
 deadline();const row=(await client.query('SELECT session_user AS login,current_user AS role,current_database() AS database,coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),false) AS tls')).rows[0];
 // SET ROLE / role=... substitution: the authenticated LOGIN must itself be the runtime.
 requireOk(row.login===cfg.scope.runtimeRole&&row.role===cfg.scope.runtimeRole&&row.database===cfg.scope.database&&row.tls===true);
 const expected={generation:cfg.scope.generation,dbMode:'rds',names:(await plan({mode:'rds',shim:false,bootstrap:false,verify:true,runtimeRole:cfg.scope.runtimeRole,runtimeLogin:true,functionBoundary:'global-default-revoke'})).map(s=>s.name)};
 const verdict=await schemaVerdict(expected,async work=>{await client.query('BEGIN');try{const value=await work(client);await client.query('COMMIT');return value;}catch(error){await client.query('ROLLBACK').catch(()=>{});throw error;}});
 requireOk(verdict.ok);deadline();
}
let owner;let complete=false;
try{
 cfg=await readFrame();requireOk(cfg.format==='actual-rds-io-v1'&&cfg.sequence===0&&Object.keys(cfg).sort().join(',')==='ca,format,ownerPassword,priorRuntimePassword,scope,sequence,sources,wrongCa');
 requireOk(typeof cfg.ownerPassword==='string'&&cfg.ownerPassword.length>0&&!/[\r\n\0]/.test(cfg.ownerPassword));
 validateGuestScope(cfg.scope,new Date());requireOk(sourceManifestSha256(cfg.sources)===cfg.scope.sourceManifestSha256);
 requireOk(cfg.scope.phase==='fresh'?cfg.priorRuntimePassword===null:typeof cfg.priorRuntimePassword==='string'&&cfg.priorRuntimePassword.length>0);
 const installed=JSON.parse(await readFile(new URL('./guest-sources.json',import.meta.url),'utf8'));requireOk(sourceManifestSha256(installed)===sourceManifestSha256(cfg.sources));
 // These are actual TLS errors against the same endpoint/certificate. The
 // hostname negative runs Node's default checker with a deliberately wrong host;
 // pg replaces ssl.servername, so changing that option alone is insufficient.
 await refused(cfg.scope.owner,cfg.ownerPassword,'hostname',['ERR_TLS_CERT_ALTNAME_INVALID']);checks.push('wrong_hostname_tls_refused');
 await refused(cfg.scope.owner,cfg.ownerPassword,'ca',['DEPTH_ZERO_SELF_SIGNED_CERT','SELF_SIGNED_CERT_IN_CHAIN','UNABLE_TO_VERIFY_LEAF_SIGNATURE','UNABLE_TO_GET_ISSUER_CERT_LOCALLY']);checks.push('wrong_ca_tls_refused');
 if(cfg.scope.phase==='restored'){
  const prior=await connect(cfg.scope.runtimeRole,cfg.priorRuntimePassword);
  try{await readiness(prior);}finally{await prior.end();}
  checks.push('seed_version_fresh_tls_readiness_BEFORE_bootstrap_or_rotation');
  await request({operation:'restored-auth'});
 }
 owner=await connect(cfg.scope.owner,cfg.ownerPassword);
 let previous=cfg.priorRuntimePassword;
 const receipt=await runActualRdsGuest(cfg.scope,{
  owner,sources:cfg.sources,now:()=>new Date(),
  async bootstrap(file){deadline();await request({operation:'bootstrap',file});},
  async runtimeCredentials(phase){
   deadline();const response=await request({operation:'runtime',phase});
   requireOk(typeof response.password==='string'&&response.password.length>=32&&!/[\r\n\0]/.test(response.password)&&/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(response.rotationId));
   if(previous!==null){requireOk(response.password!==previous);await refused(cfg.scope.runtimeRole,previous,undefined,['28P01']);checks.push('old_'+phase+'_password_exact_28P01');}
   previous=response.password;
   return {role:cfg.scope.runtimeRole,rotationId:response.rotationId,connect:()=>connect(cfg.scope.runtimeRole,response.password)};
  }
 });
 owner=undefined; // Library closes it even on failed SQL/readiness.
 requireOk(receipt.ok===true&&receipt.phase==='sql_verified_awaiting_parent_retirement'&&receipt.runtimeRotationIds.length===2);
 const published=await request({operation:'publish',receipt,checks});
 requireOk(typeof published.persistedPassword==='string'&&published.persistedPassword===previous&&published.secretRef&&typeof published.secretRef.arn==='string'&&/^[a-f0-9-]{36}$/.test(published.secretRef.versionId));
 const verified=await connect(cfg.scope.runtimeRole,published.persistedPassword);
 try{await readiness(verified);}finally{await verified.end();}
 checks.push('exact_persisted_version_fresh_tls_readiness');
 send({operation:'result',ok:true,receipt,checks,secretRef:published.secretRef});complete=true;
}catch{
 send({operation:'result',ok:false,code:'guest_transport_failed',checks});
}finally{
 if(owner)try{await owner.end();}catch{complete=false;}
 reader.close();process.stdin.pause();
}
if(!complete)process.exitCode=1;
