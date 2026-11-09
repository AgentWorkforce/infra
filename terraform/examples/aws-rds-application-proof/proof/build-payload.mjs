/** Build only. No database, cloud credential/API or image publication. */
import {parseArgs} from 'node:util';
import {createHash,X509Certificate} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {readFileSync,writeFileSync,existsSync,mkdirSync,realpathSync} from 'node:fs';
import {dirname,resolve,join,relative} from 'node:path';
import {fileURLToPath} from 'node:url';
const here=dirname(fileURLToPath(import.meta.url)),repo=resolve(here,'../../../..');
const {values:v}=parseArgs({options:{source:{type:'string'},output:{type:'string'},ca:{type:'string'},'ca-sha256':{type:'string'},'wrong-ca':{type:'string'},commit:{type:'string'},artifact:{type:'string'},'test-only-dirty':{type:'boolean',default:false}}});
const requireOk=(yes,code)=>{if(!yes)throw new Error(code);};const sha=b=>createHash('sha256').update(b).digest('hex');
requireOk(process.versions.node.split('.')[0]==='24'&&v.source&&v.output&&v.ca&&v['ca-sha256']&&v['wrong-ca']&&v.commit&&v.artifact,'explicit_build_inputs_required');
const git=(...args)=>execFileSync('git',args,{cwd:repo,encoding:'utf8'}).trim();
const commit=git('rev-parse','HEAD'),tree=git('rev-parse','HEAD^{tree}');const dirty=!!git('status','--porcelain');
requireOk(!dirty||v['test-only-dirty'],'commit_source_before_operational_build');
const out=resolve(v.output);requireOk(!existsSync(out),'new_output_required');
if(process.platform==='darwin')requireOk(out.startsWith('/Volumes/T7/'),'build_output_requires_T7');
function cert(path){const bytes=readFileSync(path);requireOk(bytes.length<=131072&&!bytes.includes(Buffer.from('PRIVATE KEY')),'public_certificate_only');const text=bytes.toString('utf8');const blocks=text.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g);requireOk(blocks&&blocks.length<=8&&text.replace(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g,'').trim()==='','certificate_inventory');for(const item of blocks)requireOk(new X509Certificate(item).ca,'root_ca_required');return bytes;}
const ca=cert(v.ca),wrong=cert(v['wrong-ca']);requireOk(sha(ca)===v['ca-sha256']&&sha(ca)!==sha(wrong),'explicit_ca_digest_mismatch');
const prepared=JSON.parse(execFileSync(process.execPath,[join(here,'prepare-source.mjs'),realpathSync(v.source),out,v.commit,v.artifact],{encoding:'utf8',timeout:60000,maxBuffer:4*1024*1024}));
const manifestPath=join(out,'archive-manifest.json'),m=JSON.parse(readFileSync(manifestPath));
const shipped=['guest-adapter.mjs','guest_protocol.py','secret_io.py','verify-host.py','s3_probe.py'];
for(const name of shipped){const bytes=readFileSync(join(here,name));writeFileSync(join(out,name),bytes,{mode:0o600});m.files[name]=sha(bytes);}
mkdirSync(join(out,'assets'));
for(const [name,bytes] of [['rds-ca.pem',ca],['wrong-ca.pem',wrong]]){writeFileSync(join(out,'assets',name),bytes,{mode:0o600});m.files['assets/'+name]=sha(bytes);}
const scope=relative(repo,resolve(here,'..'));
const tracked=git('ls-files','--',scope).split('\n').filter(Boolean);const sources={};for(const path of tracked)sources[path]=sha(readFileSync(join(repo,path)));
const lock=resolve(here,'../.terraform.lock.hcl');requireOk(existsSync(lock),'provider_lock_required');if(!dirty)requireOk(tracked.includes(relative(repo,lock)),'provider_lock_must_be_committed');
Object.assign(m,{format:'actual-rds-application-archive-v1',helm_commit:commit,helm_tree:tree,helm_sources:sources,provider_lock_sha256:sha(readFileSync(lock)),guest_manifest_sha256:prepared.guest_manifest_sha256,ca_sha256:sha(ca),runtime_images:{node:'node@sha256:48abc13a19400ca3985071e287bd405a1d99306770eb81d61202fb6b65cf0b57',psql:'postgres@sha256:748a18a54d3842d43bc156f0840d78029b8d349e0feca98c12b9c4ce3404a6b3'},test_only:dirty||v['test-only-dirty'],toolchain:{node:process.version}});
writeFileSync(manifestPath,JSON.stringify(m,null,2)+'\n',{mode:0o600});
requireOk(git('rev-parse','HEAD')===commit&&git('rev-parse','HEAD^{tree}')===tree&&!!git('status','--porcelain')===dirty,'build_source_moved');
for(const [path,h] of Object.entries(sources))requireOk(sha(readFileSync(join(repo,path)))===h,'build_source_bytes_moved');
const archive=out+'.tar.gz';const packed=JSON.parse(execFileSync('python3',[join(here,'archive_source.py'),out,archive],{encoding:'utf8',timeout:30000}));
const receipt={...packed,source_commit:commit,guest_source_commit:m.composition_commit,guest_manifest_sha256:m.guest_manifest_sha256,guest_generation:JSON.parse(readFileSync(join(out,'guest-sources.json'))).generation,bun_lock_sha256:m.bun_lock_sha256,provider_lock_sha256:m.provider_lock_sha256,ca_sha256:m.ca_sha256,images:m.runtime_images,archive,manifest_sha256:sha(readFileSync(manifestPath)),test_only:m.test_only};
writeFileSync(out+'.receipt.json',JSON.stringify(receipt,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(receipt));
