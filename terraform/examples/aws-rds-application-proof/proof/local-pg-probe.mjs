/** SYNTHETIC LOCAL IO ONLY. Never invokes actual-RDS library or migrations. */
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require=createRequire(new URL('./package.json',import.meta.url));
const {Client}=require('pg');
const v=JSON.parse(readFileSync(0,'utf8'));
const c=new Client({host:v.wrongHostname?'rds-prep-wrong':'rds-prep-db',port:5432,database:'postgres',user:'proof_runtime',password:v.password,ssl:{ca:v.ca,rejectUnauthorized:true,servername:v.wrongHostname?'rds-prep-wrong':'rds-prep-db'},connectionTimeoutMillis:5000,query_timeout:5000,statement_timeout:5000});
let result;
try {
 await c.connect();
 const row=(await c.query("SELECT current_user AS role,coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),false) AS tls")).rows[0];
 assert.deepEqual(row,{role:'proof_runtime',tls:true});result={ok:true,authenticated:true,node:process.version,arch:process.arch,platform:process.platform};
}catch(error){result={ok:false,code:typeof error.code==='string'?error.code:'local_probe_failed'};}
finally {try{await c.end();}catch{result={ok:false,code:'local_close_failed'};}}
console.log(JSON.stringify(result));
