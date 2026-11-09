/** Installed source only: no SQL clients/connections, fixture or AWS calls. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import * as driver from './source/src/hoopdb/rds-activation.ts';
import { generation, plan } from './source/src/hoopdb/migrate.ts';
assert.equal(process.versions.node.split('.')[0], '24');
const manifest=JSON.parse(await readFile(new URL('./guest-sources.json',import.meta.url),'utf8'));
assert.equal(await generation(),manifest.generation);
for (const [name,expected] of Object.entries(manifest.files)) {
  assert.equal(createHash('sha256').update(await readFile(new URL('./source/'+name,import.meta.url))).digest('hex'),expected);
}
assert.equal(driver.CONTRACT,manifest.contract);
assert.equal(driver.artifactIdentity().artifact_sha256,manifest.artifactSha256);
const steps=await plan({mode:'rds',shim:false,bootstrap:false,verify:true,runtimeRole:'sessions_pipeline_runtime',runtimeLogin:true,functionBoundary:'global-default-revoke'});
assert(steps.length>0 && steps.every(s=>!s.name.startsWith('shim:')));
await assert.rejects(import('@rhc/unapproved'),/guest_alias_refused/);
await assert.rejects(import('@rhc/lib/scrub.ts'),/guest_alias_refused/); // Valid alias from wrong parent is also refused.
console.log(JSON.stringify({ok:true,scope:'installed driver/migrator import and source-assets only; no database/cloud',node:process.version,platform:process.platform,arch:process.arch,generation:manifest.generation,source_files:Object.keys(manifest.files).length,plan_steps:steps.length,unknown_alias_and_wrong_parent_refused:true}));
