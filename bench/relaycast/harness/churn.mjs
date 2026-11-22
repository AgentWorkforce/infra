#!/usr/bin/env node
// Actor churn at scale: creates RCB_ACTORS minimal workspaces (one Workspace actor each, with
// agents p0 and r0), then keeps RCB_SLOTS concurrent visits going for RCB_DURATION_S. A visit
// picks the next workspace in rotation, reads back its p0->r0 conversation (on revisits the
// actor is usually dormant, so this restores it from storage) and checks that it holds every
// DM acknowledged so far, then sends RCB_MESSAGES DMs spaced over RCB_VISIT_S seconds.
// Idle hosts retire after the chart's host idle timeout, so live actors stay near the slot
// count while every actor is activated, written, retired and restored repeatedly.
//
// Env: RCB_BASE_URL, RCB_INTERNAL_SECRET_FILE, RCB_RUN, RCB_ACTORS (10000), RCB_SLOTS (200),
//      RCB_MESSAGES (3), RCB_VISIT_S (20), RCB_DURATION_S (7200), RCB_CONCURRENCY (64),
//      RCB_OUT (results JSON). Tokens stay in this process; nothing secret is written out.
import { env, envInt, httpClient, readSecretFile, writeJsonAtomic, HistMap, Counter, log, hr, sleep } from './lib.mjs';

const base = env('RCB_BASE_URL');
const internal = readSecretFile(env('RCB_INTERNAL_SECRET_FILE'));
const run = env('RCB_RUN');
const N = envInt('RCB_ACTORS', 10000);
const SLOTS = envInt('RCB_SLOTS', 200);
const MESSAGES = envInt('RCB_MESSAGES', 3);
const VISIT_MS = envInt('RCB_VISIT_S', 20) * 1000;
const DURATION_MS = envInt('RCB_DURATION_S', 7200) * 1000;
const CONC = envInt('RCB_CONCURRENCY', 64);
const OUT = env('RCB_OUT', '/work/churn.json');

const call = httpClient(base, { timeoutMs: 60000 });
const lat = new HistMap();
const status = new Counter();
const counts = { created: 0, createFailed: 0, visits: 0, revisits: 0, sent: 0, sendFailed: 0, readbacks: 0, readbackFailed: 0, missing: 0, extra: 0 };
const mismatches = [];
const started = Date.now();

async function req(route, method, path, token, body, retries = 6) {
  for (let attempt = 0; ; attempt++) {
    const r = await call(method, path, token, body);
    lat.add(route, r.ms);
    status.inc(`${route} ${r.status}`);
    if (r.status >= 200 && r.status < 300) return r.body?.data ?? r.body;
    if (attempt >= retries || !(r.status === 429 || r.status === 0 || r.status >= 500)) {
      throw new Error(`${route}: HTTP ${r.status}`);
    }
    await sleep(Math.min(20000, 500 * 2 ** attempt));
  }
}

async function pool(count, fn) {
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(CONC, count) }, async () => {
    while (i < count) { const k = i++; await fn(k); }
  }));
}

async function create(i) {
  try {
    const ws = await req('POST /internal/workspaces', 'POST', '/internal/workspaces', internal, { name: `rcb-${run}-c${i}` });
    const p0 = await req('POST /v1/agents', 'POST', '/v1/agents', ws.api_key, { name: 'p0' });
    await req('POST /v1/agents', 'POST', '/v1/agents', ws.api_key, { name: 'r0' });
    counts.created++;
    return { i, token: p0.token, acked: 0, conversation: null, visits: 0 };
  } catch (error) {
    counts.createFailed++;
    return null;
  }
}

async function readback(w) {
  if (!w.conversation) {
    const list = await req('GET /v1/dm/conversations', 'GET', '/v1/dm/conversations', w.token);
    const convs = Array.isArray(list) ? list : list?.conversations ?? [];
    w.conversation = convs[0]?.id ?? convs[0]?.conversation_id ?? null;
    if (!w.conversation) return w.acked === 0 ? 0 : -1;
  }
  const page = await req('GET /v1/dm/:id/messages', 'GET', `/v1/dm/${w.conversation}/messages?limit=200`, w.token);
  const messages = Array.isArray(page) ? page : page?.messages ?? [];
  return messages.length;
}

async function visit(w) {
  counts.visits++;
  if (w.visits > 0) {
    counts.revisits++;
    try {
      const held = await readback(w);
      counts.readbacks++;
      if (held < w.acked) { counts.missing += w.acked - held; mismatches.push({ ws: w.i, acked: w.acked, held, at: Date.now() - started }); }
      if (held > w.acked) counts.extra += held - w.acked;
    } catch {
      counts.readbackFailed++;
    }
  }
  w.visits++;
  for (let m = 0; m < MESSAGES; m++) {
    try {
      await req('POST /v1/dm', 'POST', '/v1/dm', w.token, { to: 'r0', text: `churn ${w.i} ${w.acked + 1}` }, 0);
      w.acked++;
      counts.sent++;
    } catch {
      counts.sendFailed++;
    }
    if (m + 1 < MESSAGES) await sleep(VISIT_MS / MESSAGES);
  }
}

function snapshot(phase) {
  return {
    kind: 'churn', run, phase, params: { N, SLOTS, MESSAGES, VISIT_MS, DURATION_MS, CONC },
    elapsedMs: Date.now() - started, counts, mismatches: mismatches.slice(0, 50),
    status: status.toJSON(), latency: Object.fromEntries([...lat.m].map(([k, h]) => [k, h.summary()])),
  };
}

const t0 = hr();
const workspaces = new Array(N);
const progress = setInterval(() => { log('progress', counts); writeJsonAtomic(OUT, snapshot('running')); }, 30000);
await pool(N, async (i) => { workspaces[i] = await create(i); });
const live = workspaces.filter(Boolean);
log(`created ${live.length}/${N} workspaces in ${Math.round(hr() - t0)} ms`);
writeJsonAtomic(OUT, snapshot('created'));

const deadline = Date.now() + DURATION_MS;
let next = 0;
await Promise.all(Array.from({ length: SLOTS }, async () => {
  while (Date.now() < deadline) {
    const w = live[next++ % live.length];
    if (w.busy) { await sleep(100); continue; }
    w.busy = true;
    try { await visit(w); } finally { w.busy = false; }
  }
}));

// Final pass: every workspace's conversation must hold every acknowledged DM.
await pool(live.length, async (k) => {
  const w = live[k];
  if (w.acked === 0) return;
  try {
    const held = await readback(w);
    counts.readbacks++;
    if (held < w.acked) { counts.missing += w.acked - held; mismatches.push({ ws: w.i, acked: w.acked, held, final: true }); }
  } catch {
    counts.readbackFailed++;
  }
});
clearInterval(progress);
counts.touched = live.filter((w) => w.visits > 0).length;
writeJsonAtomic(OUT, snapshot('done'));
log('churn done', counts);
