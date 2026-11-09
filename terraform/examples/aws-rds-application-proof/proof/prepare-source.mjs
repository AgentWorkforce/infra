/** Source-only preparation. No secret loader, DB connection, Docker or cloud. */
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {createRequire} from 'node:module';
import {existsSync,lstatSync,mkdirSync,readFileSync,readdirSync,realpathSync,writeFileSync} from 'node:fs';
import {dirname,join,relative,resolve,sep} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';

const CONTRACT='rds-activation/v1';
// Entry points whose relative-import closure ships; the alias target is added by name.
// Non-TypeScript files the migrator reads at runtime outside the listed SQL directories.
const RUNTIME_ASSETS=['src/hoopdb/sessions-function-acl.json'];
const ENTRY=['src/hoopdb/rds-activation.ts','src/hoopdb/migrate.ts','src/shared/db.ts','packages/pipeline/src/lib/scrub.ts'];
const here=dirname(fileURLToPath(import.meta.url));
const hash=b=>createHash('sha256').update(b).digest('hex');
const requireInvariant=(v,code)=>{if(!v)throw new Error(code);};
requireInvariant(process.versions.node.split('.')[0]==='24','source_node24_required');
requireInvariant(process.argv.length===6,'usage_source_root_NEW_output_commit_artifact');
const source=realpathSync(process.argv[2]),out=resolve(process.argv[3]);
const EXPECTED=process.argv[4],ARTIFACT=process.argv[5];
requireInvariant(/^[a-f0-9]{40}$/.test(EXPECTED)&&/^[a-f0-9]{64}$/.test(ARTIFACT),'source_pin_shape');
if(process.platform==='darwin')requireInvariant(out.startsWith('/Volumes/T7/'),'output_requires_T7');
requireInvariant(!existsSync(out),'output_must_be_new');
const git=(...a)=>execFileSync('git',a,{cwd:source,encoding:'utf8',maxBuffer:16*1024*1024}).trim();
const clean=()=>{requireInvariant(git('rev-parse','HEAD')===EXPECTED,'unexpected_guest_commit');requireInvariant(!git('status','--porcelain','--untracked-files=normal'),'guest_tree_dirty');};
clean();
mkdirSync(out,{recursive:true,mode:0o700});
// Preparation hook is outside the archive, and cannot affect the source checkout.
const prepHook=out+'.prepare-hook.mjs';
writeFileSync(prepHook,`import {install} from ${JSON.stringify(pathToFileURL(join(here,'register.mjs')).href)};install(new URL(${JSON.stringify(pathToFileURL(source+sep).href)}));\n`,{mode:0o600});
const capture=`const d=await import(${JSON.stringify(pathToFileURL(join(source,'src/hoopdb/rds-activation.ts')).href)});const m=await import(${JSON.stringify(pathToFileURL(join(source,'src/hoopdb/migrate.ts')).href)});const c=await import(${JSON.stringify(pathToFileURL(join(source,'src/hoopdb/session-bootstrap-chain.ts')).href)});const id=d.artifactIdentity();const spec=d.parseRoleSpec(d.roleSpecSources());console.log(JSON.stringify({contract:id.contract,artifactSha256:id.artifact_sha256,artifactFiles:id.artifact_files.map(f=>f[0]),generation:await m.generation(),bootstrapChain:c.SESSION_BOOTSTRAP_FILES,loginRoles:spec.filter(r=>r.login).map(r=>r.name)}));`;
const captured=JSON.parse(execFileSync(process.execPath,['--experimental-transform-types','--import',prepHook,'--input-type=module','-e',capture],{cwd:source,encoding:'utf8',timeout:30000,maxBuffer:4*1024*1024}).trim().split('\n').at(-1));
requireInvariant(captured.contract===CONTRACT&&captured.artifactSha256===ARTIFACT,'activation_artifact_changed');
// Only the exact relative-import closure of the entry points ships.
const closure=new Set();
function follow(name){
 if(closure.has(name))return;requireInvariant(existsSync(join(source,name)),'closure_source_missing');closure.add(name);
 const text=readFileSync(join(source,name),'utf8').split('\n').map(line=>line.replace(/^\s*(\/\/|\*|\/\*).*$/,'')).join('\n');
 for(const match of text.matchAll(/(?:^|[;\n])\s*(import|export)\s+(type\s+)?(?:[^'";]*?\sfrom\s+)?["']([^"']+)["']/g)){
  const specifier=match[3];if(match[2])continue;
  if(specifier.startsWith('./')||specifier.startsWith('../'))follow(relative(source,resolve(dirname(join(source,name)),specifier)));
  else requireInvariant(specifier.startsWith('node:')||specifier==='pg'||specifier==='@rhc/lib/scrub.ts','unreviewed_runtime_import');
 }
}
ENTRY.forEach(follow);
const listSql=dir=>readdirSync(join(source,dir),{recursive:true}).map(String).filter(f=>f.endsWith('.sql')).sort().map(f=>dir+'/'+f);
const shipped=[...new Set([...closure,...captured.artifactFiles,...listSql('supabase/bootstrap'),...listSql('supabase/migrations'),...listSql('src/hoopdb/migrations'),...RUNTIME_ASSETS,'tsconfig.json','bun.lock'])].sort();
requireInvariant(captured.bootstrapChain.every(name=>shipped.includes(name)),'bootstrap_chain_not_shipped');
const sourceFiles={};for(const name of shipped)sourceFiles[name]=hash(readFileSync(join(source,name)));
const manifest={compositionCommit:EXPECTED,contract:CONTRACT,artifactSha256:ARTIFACT,generation:captured.generation,bootstrapChain:captured.bootstrapChain,loginRoles:captured.loginRoles,files:sourceFiles};
const manifestSha256=hash(JSON.stringify(manifest));
const files={};
function put(name,bytes){requireInvariant(!name.startsWith('/')&&!name.split('/').includes('..')&&!files[name],'unsafe_duplicate_archive_path');mkdirSync(dirname(join(out,name)),{recursive:true});writeFileSync(join(out,name),bytes,{mode:0o600});files[name]=hash(bytes);}
for(const name of shipped){
 requireInvariant(name!=='scripts/pg-proof/rds-profile-proof.ts','emulation_must_not_ship');
 const path=join(source,name);requireInvariant(lstatSync(path).isFile()&&!lstatSync(path).isSymbolicLink(),'source_not_regular');put('source/'+name,readFileSync(path));
}
put('guest-sources.json',Buffer.from(JSON.stringify(manifest)+'\n'));
for(const name of ['register.mjs','runtime-hook.mjs','import-check.mjs'])put(name,readFileSync(join(here,name)));
// Bun's lock stores package records on individual JSON lines. Parse only those
// exact records with JSON.parse; never evaluate text or invent an npm lock.
const lock=readFileSync(join(source,'bun.lock'),'utf8');const records=[];
for(const line of lock.split('\n'))if(/^\s*"[^"\n]+": \[/.test(line)){
 const pair=JSON.parse('{'+line.trim().replace(/,$/,'')+'}');records.push(Object.values(pair)[0]);
}
const packages={};
function packageRoot(request,name){
 let entry;try{entry=request.resolve(name+'/package.json');}catch{entry=request.resolve(name);}
 let folder=dirname(entry);
 while(folder!==dirname(folder)){
  const file=join(folder,'package.json');if(existsSync(file)&&JSON.parse(readFileSync(file)).name===name)return realpathSync(folder);
  folder=dirname(folder);
 }
 throw new Error('dependency_package_missing');
}
function dependency(request,name){
 const folder=packageRoot(request,name);requireInvariant(folder.startsWith(source+sep+'node_modules'+sep),'dependency_outside_own_install');
 const pkg=JSON.parse(readFileSync(join(folder,'package.json')));requireInvariant(pkg.name===name&&typeof pkg.version==='string','invalid_dependency_identity');
 const record=records.filter(r=>r[0]===name+'@'+pkg.version);requireInvariant(record.length===1&&/^sha512-/.test(record[0][3]),'dependency_not_exactly_in_bun_lock');
 if(packages[name]){requireInvariant(packages[name].version===pkg.version,'flat_dependency_version_conflict');return;}
 packages[name]={version:pkg.version,lock_integrity:record[0][3]};
 const local=createRequire(join(folder,'package.json'));
 for(const dep of Object.keys(pkg.dependencies||{}))dependency(local,dep);
 for(const dep of Object.keys(pkg.optionalDependencies||{})){
  try{local.resolve(dep);}catch{continue;}dependency(local,dep);
 }
 function walk(path,prefix=''){
  for(const leaf of readdirSync(path).sort()){
   if(leaf==='node_modules')continue;
   const abs=join(path,leaf),rel=prefix+leaf,st=lstatSync(abs);requireInvariant(!st.isSymbolicLink(),'package_symlink_refused');
   if(st.isDirectory())walk(abs,rel+'/');else {requireInvariant(st.isFile(),'package_special_file_refused');put('node_modules/'+name+'/'+rel,readFileSync(abs));}
  }
 }
 walk(folder);
}
dependency(createRequire(join(source,'package.json')),'pg');
requireInvariant(packages.pg.version==='8.23.1','pg_version_changed');
clean();
const outer={format:'actual-rds-source-archive-v1',composition_commit:EXPECTED,composition_tree:git('rev-parse','HEAD^{tree}'),bun_lock_sha256:hash(Buffer.from(lock)),packages,files};
writeFileSync(join(out,'archive-manifest.json'),JSON.stringify(outer,null,2)+'\n',{mode:0o600});
console.log(JSON.stringify({ok:true,scope:'source preparation only; installed execution still required',output:out,source_commit:EXPECTED,artifact_sha256:ARTIFACT,generation:captured.generation,login_roles:captured.loginRoles.length,pg:packages.pg.version,packages:Object.keys(packages).length,files:Object.keys(files).length,manifest_sha256:hash(readFileSync(join(out,'archive-manifest.json'))),guest_manifest_sha256:manifestSha256}));
