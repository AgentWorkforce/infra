// Transport proof against the pinned MinIO image. Credentials are ephemeral
// fixtures in the parent process environment; never print URLs or witnesses.
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

let stage = 'imports';
try {
  const root = process.argv[2]!;
  const { HistoryUploadCredentials, S3PrivacyJournalReader } = await import(pathToFileURL(join(root, 'src/history-upload/credentials.ts')).href);
  const { signV4, encodeRfc3986 } = await import(pathToFileURL(join(root, 'src/aws/sigv4.ts')).href);
  const endpoint = process.env.PROOF_ENDPOINT!;
  const creds = { accessKeyId: process.env.MINIO_ROOT_USER!, secretAccessKey: process.env.MINIO_ROOT_PASSWORD! };
  const provider = { get: async () => creds };
  const bucket = 'upload-proof';
  const region = 'us-east-1';
  const require = (ok: boolean) => { if (!ok) throw new Error('proof assertion'); };
  async function signed(method: string, key: string) {
    const url = new URL(`${endpoint}/${bucket}${key ? '/' + key.split('/').map(encodeRfc3986).join('/') : ''}`);
    return fetch(url, {method, headers: signV4({method, url, region, service:'s3', body:'', credentials:creds, now:new Date()}), redirect:'error'});
  }
  stage = 'create bucket';
  const made = await signed('PUT', '');
  if (!made.ok) { const code=(await made.text()).match(/<Code>([A-Za-z0-9_]+)<\/Code>/)?.[1] ?? 'unknown'; stage+=` (${made.status}/${code})`; require(false); }
  await made.body?.cancel();
  const vectors = JSON.parse(readFileSync(process.argv[3]!, 'utf8'));
  const body = Buffer.from(vectors.object.objectBytesBase64, 'base64');
  const digest = createHash('sha256').update(body).digest();
  const config = {mode:'on', allowlist:[], bucket, region, keyRoot:'96bulls', endpoint, internalEndpoint:endpoint,
    roleArn:null, kmsKeyArn:null, storeCredentials:creds, witnessKey:Buffer.from(process.env.PROOF_WITNESS_HEX!, 'hex'), maxObjectBytes:2097152};
  const issuer = new HistoryUploadCredentials({config, credentials:provider,
    sts:{assumeRole:async () => {throw new Error('unexpected STS');}},
    journal:new S3PrivacyJournalReader({bucket, region, credentials:provider, endpoint})});
  const tenant = {orgId:'org-synthetic', workspaceId:'ws-synthetic', userId:'user-synthetic'};
  const relative = (origin: string) => `o=${origin}/b=${vectors.object.batchSegment}/d=${digest.toString('hex').slice(0,32)}-w0.json.zst`;
  stage = 'presigned-only backend';
  let stsRefused = false;
  try {await issuer.issue(tenant,{originId:'origin-synthetic',kind:'sts'});} catch (error:any) {stsRefused=error.status===501 && error.code==='unsupported_by_backend';}
  require(stsRefused);
  async function grant(origin: string) {
    const result = await issuer.issue(tenant,{originId:origin,kind:'presigned',keys:[{key:relative(origin),sha256:digest.toString('base64')}]});
    require(result.kind==='presigned' && result.kmsKeyId===null && result.endpoint===endpoint);
    const url = result.urls[0].url;
    require(!new URL(url).searchParams.get('X-Amz-SignedHeaders')?.includes('server-side-encryption'));
    return {result, url, headers:{'content-type':'application/json','content-encoding':'zstd','if-none-match':'*',
      'x-amz-checksum-sha256':digest.toString('base64'),'x-amz-meta-relay-witness':result.witness}};
  }
  stage = 'initial conditional PUT';
  const first=await grant('origin-synthetic');
  const put=await fetch(first.url,{method:'PUT',headers:first.headers,body,redirect:'error'});
  const putStatus=put.status; require(putStatus===200); await put.body?.cancel();
  stage = 'repeat conditional PUT';
  const again=await fetch(first.url,{method:'PUT',headers:first.headers,body,redirect:'error'});
  const repeatStatus=again.status; require(repeatStatus===412); await again.body?.cancel();
  stage = 'stored encoding and witness';
  const head=await signed('HEAD',first.result.keyPrefix+relative('origin-synthetic'));
  stage+=` (status=${head.status}, encoding=${head.headers.get('content-encoding')==='zstd'}, witness=${head.headers.get('x-amz-meta-relay-witness')===first.result.witness})`;
  require(head.status===200 && head.headers.get('content-encoding')==='zstd' && head.headers.get('x-amz-meta-relay-witness')===first.result.witness);
  stage = 'checksum rejection';
  const bad=await grant('bad-checksum');
  const corrupt=Buffer.from(body); corrupt[0]^=1;
  const badPut=await fetch(bad.url,{method:'PUT',headers:bad.headers,body:corrupt,redirect:'error'});
  const badStatus=badPut.status; require(badStatus===400); await badPut.body?.cancel();
  const absent=await signed('HEAD',bad.result.keyPrefix+relative('bad-checksum')); require(absent.status===404);
  stage = 'signed conditional-header enforcement';
  const stripped=await grant('stripped-condition');
  const headers:any={...stripped.headers}; delete headers['if-none-match'];
  const unsigned=await fetch(stripped.url,{method:'PUT',headers,body,redirect:'error'});
  const strippedStatus=unsigned.status; require([400,403].includes(strippedStatus)); await unsigned.body?.cancel();
  const notWritten=await signed('HEAD',stripped.result.keyPrefix+relative('stripped-condition')); require(notWritten.status===404);
  console.log(JSON.stringify({putStatus,repeatStatus,checksumRejection:badStatus,missingSignedCondition:strippedStatus,
    witnessAndEncodingPreserved:true,noKmsHeaders:true,stsRefused}));
} catch {
  // No exception object: provider errors may contain the signed URL.
  console.error(`MinIO proof failed at ${stage}`);
  process.exitCode=1;
}
