#!/usr/bin/env node
// Merges producer-*.json and sink-*.json from one run directory into
// summary.json plus CSVs (route latency, delivery latency, integrity).
//
//   node report.mjs <run-dir> [--arm pg|actors] [--step <label>]
//
// Integrity, per (producer stream, target receiver):
//   expected   = seqs 1..sent minus failed (non-201) and ambiguous (timeout)
//   received   = seqs 1..last seen minus the receiver's gaps
//   lost       = |expected| - |expected ∩ received|            (gate: 0)
//   duplicate  = repeat of a seq on the socket that first delivered it (gate: 0)
//   redelivered= repeat on a later socket after a reconnect (at-least-once; reported)
//   reordered  = a seq that filled an earlier gap late           (gate: 0)
//   unexpected = failed (non-201) seqs that were nevertheless delivered
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { Hist } from './lib.mjs';

const dir = process.argv[2];
const arg = (n) => { const i = process.argv.indexOf(n); return i > 0 ? process.argv[i + 1] : ''; };
const arm = arg('--arm');
const files = readdirSync(dir).filter((f) => f.endsWith('.json'));
const load = (f) => JSON.parse(readFileSync(join(dir, f), 'utf8'));
const producers = files.filter((f) => f.startsWith('producer-')).map(load);
const sinks = files.filter((f) => f.startsWith('sink-')).map(load);

const mergeHists = (objs) => {
  const out = new Map();
  for (const o of objs) for (const [k, j] of Object.entries(o || {})) {
    if (!out.has(k)) out.set(k, new Hist());
    out.get(k).merge(Hist.from(j));
  }
  return out;
};

// Phase windows (union across shards).
const phases = new Map();
for (const p of producers) for (const ph of p.phases) {
  const w = phases.get(ph.label) || { label: ph.label, kind: ph.kind, offeredRate: ph.offeredRate, startedAt: Infinity, endedAt: 0, issued: 0, replay: ph.replay };
  w.startedAt = Math.min(w.startedAt, ph.startedAt); w.endedAt = Math.max(w.endedAt, ph.endedAt); w.issued += ph.issued;
  phases.set(ph.label, w);
}

const raw = mergeHists(producers.map((p) => p.hist));
const corr = mergeHists(producers.map((p) => p.histCorrected));
const status = {};
for (const p of producers) for (const [k, n] of Object.entries(p.status)) status[k] = (status[k] || 0) + n;

const routeRows = [];
for (const [k, h] of raw) {
  const [phase, ...rest] = k.split(' ');
  const route = rest.join(' ');
  const w = phases.get(phase);
  const secs = w ? (w.endedAt - w.startedAt) / 1000 : null;
  const codes = Object.entries(status).filter(([sk]) => sk.startsWith(`${phase} ${route} `)).map(([sk, n]) => [sk.slice(phase.length + route.length + 2), n]);
  const total = codes.reduce((a, [, n]) => a + n, 0);
  const ok = codes.filter(([c]) => /^2\d\d$/.test(c)).reduce((a, [, n]) => a + n, 0);
  const n429 = codes.filter(([c]) => c === '429').reduce((a, [, n]) => a + n, 0);
  const n5xx = codes.filter(([c]) => /^5\d\d$/.test(c)).reduce((a, [, n]) => a + n, 0);
  const n0 = codes.filter(([c]) => c === '0').reduce((a, [, n]) => a + n, 0);
  const s = h.summary(); const c = corr.get(k)?.summary() || {};
  routeRows.push({ arm, phase, route, requests: total, ok, rps_ok: secs ? +(ok / secs).toFixed(2) : null,
    err_rate: total ? +((total - ok) / total).toFixed(5) : null, r429: n429, r5xx: n5xx, net_err: n0,
    p50: s.p50, p95: s.p95, p99: s.p99, max: s.max, corrected_p50: c.p50 ?? null, corrected_p95: c.p95 ?? null, corrected_p99: c.p99 ?? null });
}

const deliv = mergeHists(sinks.map((s) => s.deliveryLatency));
const deliveryRows = [...deliv].map(([phase, h]) => {
  const w = phases.get(phase); const secs = w ? (w.endedAt - w.startedAt) / 1000 : null; const s = h.summary();
  return { arm, phase, deliveries: s.n, deliveries_per_s: secs ? +(s.n / secs).toFixed(2) : null, p50: s.p50, p95: s.p95, p99: s.p99, p999: s.p999, max: s.max };
});

// Integrity.
const recv = new Map();
for (const s of sinks) for (const [k, v] of Object.entries(s.streams)) recv.set(k, v);
const integ = new Map();
const bump = (phase, f, n) => { const r = integ.get(phase) || { arm, phase, expected: 0, delivered: 0, lost: 0, duplicate: 0, redelivered: 0, reordered: 0, reordered_after_timeout: 0, unexpected: 0, truncated: 0 }; r[f] += n; integ.set(phase, r); };
for (const p of producers) for (const st of p.streams) {
  const failed = new Set(st.failed); const amb = new Set(st.ambiguous);
  for (const t of st.targets) {
    const key = `${st.key}|${st.ws}/${t}`;
    const r = recv.get(key);
    const exp = st.sent - failed.size - amb.size;
    bump(st.phase, 'expected', exp);
    if (!r) { bump(st.phase, 'lost', exp); continue; }
    const missing = new Set(r.missing);
    if (r.missingCount > r.missing.length) bump(st.phase, 'truncated', 1);
    let got = 0; let unexpected = 0;
    for (let k = 1; k <= Math.min(st.sent, r.last); k++) {
      if (missing.has(k)) continue;
      if (failed.has(k)) unexpected++; else if (!amb.has(k)) got++;
    }
    bump(st.phase, 'delivered', got); bump(st.phase, 'lost', exp - got); bump(st.phase, 'unexpected', unexpected);
    bump(st.phase, 'duplicate', r.dups); bump(st.phase, 'redelivered', r.redelivered || 0);
    // A late arrival is a reorder only when neither it nor anything it
    // overtook was a send the client gave up on (timeout): after a timeout the
    // client sends N+1 while N may still be queued server-side.
    const ooo = r.oooSeqs ? r.oooSeqs.filter((k) => !amb.has(k)).length : r.ooo;
    bump(st.phase, 'reordered', amb.size ? ooo : r.ooo);
    bump(st.phase, 'reordered_after_timeout', r.oooSeqs ? r.oooSeqs.length - ooo : 0);
  }
}

const sinkMeta = sinks.map((s) => ({ shard: s.shard, sockets: s.sockets, connected: s.connected, drops: s.drops,
  connect: Hist.from(s.connect).summary(), reconnect: Hist.from(s.reconnect).summary(), counters: s.counters, drain: s.drain, rssBytes: s.mem }));

const summary = { arm, dir, phases: [...phases.values()], routes: routeRows, delivery: deliveryRows, integrity: [...integ.values()], sinks: sinkMeta };
writeFileSync(join(dir, 'summary.json'), JSON.stringify(summary, null, 1));
const csv = (rows) => rows.length ? [Object.keys(rows[0]).join(','), ...rows.map((r) => Object.values(r).map((v) => (v === null ? '' : String(v).includes(',') ? `"${v}"` : v)).join(','))].join('\n') + '\n' : '';
writeFileSync(join(dir, 'routes.csv'), csv(routeRows));
writeFileSync(join(dir, 'delivery.csv'), csv(deliveryRows));
writeFileSync(join(dir, 'integrity.csv'), csv([...integ.values()]));
console.log(JSON.stringify({ routes: routeRows.length, delivery: deliveryRows, integrity: [...integ.values()] }, null, 1));
