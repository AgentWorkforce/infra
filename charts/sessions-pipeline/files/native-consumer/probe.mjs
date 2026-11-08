import { existsSync } from 'node:fs';
const mode = process.argv[2];
const file = process.env.CONSUMER_UNHEALTHY_FILE;
if (!file || !file.startsWith('/tmp/') || file.includes('..')) process.exit(1);
if (!['ready', 'live'].includes(mode) || process.env.RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER !== 'true' || existsSync(file)) process.exit(1);
const port = process.env.WORKER_HEALTH_PORT;
if (!/^[0-9]+$/.test(port || '')) process.exit(1);
fetch(`http://127.0.0.1:${port}/${mode === 'ready' ? 'readyz' : 'healthz'}`, { signal: AbortSignal.timeout(1500) })
  .then(async r => { const v = await r.json(); process.exit(r.ok && v.ok === true && v.dormant !== true && v.enabled !== false && !existsSync(file) ? 0 : 1); })
  .catch(() => process.exit(1));
