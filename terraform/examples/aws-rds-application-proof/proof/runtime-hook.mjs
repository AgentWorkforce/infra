import { closeSync, readSync } from 'node:fs';
import { install } from './register.mjs';
install(new URL('./source/', import.meta.url));
// Secret-bearing URL for the unchanged migrator: read once from a private pipe, so it is
// never in this process's initial environment or argv. Absent marker: nothing to do.
const marker = process.env.HOOPDB_URL_FD;
if (marker !== undefined) {
  if (!/^[3-9]$/.test(marker) || process.env.HOOPDB_URL !== undefined) throw new Error('guest_url_channel_refused');
  const fd = Number(marker), chunks = [], end = Date.now() + 10000;
  for (;;) {
    const chunk = Buffer.alloc(4096);
    let count;
    try { count = readSync(fd, chunk, 0, chunk.length, null); } catch (error) {
      if (error.code !== 'EAGAIN' || Date.now() > end) throw new Error('guest_url_channel_refused');
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
      continue;
    }
    if (count === 0) break;
    chunks.push(chunk.subarray(0, count));
    if (chunks.reduce((n, c) => n + c.length, 0) > 8192) throw new Error('guest_url_channel_refused');
  }
  closeSync(fd);
  const url = Buffer.concat(chunks).toString('utf8');
  if (!url.startsWith('postgres://')) throw new Error('guest_url_channel_refused');
  delete process.env.HOOPDB_URL_FD;
  process.env.HOOPDB_URL = url;
}
