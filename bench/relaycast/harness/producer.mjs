#!/usr/bin/env node
// Open-loop load producer. Runs the phases of a plan (RCB_PLAN, a JSON file)
// against the fixture, shard RCB_SHARD of RCB_SHARDS (each shard owns every
// RCB_SHARDS-th producer agent and sends rate/RCB_SHARDS).
//
// Open loop: sends are scheduled at the target rate whether or not earlier
// ones finished, so a slow server shows up as latency (measured from the
// intended send time, "corrected") instead of as a lower offered rate. Each
// stream (producer -> DM peer, or producer -> channel) has at most one request
// in flight, so per-stream ordering at the receiver is meaningful; streams
// are many, so concurrency is not capped by that.
//
// Phase kinds (fields: label, kind, durationS, rate, sizeBytes, burst):
//   dm | channel | mixed (dmShare) | fanout | broadcast (targets) | upload
//   | replay (profile, scale, basis: rps_peak_minute_max|rps_peak_hour|rps_avg)
//   | backlog (DMs to offline backlog receivers) | idle (only waits)
// burst: {periodS, lenS, factor} multiplies the rate inside each window.
import { readFileSync } from 'node:fs';
import http from 'node:http';
import { env, envInt, httpClient, HistMap, Counter, marker, log, hr, now, sleep, writeJsonAtomic } from './lib.mjs';

const fixture = JSON.parse(readFileSync(env('RCB_FIXTURE'), 'utf8'));
const plan = JSON.parse(readFileSync(env('RCB_PLAN'), 'utf8'));
const SHARD = envInt('RCB_SHARD', 0);
const SHARDS = envInt('RCB_SHARDS', 1);
const MAX_INFLIGHT = envInt('RCB_MAX_INFLIGHT', 8192);
const QUEUE_CAP = envInt('RCB_STREAM_QUEUE_CAP', 2000);
const OUT = env('RCB_OUT', '');
// Sink control URLs (comma separated, e.g. http://sink-0.sink:9090); shard 0
// takes the backlog receivers offline and back online around backlog phases.
const SINKS = env('RCB_SINK_URLS', '').split(',').filter(Boolean);
// /status for the coordinator, which times chaos actions against the phase clock.
const STATUS_PORT = envInt('RCB_STATUS_PORT', 0);
const progress = { phase: null, phaseStartedAt: null, done: false, completed: [] };
if (STATUS_PORT) {
  http.createServer((req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    // /result: the full result (histograms and stream accounting) for the coordinator.
    res.end(JSON.stringify(req.url.startsWith('/result') ? result() : { ...progress, now: Date.now(), inflight }));
  }).listen(STATUS_PORT).unref();
}
async function sinkControl(action, agents) {
  const out = [];
  for (const u of SINKS) {
    try { const r = await fetch(`${u}/${action}?agents=${agents.join(',')}`, { method: 'POST', signal: AbortSignal.timeout(120000) }); out.push(await r.json()); }
    catch (e) { out.push({ error: e.message }); }
  }
  return out;
}
const call = httpClient(fixture.baseUrl, { timeoutMs: envInt('RCB_TIMEOUT_MS', 30000) });

// Producers owned by this shard.
const mine = [];
let g = 0;
for (const ws of fixture.workspaces) for (const p of ws.producers) { if (g++ % SHARDS === SHARD) mine.push({ ws, p, id: `${ws.i}.${p.name}` }); }
if (!mine.length) { log(`shard ${SHARD}: no producers`); }

const lat = new HistMap(); // `${phase} ${route}` raw (from actual send)
const latC = new HistMap(); // corrected (from intended time)
const status = new Counter();
const streamState = new Map(); // `${producer}|${stream}` -> {seq, failed:[], ambiguous:[], targets, queue:[], busy}
// Recent channel-message and DM-conversation ids per workspace, so replayed
// reads target objects the calling agent can see.
const recentByWs = new Map();
const recentOf = (wsI) => { let r = recentByWs.get(wsI); if (!r) recentByWs.set(wsI, (r = { msgIds: [], convIds: new Map() })); return r; };
let inflight = 0;

// Streams are per phase, so separate producer runs never reuse a sequence.
function stream(prod, kind, target, targets, phase) {
  const sid = `${phase}/${kind}:${target}`;
  const key = `${prod.id}|${sid}`;
  let s = streamState.get(key);
  if (!s) streamState.set(key, (s = { key, sid, prod, kind, target, ws: prod.ws.i, targets, seq: 0, failed: [], ambiguous: [], pending: new Set(), queue: [], busy: false, phase: null }));
  return s;
}

const routeOf = { dm: 'POST /v1/dm', channel: 'POST /v1/channels/:name/messages' };

async function sendOn(s, phase, intended, sizeBytes) {
  s.busy = true; inflight++;
  const seq = ++s.seq;
  s.pending.add(seq); // in flight: ambiguous if the result is read before it settles
  const sent = now();
  const text = marker(phase, s.prod.id, s.sid, seq, sent, sizeBytes);
  const r = s.kind === 'dm'
    ? await call('POST', '/v1/dm', s.prod.p.token, { to: s.target, text })
    : await call('POST', `/v1/channels/${s.target}/messages`, s.prod.p.token, { text });
  const route = routeOf[s.kind];
  lat.add(`${phase} ${route}`, r.ms);
  latC.add(`${phase} ${route}`, now() - intended);
  status.inc(`${phase} ${route} ${r.status}`);
  if (r.status === 201) {
    const recent = recentOf(s.ws);
    if (s.kind === 'channel' && r.body?.data?.id) {
      if (recent.msgIds.length < 2000) recent.msgIds.push(r.body.data.id); else recent.msgIds[seq % 2000] = r.body.data.id;
    }
    const conv = r.body?.data?.conversation_id;
    if (conv) recent.convIds.set(s.prod.id, conv);
    if (r.body?.data?.deliveries_truncated === false) {
      const skipped = (r.body.data.deliveries || []).filter((d) => d.status !== 'queued').length;
      if (skipped) status.inc(`${phase} delivery_not_queued`, skipped);
    }
  } else if (r.status === 0) s.ambiguous.push(seq); else s.failed.push(seq);
  s.pending.delete(seq);
  inflight--; s.busy = false;
  const next = s.queue.shift();
  if (next) sendOn(s, next.phase, next.intended, next.sizeBytes);
}

function enqueue(s, phase, intended, sizeBytes) {
  s.phase = s.phase || phase;
  if (!s.busy && inflight < MAX_INFLIGHT) { sendOn(s, phase, intended, sizeBytes); return; }
  if (s.queue.length >= QUEUE_CAP) { status.inc(`${phase} client_overflow`); return; }
  s.queue.push({ phase, intended, sizeBytes });
}

const pick = (arr, i) => arr[i % arr.length];
let rr = 0;

function dmStreams(phase) {
  // Each producer DMs receivers of its own workspace, rotating.
  return mine.flatMap((m) => m.ws.receivers.map((r) => () => stream(m, 'dm', r, [r], phase)));
}
function channelStreams(fanoutOnly, phase) {
  return mine.flatMap((m) => m.ws.channels.filter((c) => !!c.fanout === !!fanoutOnly).map((c) => () => stream(m, 'channel', c.name, c.members, phase)));
}

async function runRate(ph, emit) {
  const start = hr();
  const end = start + ph.durationS * 1000;
  const shardRate = ph.rate / SHARDS;
  let issued = 0; let virt = 0; let last = start;
  while (true) {
    const t = hr();
    if (t >= end) break;
    let mult = 1;
    if (ph.burst) { const inCycle = ((t - start) / 1000) % ph.burst.periodS; if (inCycle < ph.burst.lenS) mult = ph.burst.factor; }
    virt += ((t - last) / 1000) * shardRate * mult; last = t;
    const due = Math.floor(virt) - issued;
    const wall = now();
    for (let k = 0; k < due; k++) emit(wall - ((due - 1 - k) / Math.max(shardRate * mult, 1)) * 1000);
    issued += Math.max(due, 0);
    await sleep(2);
  }
  return issued;
}

async function upload(ph, intended) {
  const m = pick(mine, rr++);
  const size = ph.sizeBytes || 65536;
  const steps = [
    ['POST /v1/files/upload', () => call('POST', '/v1/files/upload', m.p.token, { filename: 'bench.bin', content_type: 'application/octet-stream', size_bytes: size })],
  ];
  inflight++;
  const t0 = now();
  let r = await steps[0][1]();
  lat.add(`${ph.label} ${steps[0][0]}`, r.ms); status.inc(`${ph.label} ${steps[0][0]} ${r.status}`);
  if (r.status === 201) {
    const { id, upload_url: u } = r.body.data;
    const putUrl = u.replace(/^https?:\/\/[^/]+/, fixture.baseUrl);
    const tp = hr();
    let ps = 0;
    try { ps = (await fetch(putUrl, { method: 'PUT', body: new Uint8Array(size), signal: AbortSignal.timeout(60000) })).status; } catch { ps = 0; }
    lat.add(`${ph.label} PUT /_relayfiles`, hr() - tp); status.inc(`${ph.label} PUT /_relayfiles ${ps}`);
    r = await call('POST', `/v1/files/${id}/complete`, m.p.token);
    lat.add(`${ph.label} POST /v1/files/:id/complete`, r.ms); status.inc(`${ph.label} POST /v1/files/:id/complete ${r.status}`);
    latC.add(`${ph.label} upload_total`, now() - intended);
  }
  lat.add(`${ph.label} upload_total_raw`, now() - t0);
  inflight--;
}

// Production replay: route templates mapped to concrete calls. Routes the
// harness cannot reproduce safely are listed as skipped with their share.
function replayCalls(m) {
  const tok = m.p.token; const key = m.ws.key;
  const recent = recentOf(m.ws.i);
  const anyMsg = () => recent.msgIds[(Math.random() * recent.msgIds.length) | 0];
  const anyConv = () => recent.convIds.get(m.id);
  const rcv = pick(m.ws.receivers, rr++);
  const ch = pick(m.ws.channels.filter((c) => !c.fanout), rr);
  return {
    'GET /v1/deliveries': () => call('GET', '/v1/deliveries?limit=50', tok),
    'POST /v1/agents/heartbeat': () => call('POST', '/v1/agents/heartbeat', tok, {}),
    'GET /v1/messages/:id/replies': () => { const id = anyMsg(); return id && call('GET', `/v1/messages/${id}/replies`, tok); },
    'GET /v1/agents/:id': () => call('GET', `/v1/agents/${m.p.name}`, key),
    'GET /v1/agents': () => call('GET', '/v1/agents', key),
    'GET /v1/agent': () => call('GET', '/v1/agent', tok),
    'GET /v1/workspace': () => call('GET', '/v1/workspace', key),
    'GET /v1/dm/:id/messages': () => { const id = anyConv(); return id && call('GET', `/v1/dm/${id}/messages`, tok); },
    'GET /v1/inbox': () => call('GET', '/v1/inbox', tok),
    'GET /v1/workspace/events': () => call('GET', '/v1/workspace/events?limit=50', key),
    'GET /v1/channels/:channel/messages': () => call('GET', `/v1/channels/${ch.name}/messages?limit=50`, tok),
    'GET /v1/dm/conversations': () => call('GET', '/v1/dm/conversations', tok),
    'GET /v1/messages/:id': () => { const id = anyMsg(); return id && call('GET', `/v1/messages/${id}`, tok); },
    'GET /v1/channels': () => call('GET', '/v1/channels', tok),
    'GET /v1/nodes': () => call('GET', '/v1/nodes', key),
    'GET /v1/channels/:channel': () => call('GET', `/v1/channels/${ch.name}`, tok),
    'POST /v1/messages/:id/read': () => { const id = anyMsg(); return id && call('POST', `/v1/messages/${id}/read`, tok); },
    'POST /v1/messages/:id/replies': () => { const id = anyMsg(); return id && call('POST', `/v1/messages/${id}/replies`, tok, { text: 'rcb reply' }); },
    // Tracked writes go through the sequenced streams instead:
    'POST /v1/dm': 'dm',
    'POST /v1/channels/:channel/messages': 'channel',
    _rcv: rcv, _ch: ch,
  };
}

async function replay(ph) {
  const profile = JSON.parse(readFileSync(ph.profile, 'utf8'));
  const basis = profile[ph.basis || 'rps_peak_minute_max'];
  const total = basis * (ph.scale || 1);
  const supported = Object.keys(replayCalls(mine[0])).filter((k) => !k.startsWith('_'));
  const routes = profile.routes.map((r) => ({ key: `${r.method} ${r.path}`, share: r.share }));
  const covered = routes.filter((r) => supported.includes(r.key));
  const coveredShare = covered.reduce((a, r) => a + r.share, 0);
  const skipped = routes.filter((r) => !supported.includes(r.key)).map((r) => ({ route: r.key, share: r.share }));
  // Cumulative weights over the covered routes, renormalised so the offered
  // total equals the scaled production rate.
  const cum = []; let acc = 0;
  for (const r of covered) { acc += r.share / coveredShare; cum.push([acc, r.key]); }
  const meta = { basis: ph.basis || 'rps_peak_minute_max', baseRps: basis, scale: ph.scale || 1, offeredRps: total, coveredShare, skipped };
  const issued = await runRate({ ...ph, rate: total }, (intended) => {
    const x = Math.random(); const key = (cum.find(([c]) => x <= c) || cum[cum.length - 1])[1];
    const m = pick(mine, rr++);
    const calls = replayCalls(m);
    const fn = calls[key];
    if (fn === 'dm') return enqueue(stream(m, 'dm', calls._rcv, [calls._rcv], ph.label), ph.label, intended, ph.sizeBytes || 0);
    if (fn === 'channel') return enqueue(stream(m, 'channel', calls._ch.name, calls._ch.members, ph.label), ph.label, intended, ph.sizeBytes || 0);
    if (inflight >= MAX_INFLIGHT) { status.inc(`${ph.label} client_overflow`); return; }
    inflight++;
    Promise.resolve(fn()).then((r) => {
      inflight--;
      if (!r) { status.inc(`${ph.label} ${key} no_target`); return; }
      lat.add(`${ph.label} ${key}`, r.ms); latC.add(`${ph.label} ${key}`, now() - intended); status.inc(`${ph.label} ${key} ${r.status}`);
    });
  });
  return { issued, replay: meta };
}

async function runPhase(ph) {
  const t0 = now();
  const size = ph.sizeBytes || 0;
  let issued = 0; let extra = {};
  if (ph.kind === 'idle') { await sleep(ph.durationS * 1000); }
  else if (ph.kind === 'dm' || ph.kind === 'channel' || ph.kind === 'mixed' || ph.kind === 'fanout') {
    const dms = ph.kind === 'fanout' ? [] : dmStreams(ph.label);
    const chs = ph.kind === 'fanout' ? channelStreams(true, ph.label) : channelStreams(false, ph.label);
    const share = ph.kind === 'dm' ? 1 : ph.kind === 'channel' || ph.kind === 'fanout' ? 0 : (ph.dmShare ?? 0.6);
    if ((share > 0 && !dms.length) || (share < 1 && !chs.length)) { log(`shard ${SHARD}: phase ${ph.label} has no streams here`); await sleep(ph.durationS * 1000); }
    else issued = await runRate(ph, (intended) => {
      const useDm = Math.random() < share;
      const s = useDm ? pick(dms, rr++)() : pick(chs, rr++)();
      enqueue(s, ph.label, intended, size);
    });
  } else if (ph.kind === 'backlog') {
    // DMs to the workspace-0 backlog receivers while their sockets are
    // closed; after offlineHoldS they reconnect and the sinks time the drain.
    const backlogAgents = fixture.workspaces[0].backlog || [];
    if (SHARD === 0 && SINKS.length) extra.offline = { at: now(), result: await sinkControl('offline', backlogAgents) };
    else await sleep(2000);
    const bs = mine.filter((m) => m.ws.backlog?.length).flatMap((m) => m.ws.backlog.map((b) => () => stream(m, 'dm', b, [b], ph.label)));
    if (!bs.length) await sleep(ph.durationS * 1000);
    else issued = await runRate(ph, (intended) => enqueue(pick(bs, rr++)(), ph.label, intended, size));
    while (inflight > 0) await sleep(50);
    await sleep((ph.offlineHoldS ?? 5) * 1000);
    if (SHARD === 0 && SINKS.length) extra.online = { at: now(), result: await sinkControl('online', backlogAgents) };
  } else if (ph.kind === 'broadcast') {
    const targets = ph.targets || 100;
    issued = await runRate(ph, (intended) => {
      const m = pick(mine, rr++);
      for (let k = 0; k < Math.min(targets, m.ws.receivers.length); k++) enqueue(stream(m, 'dm', m.ws.receivers[k], [m.ws.receivers[k]], ph.label), ph.label, intended, size);
    });
  } else if (ph.kind === 'upload') {
    issued = await runRate(ph, (intended) => { if (inflight < MAX_INFLIGHT) upload(ph, intended); else status.inc(`${ph.label} client_overflow`); });
  } else if (ph.kind === 'replay') {
    ({ issued, ...extra } = await replay(ph));
  } else throw new Error(`unknown phase kind ${ph.kind}`);
  // Let in-flight sends and stream queues finish (bounded).
  const drainUntil = now() + (ph.drainS ?? 60) * 1000;
  while (now() < drainUntil && (inflight > 0 || [...streamState.values()].some((s) => s.queue.length))) await sleep(50);
  // Sends still queued when the drain window ends were never issued: count
  // them (client-side backlog, a saturation signal) and drop them.
  for (const s of streamState.values()) {
    if (s.queue.length && s.phase === ph.label) { status.inc(`${ph.label} unsent_at_end`, s.queue.length); s.queue.length = 0; }
  }
  return { label: ph.label, kind: ph.kind, startedAt: t0, endedAt: now(), issued, offeredRate: ph.rate, ...extra };
}

const phases = [];
const wantPhases = env('RCB_PHASES', '').split(',').filter(Boolean);
for (const ph of plan.phases) {
  if (wantPhases.length && !wantPhases.includes(ph.label)) continue;
  progress.phase = ph.label; progress.phaseStartedAt = now();
  log(`shard ${SHARD}: phase ${ph.label} (${ph.kind}, ${ph.rate ?? '-'} /s, ${ph.durationS}s)`);
  phases.push(await runPhase(ph));
  progress.completed.push(ph.label);
  if (OUT) writeJsonAtomic(OUT, result());
}

function result() {
  const latency = {}; const corrected = {};
  for (const [k, h] of lat.m) latency[k] = h.summary();
  for (const [k, h] of latC.m) corrected[k] = h.summary();
  return {
    kind: 'producer', shard: SHARD, shards: SHARDS, run: fixture.run, plan: plan.name, phases,
    status: status.toJSON(), latency, corrected, hist: lat.toJSON(), histCorrected: latC.toJSON(),
    streams: [...streamState.values()].map((s) => ({ key: s.key, phase: s.phase, ws: s.ws, kind: s.kind, target: s.target,
      targets: s.targets, sent: s.seq, failed: s.failed, ambiguous: [...s.ambiguous, ...s.pending] })),
  };
}
if (OUT) writeJsonAtomic(OUT, result());
progress.done = true; progress.phase = null;
log(`shard ${SHARD} done`);
// Linger so the coordinator can read the final /status and /result.
if (STATUS_PORT) await sleep(envInt('RCB_LINGER_S', 5) * 1000);
process.exit(0);
