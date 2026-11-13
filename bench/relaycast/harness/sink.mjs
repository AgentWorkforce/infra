#!/usr/bin/env node
// Receiver fleet. Opens one /v1/node/ws socket per fixture node assigned to
// RCB_SHARD, registers that node's receiver agents, joins their channels, and
// then for every delivered benchmark message records:
//   - send-to-delivery latency (receive time - sent_epoch_ms in the marker),
//     per phase;
//   - per (producer, stream, receiver) sequence accounting: distinct, gaps
//     (missing), duplicates, out-of-order arrivals;
//   - socket drops, reconnect time and drain after reconnect.
// Deliveries are acked with delivery.ack up_to_seq every RCB_ACK_MS.
//
// HTTP control on RCB_PORT (default 9090), cluster-internal only:
//   GET  /ready            200 once every socket is registered and joined
//   GET  /stats            JSON snapshot (histograms mergeable, see lib.mjs)
//   POST /offline?agents=b0,b1   close those agents' sockets (backlog test)
//   POST /online?agents=b0,b1    reopen them; drain is measured from here
import http from 'node:http';
import { readFileSync } from 'node:fs';
import { env, envInt, httpClient, HistMap, Hist, Counter, MARKER_RE, log, now, sleep, writeJsonAtomic } from './lib.mjs';

const fixture = JSON.parse(readFileSync(env('RCB_FIXTURE'), 'utf8'));
const SHARD = envInt('RCB_SHARD', 0);
const PORT = envInt('RCB_PORT', 9090);
const ACK_MS = envInt('RCB_ACK_MS', 50);
const HEARTBEAT_MS = envInt('RCB_HEARTBEAT_MS', 15000);
const OUT = env('RCB_OUT', '');
const call = httpClient(fixture.baseUrl);
const wsBase = fixture.baseUrl.replace(/^http/, 'ws');

const deliveryLat = new HistMap(); // per phase
const counters = new Counter();
const streams = new Map(); // key producer|stream|receiver -> state
const drain = []; // backlog drain records
const reconnectLat = new Hist();
let genCounter = 0;
const dupEvidence = []; // first 200 duplicates/redeliveries with timing, for the report
const firstSeen = new Map(); // delivery_id -> first arrival ms (bounded)

// A repeat of a seq on the same socket generation that first delivered it is
// a duplicate (gate: 0). A repeat on a later generation is redelivery after a
// reconnect: delivery.ack has no reply, so an ack written just before a drop
// may never commit, and the engine re-drains unacked rows (at-least-once).
// Each stream keeps [fromSeq, generation] transitions to find the first
// delivery's generation without storing every seq.
function genOf(s, seq) {
  let g = s.gens[0][1];
  for (const [from, gen] of s.gens) { if (from <= seq) g = gen; else break; }
  return g;
}
function track(phase, producer, stream, seq, receiver, gen) {
  const key = `${producer}|${stream}|${receiver}`;
  let s = streams.get(key);
  if (!s) streams.set(key, (s = { phase, last: 0, distinct: 0, dups: 0, redelivered: 0, ooo: 0, missing: new Set(), oooSeqs: [], gens: [[1, gen]] }));
  if (seq > s.last && s.gens[s.gens.length - 1][1] !== gen) s.gens.push([seq, gen]);
  if (seq === s.last + 1) { s.last = seq; s.distinct++; return; }
  if (seq > s.last + 1) {
    for (let k = s.last + 1; k < seq; k++) s.missing.add(k);
    s.last = seq; s.distinct++; return;
  }
  if (s.missing.delete(seq)) { s.distinct++; s.ooo++; if (s.oooSeqs.length < 5000) s.oooSeqs.push(seq); return; }
  if (genOf(s, seq) === gen) s.dups++; else s.redelivered++;
}

class NodeConn {
  constructor(ws, node) {
    this.ws = ws; this.node = node; this.agents = new Map(); // name -> {id, token, maxSeq, ackedSeq}
    this.sock = null; this.ready = false; this.drops = 0; this.offline = false; this.pending = new Map(); this.reqId = 0;
    this.onlineAt = null; this.lastDeliverAt = null; this.drainCount = 0; this.downAt = null; this.connecting = null; this.gen = 0;
  }
  send(frame) { if (this.sock?.readyState === 1) this.sock.send(JSON.stringify({ v: 1, ...frame })); }
  request(frame, timeoutMs = 30000) {
    const id = `q${++this.reqId}`;
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => { this.pending.delete(id); reject(new Error(`${frame.type} timeout`)); }, timeoutMs);
      this.pending.set(id, { resolve: (d) => { clearTimeout(t); resolve(d); }, reject: (e) => { clearTimeout(t); reject(e); } });
      this.send({ ...frame, id });
    });
  }
  // One connect loop per node at a time; concurrent callers share it.
  open() {
    if (!this.connecting) this.connecting = this.connectLoop().finally(() => { this.connecting = null; });
    return this.connecting;
  }
  async connectLoop() {
    const t0 = now();
    for (let attempt = 0; ; attempt++) {
      if (this.offline) return now() - t0;
      try {
        await this.connectOnce();
        if (this.downAt) { reconnectLat.add(now() - this.downAt); this.downAt = null; }
        return now() - t0;
      } catch (e) {
        counters.inc(`connect_error ${e.message.slice(0, 60)}`);
        await sleep(Math.min(2000, 100 * 2 ** attempt) * (0.5 + Math.random() / 2));
      }
    }
  }
  connectOnce() {
    return new Promise((resolve, reject) => {
      const sock = new WebSocket(`${wsBase}/v1/node/ws?token=${encodeURIComponent(this.node.token)}`);
      this.sock = sock;
      let settled = false; let established = false;
      sock.onopen = async () => {
        // A new generation starts when the socket opens: the engine re-drains
        // unacked deliveries right after node.register, before agent setup
        // finishes, and those must count as redeliveries on this socket.
        this.gen = ++genCounter;
        try {
          await this.request({ type: 'node.register', name: this.node.name, node_id: this.node.id, capabilities: [],
            max_agents: Math.max(this.node.agents.length, 1), tags: [], version: 'rcb-1' });
          // Agents stay bound to the node across reconnects (the engine
          // re-drains their unacked deliveries), so they register once.
          for (const name of this.node.agents) {
            if (this.agents.has(name)) continue;
            // Agents bound over HTTP (POST /v1/nodes/:name/agents) receive on
            // node.register; they already exist and are already channel members.
            if (this.node.bound) { this.agents.set(name, { id: null, token: null, maxSeq: 0, ackedSeq: 0 }); continue; }
            const d = await this.request({ type: 'agent.register', name });
            this.agents.set(name, { id: d.agent_id, token: d.token, maxSeq: 0, ackedSeq: 0 });
          }
          this.ready = true; established = true; settled = true; resolve();
        } catch (e) { settled = true; try { sock.close(); } catch { /* */ } reject(e); }
      };
      sock.onerror = () => { if (!settled) { settled = true; reject(new Error('ws error')); } };
      sock.onclose = (ev) => {
        this.ready = false;
        for (const p of this.pending.values()) p.reject(new Error('closed'));
        this.pending.clear();
        if (!settled) { settled = true; reject(new Error(`ws closed ${ev.code}`)); return; }
        if (this.offline || !established || this.sock !== sock) return;
        this.drops++; counters.inc(`ws_drop ${ev.code}`); this.downAt = now();
        this.open();
      };
      sock.onmessage = (ev) => this.onFrame(ev.data);
    });
  }
  onFrame(data) {
    let f;
    try { f = JSON.parse(data); } catch { counters.inc('bad_frame'); return; }
    if (f.type === 'reply' || f.type === 'error') {
      const p = this.pending.get(f.id);
      if (p) { this.pending.delete(f.id); f.type === 'reply' ? p.resolve(f.data) : p.reject(new Error(`${f.error?.code || f.code || 'error'}`)); }
      else if (f.type === 'error') counters.inc(`ws_error ${f.error?.code || f.code}`);
      return;
    }
    if (f.type !== 'deliver') { counters.inc(`frame ${f.type}`); return; }
    const t = now();
    counters.inc('deliver');
    const a = this.agents.get(f.agent);
    if (a && f.seq > a.maxSeq) a.maxSeq = f.seq;
    const text = f.payload?.data?.message?.text ?? f.payload?.data?.text ?? JSON.stringify(f.payload);
    const m = MARKER_RE.exec(text);
    if (!m) { counters.inc('deliver_unmarked'); return; }
    const [, phase, producer, stream, seqS, sentS] = m;
    deliveryLat.add(phase, t - Number(sentS));
    track(phase, producer, stream, Number(seqS), `${this.ws.i}/${f.agent}`, this.gen);
    if (this.onlineAt) { this.lastDeliverAt = t; this.drainCount++; }
    const prevSeen = firstSeen.get(f.delivery_id);
    if (prevSeen !== undefined && dupEvidence.length < 200) {
      dupEvidence.push({ delivery_id: f.delivery_id, agent: `${this.ws.i}/${f.agent}`, seq: f.seq, firstAt: prevSeen.t, againAt: t,
        sameSocket: prevSeen.gen === this.gen });
    }
    if (prevSeen === undefined) { firstSeen.set(f.delivery_id, { t, gen: this.gen }); if (firstSeen.size > 200000) firstSeen.delete(firstSeen.keys().next().value); }
  }
  flushAcks() {
    if (!this.ready) return;
    for (const [name, a] of this.agents) {
      if (a.maxSeq > a.ackedSeq) {
        this.send({ type: 'delivery.ack', agent: name, up_to_seq: a.maxSeq }); a.ackedSeq = a.maxSeq;
      }
    }
  }
  heartbeat() { if (this.ready) this.send({ type: 'node.heartbeat', active_agents: this.agents.size, handlers_live: true }); }
  goOffline() { this.flushAcks(); this.offline = true; this.ready = false; try { this.sock?.close(1000, 'bench offline'); } catch { /* */ } }
  async goOnline() {
    this.offline = false; this.onlineAt = now(); this.lastDeliverAt = null; this.drainCount = 0;
    const ms = await this.open();
    return ms;
  }
}

const conns = [];
for (const ws of fixture.workspaces) for (const node of ws.nodes) if (node.shard === SHARD) conns.push(new NodeConn(ws, node));
log(`shard ${SHARD}: ${conns.length} node sockets, ${conns.reduce((n, c) => n + c.node.agents.length, 0)} receivers`);

let ready = false;
const connectLat = new Hist();
(async () => {
  const CONC = envInt('RCB_CONNECT_CONCURRENCY', 64);
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(CONC, conns.length) }, async () => {
    while (i < conns.length) { const c = conns[i++]; connectLat.add(await c.open()); }
  }));
  // Receivers join their channels with the token agent.register returned.
  const joins = [];
  for (const c of conns) {
    for (const ch of c.ws.channels) for (const name of ch.members) {
      const a = c.agents.get(name);
      if (a?.token) joins.push([ch.name, a.token]);
    }
  }
  let j = 0;
  await Promise.all(Array.from({ length: Math.min(32, joins.length) }, async () => {
    while (j < joins.length) {
      const [ch, tok] = joins[j++];
      for (let attempt = 0; attempt < 6; attempt++) {
        const r = await call('POST', `/v1/channels/${ch}/join`, tok);
        counters.inc(`join ${r.status}`);
        if (r.status === 200) break;
        await sleep(500 * 2 ** attempt);
      }
    }
  }));
  ready = true;
  log(`shard ${SHARD} ready`, { connect: connectLat.summary(), joins: joins.length });
})();

setInterval(() => { for (const c of conns) c.flushAcks(); }, ACK_MS).unref();
setInterval(() => { for (const c of conns) c.heartbeat(); }, HEARTBEAT_MS).unref();

function snapshot() {
  const st = {};
  for (const [k, s] of streams) st[k] = { phase: s.phase, last: s.last, distinct: s.distinct, dups: s.dups, redelivered: s.redelivered, ooo: s.ooo, oooSeqs: s.oooSeqs, missing: [...s.missing].slice(0, 1000), missingCount: s.missing.size };
  return {
    kind: 'sink', shard: SHARD, run: fixture.run, at: new Date().toISOString(), ready,
    sockets: conns.length, connected: conns.filter((c) => c.ready).length, drops: conns.reduce((n, c) => n + c.drops, 0),
    connect: connectLat.toJSON(), reconnect: reconnectLat.toJSON(), counters: counters.toJSON(),
    deliveryLatency: deliveryLat.toJSON(), streams: st, dupEvidence,
    drain: drain.concat(conns.filter((c) => c.onlineAt).map((c) => ({ node: `${c.ws.i}/${c.node.name}`, onlineAt: c.onlineAt,
      lastDeliverAt: c.lastDeliverAt, drained: c.drainCount, drainMs: c.lastDeliverAt ? c.lastDeliverAt - c.onlineAt : null }))),
    mem: process.memoryUsage().rss,
  };
}

const pick = (url) => new Set((url.searchParams.get('agents') || '').split(',').filter(Boolean));
http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const reply = (code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
  if (url.pathname === '/ready') return reply(ready ? 200 : 503, { ready, connected: conns.filter((c) => c.ready).length, sockets: conns.length });
  if (url.pathname === '/stats') return reply(200, snapshot());
  if (req.method === 'POST' && url.pathname === '/offline') {
    const want = pick(url); const hit = conns.filter((c) => c.node.agents.some((a) => want.has(a)));
    hit.forEach((c) => c.goOffline()); return reply(200, { offline: hit.map((c) => c.node.name) });
  }
  if (req.method === 'POST' && url.pathname === '/online') {
    const want = pick(url); const hit = conns.filter((c) => c.node.agents.some((a) => want.has(a)));
    const ms = await Promise.all(hit.map((c) => c.goOnline())); return reply(200, { online: hit.map((c) => c.node.name), reconnectMs: ms });
  }
  reply(404, {});
}).listen(PORT);

const finish = () => { if (OUT) writeJsonAtomic(OUT, snapshot()); process.exit(0); };
process.on('SIGTERM', finish);
process.on('SIGINT', finish);
