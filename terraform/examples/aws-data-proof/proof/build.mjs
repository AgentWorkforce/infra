import { build } from 'esbuild';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const source = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
if (execFileSync('git', ['status', '--porcelain'], { encoding: 'utf8' }).trim()) throw new Error('Commit proof source before building');
mkdirSync('dist', { recursive: true });
await build({ entryPoints: ['db-proof.mjs'], outfile: 'dist/db-proof.mjs', bundle: true, platform: 'node', target: 'node24', format: 'esm', banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" } });
const host = readFileSync('verify-host.py');
writeFileSync('dist/verify-host.py', host);
const manifest = { source_sha: source, lock_sha256: hash(readFileSync('package-lock.json')), files: { 'db-proof.mjs': hash(readFileSync('dist/db-proof.mjs')), 'verify-host.py': hash(host) } };
writeFileSync('dist/manifest.json', JSON.stringify(manifest) + '\n');
// Python tar/gzip primitives make the three-member archive deterministic.
execFileSync('python3', ['-c', `import tarfile,gzip,io,pathlib
p=pathlib.Path('dist');out=io.BytesIO()
with tarfile.open(fileobj=out,mode='w',format=tarfile.USTAR_FORMAT) as t:
 for name in ['db-proof.mjs','manifest.json','verify-host.py']:
  data=(p/name).read_bytes();info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o600;info.mtime=0;t.addfile(info,io.BytesIO(data))
with (p/'payload.tar.gz').open('wb') as f:
 with gzip.GzipFile(filename='',fileobj=f,mode='wb',mtime=0) as g:g.write(out.getvalue())`]);
console.log(JSON.stringify({ ...manifest, payload_sha256: hash(readFileSync('dist/payload.tar.gz')) }));
