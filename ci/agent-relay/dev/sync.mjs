import { lstat, mkdir, rename, rm, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export function allowed(path) {
  return typeof path === 'string' && !path.startsWith('/') &&
    !path.split('/').some(x => !x || x === '.' || x === '..' || x.startsWith('.') || x === 'node_modules') &&
    (path.startsWith('src/') || path.startsWith('public/') ||
     ['index.html', 'vite.config.ts', 'vite.config.js'].includes(path) || /^tsconfig[^/]*\.json$/.test(path));
}

export function validate(input) {
  if (!input || typeof input.files !== 'object' || Array.isArray(input.files) || !input.files ||
      !Array.isArray(input.removed) || Object.keys(input.files).length > 5000) throw new Error('sync_shape');
  let bytes = 0;
  for (const [path, data] of Object.entries(input.files)) {
    if (!allowed(path) || typeof data !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(data))
      throw new Error('sync_path_or_encoding');
    bytes += Buffer.byteLength(data, 'base64');
  }
  if (bytes > 24 * 1024 * 1024 || input.removed.some(p => !allowed(p) || p in input.files)) throw new Error('sync_bound');
  return input;
}

async function destination(path) {
  const full = resolve('/devsrc', path);
  // Refuse symlink ancestors/targets, including ones created by application code.
  let current = '/devsrc';
  for (const part of path.split('/')) {
    current += '/' + part;
    try { if ((await lstat(current)).isSymbolicLink()) throw new Error('sync_symlink'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  return full;
}

async function main() {
  const chunks = []; let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > 32 * 1024 * 1024) throw new Error('sync_input_bound');
    chunks.push(chunk);
  }
  const input = validate(JSON.parse(Buffer.concat(chunks).toString('utf8')));
  for (const [path, data] of Object.entries(input.files)) {
    const full = await destination(path);
    await mkdir(dirname(full), { recursive: true });
    const tmp = full + '.kind-dev-' + process.pid;
    await writeFile(tmp, Buffer.from(data, 'base64'), { mode: 0o644, flag: 'wx' });
    await rename(tmp, full);
  }
  for (const path of input.removed) await rm(await destination(path), { force: true });
  console.log(JSON.stringify({ files: Object.keys(input.files).length, removed: input.removed.length }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  main().catch(() => { console.error('kind-dev source sync refused'); process.exit(1); });
