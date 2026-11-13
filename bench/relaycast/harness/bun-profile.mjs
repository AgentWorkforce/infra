// Samples a running Bun process through its inspector (WebKit protocol) and
// prints where CPU time goes. Runs with `bun` INSIDE the actor host pod
// (the inspector listens on 127.0.0.1 only; kubectl exec, no port exposure):
//
//   bun /tmp/bun-profile.mjs <ws-url> <seconds> > profile.json
//
// The actor process must start with BUN_OPTIONS="--inspect=127.0.0.1:6499/rcb"
// (relaycast-actor-env). Output JSON: samples, wall window, self and inclusive
// time per function (top 60), self time by category (sqlite, json, crypto,
// storage/S3 I/O, network, relaycast engine, runtime/GC/idle), and GC events
// from the Heap domain (count, total ms, max ms).
const [url, secondsArg] = process.argv.slice(2);
const seconds = Number(secondsArg || 60);
const ws = new WebSocket(url);
let id = 0;
const pending = new Map();
const gcs = [];
let tracking = null;
const send = (method, params = {}) => new Promise((resolve) => { const i = ++id; pending.set(i, resolve); ws.send(JSON.stringify({ id: i, method, params })); });
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); return; }
  if (m.method === 'Heap.garbageCollected') gcs.push(m.params.collection);
  if (m.method === 'ScriptProfiler.trackingComplete') tracking?.(m.params);
};
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
await send('Heap.enable');
await send('ScriptProfiler.startTracking', { includeSamples: true });
const t0 = Date.now();
await new Promise((r) => setTimeout(r, seconds * 1000));
const done = new Promise((r) => { tracking = r; });
await send('ScriptProfiler.stopTracking');
const params = await Promise.race([done, new Promise((r) => setTimeout(() => r(null), 30000))]);
const wallMs = Date.now() - t0;
ws.close();

const traces = params?.samples?.stackTraces || [];
const self = new Map(); const incl = new Map(); const cat = new Map();
const category = (f) => {
  const s = `${f.name} ${f.url}`.toLowerCase();
  if (/sqlite|sql|prepare|statement|\bdb\b|drizzle/.test(s)) return 'sqlite/sql';
  if (/json|stringify|parse/.test(s)) return 'json';
  if (/crypto|sha|hmac|hash|random|uuid/.test(s)) return 'crypto/hash';
  if (/s3|storage|state|kv|commit|snapshot|publish/.test(s)) return 'actor state/storage';
  if (/fetch|http|socket|websocket|net|tls/.test(s)) return 'network';
  if (/relaycast|engine|deliver|mailbox|fanout|message|channel/.test(s)) return 'relaycast engine';
  if (!f.url) return 'runtime/native';
  return 'other js';
};
const key = (f) => `${f.name || '(anonymous)'} ${String(f.url || '').split('/').slice(-2).join('/')}:${f.line ?? ''}`;
// Samples are taken every interval; each counts as one tick of the interval.
let interval = 1;
if (traces.length > 1) interval = Math.max(0.0001, (traces[traces.length - 1].timestamp - traces[0].timestamp) / (traces.length - 1));
for (const t of traces) {
  const fr = t.stackFrames || [];
  if (!fr.length) { self.set('(idle)', (self.get('(idle)') || 0) + 1); cat.set('idle', (cat.get('idle') || 0) + 1); continue; }
  const top = fr[0];
  self.set(key(top), (self.get(key(top)) || 0) + 1);
  const c = category(top); cat.set(c, (cat.get(c) || 0) + 1);
  for (const k of new Set(fr.map(key))) incl.set(k, (incl.get(k) || 0) + 1);
}
const ms = (n) => +(n * interval * 1000).toFixed(1);
const top = (m) => [...m].sort((a, b) => b[1] - a[1]).slice(0, 60).map(([k, n]) => ({ fn: k, samples: n, ms: ms(n), pct: +(100 * n / Math.max(traces.length, 1)).toFixed(1) }));
const gcMs = gcs.map((g) => (g.endTime - g.startTime) * 1000);
console.log(JSON.stringify({
  wallMs, samples: traces.length, sampleIntervalMs: +(interval * 1000).toFixed(3),
  byCategory: Object.fromEntries([...cat].sort((a, b) => b[1] - a[1]).map(([k, n]) => [k, { samples: n, ms: ms(n), pct: +(100 * n / Math.max(traces.length, 1)).toFixed(1) }])),
  selfTop: top(self), inclusiveTop: top(incl),
  gc: { count: gcs.length, totalMs: +gcMs.reduce((a, b) => a + b, 0).toFixed(1), maxMs: +Math.max(0, ...gcMs).toFixed(1),
    full: gcs.filter((g) => g.type === 'full').length },
}));
