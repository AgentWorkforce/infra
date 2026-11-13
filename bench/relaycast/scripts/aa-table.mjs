#!/usr/bin/env node
// AA decision table (robustness first) from results/aa-a63961b/<arm>/:
//   aa-soak/all/{summary.json,chaos.jsonl}, aa-soak/metrics.csv,
//   series/<arm>-aa-soak.csv (sample-series.sh), aa-headroom/** when present.
//
//   node bench/relaycast/scripts/aa-table.mjs [results-dir]   -> markdown + aa-table.json
//
// Recovery per chaos event: the first sample at or after the event from
// which, for 3 consecutive samples, OK sends per second are >= 80 % of the
// 5-sample baseline before the event, no new errors appear, deliveries keep
// flowing and every socket is connected. "No" = not recovered before the soak
// ended (would need a human).
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const RES = process.argv[2] || join(dirname(fileURLToPath(import.meta.url)), '..', 'results', 'aa-a63961b');
const ARMS = [['pg', 'Postgres (+#657, as shipped)'], ['actors', 'Durable actors (12.8.0-actors.1, as shipped)']];
const J = (p) => (existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : null);
const lines = (p) => (existsSync(p) ? readFileSync(p, 'utf8').trim().split('\n') : []);
const ms = (v) => (v == null ? '–' : v >= 1000 ? `${(v / 1000).toFixed(1)} s` : `${Math.round(v)} ms`);

function series(arm) {
  const rows = lines(join(RES, 'series', `${arm}-aa-soak.csv`)).slice(1).map((l) => l.split(',').map(Number));
  return rows.map(([ts, ok, e5, e4, e429, e0, del, drops, conn, socks]) => ({ ts, ok, err: e5 + e4 + e429 + e0, e5, e4, e429, e0, del, drops, conn, socks }));
}

function recovery(s, at) {
  const t = at / 1000;
  const before = s.filter((r) => r.ts < t).slice(-6);
  if (before.length < 3) return { recoveredS: null, note: 'no baseline' };
  const rate = (a, b) => (b.ok - a.ok) / Math.max(1, b.ts - a.ts);
  const base = rate(before[0], before[before.length - 1]);
  const after = s.filter((r) => r.ts >= t);
  for (let i = 1; i + 3 < after.length; i++) {
    const w = after.slice(i, i + 4);
    const okRate = rate(w[0], w[w.length - 1]);
    const noErr = w[w.length - 1].err === w[0].err;
    const flowing = w[w.length - 1].del > w[0].del;
    const conn = w.every((r) => r.conn === r.socks && r.socks > 0);
    if (okRate >= 0.8 * base && noErr && flowing && conn) {
      const errs = after[i].err - before[before.length - 1].err;
      const drops = after[i].drops - before[before.length - 1].drops;
      return { recoveredS: Math.round(after[i].ts - t), errorsDuring: errs, socketDrops: drops };
    }
  }
  return { recoveredS: null, errorsDuring: (after.at(-1)?.err ?? 0) - before.at(-1).err, note: 'not recovered before end' };
}

function podStats(arm) {
  const ns = `arm-${arm}`;
  const rows = lines(join(RES, arm, 'aa-soak', 'metrics.csv')).slice(1).map((l) => l.split(','));
  const pick = (re, sandbox) => rows.filter((r) => r[1] === 'pod' && (sandbox ? r[2] === `${ns}-agent-relay` : r[2] === ns && re.test(r[3])));
  const drift = (rs) => {
    if (!rs.length) return null;
    const byTs = new Map(); for (const r of rs) byTs.set(r[0], (byTs.get(r[0]) || 0) + Number(r[6] || 0));
    const v = [...byTs.entries()].sort((a, b) => a[0] - b[0]).map(([, m]) => m);
    const n = Math.max(1, Math.floor(v.length / 10));
    const head = v.slice(0, n).reduce((a, b) => a + b, 0) / n; const tail = v.slice(-n).reduce((a, b) => a + b, 0) / n;
    return { startMi: Math.round(head), endMi: Math.round(tail), peakMi: Math.max(...v) };
  };
  return {
    relaycast: drift(pick(/^relaycast-/)),
    controlPlane: arm === 'actors' ? drift(pick(/^agent-relay-durable-actors-/)) : null,
    actorHosts: arm === 'actors' ? drift(pick(null, true)) : null,
  };
}

const out = {};
const md = ['### AA decision set (relaycast main; robustness first)\n'];
for (const [arm, name] of ARMS) {
  const s = J(join(RES, arm, 'aa-soak', 'all', 'summary.json'));
  if (!s) continue;
  const integ = s.integrity.reduce((a, r) => { for (const k of ['expected', 'delivered', 'lost', 'duplicate', 'redelivered', 'reordered', 'reordered_after_timeout', 'unexpected']) a[k] = (a[k] || 0) + (r[k] || 0); return a; }, {});
  const sends = s.routes.filter((r) => /POST \/v1\/(dm|channels)/.test(r.route));
  const req = sends.reduce((a, r) => a + r.requests, 0), ok = sends.reduce((a, r) => a + r.ok, 0);
  const codes = {}; for (const r of s.routes) { codes['5xx'] = (codes['5xx'] || 0) + r.r5xx; codes['429'] = (codes['429'] || 0) + r.r429; codes.timeout = (codes.timeout || 0) + r.net_err; }
  const uploads = s.routes.filter((r) => /files/.test(r.route));
  const d = s.delivery[0] || {};
  const ser = series(arm);
  const chaos = lines(join(RES, arm, 'aa-soak', 'all', 'chaos.jsonl')).map((l) => JSON.parse(l)).map((c) => ({ ...c, ...recovery(ser, c.at) }));
  out[arm] = { name, integrity: integ, sends: { req, ok, errRate: req ? (req - ok) / req : null }, codes,
    send: { p50: Math.max(...sends.map((r) => r.corrected_p50 || 0)), p95: Math.max(...sends.map((r) => r.corrected_p95 || 0)), p99: Math.max(...sends.map((r) => r.corrected_p99 || 0)) },
    delivery: { p50: d.p50, p95: d.p95, p99: d.p99 }, uploads: uploads.map((u) => ({ route: u.route, n: u.requests, err: u.err_rate, p95: u.p95 })),
    chaos, pods: podStats(arm) };
  const o = out[arm];
  md.push(`#### ${name}\n`);
  md.push('| Robustness | Value |\n|---|---|');
  md.push(`| Integrity after quiescence (lost / duplicate / reordered) | ${integ.lost} / ${integ.duplicate} / ${integ.reordered} of ${integ.expected} |`);
  md.push(`| Redelivered after reconnect (at-least-once) / 5xx-but-delivered | ${integ.redelivered} / ${integ.unexpected} |`);
  md.push(`| Send errors | ${(o.sends.errRate * 100).toFixed(2)} % (${req - ok} of ${req}: 5xx ${codes['5xx']}, 429 ${codes['429']}, timeouts ${codes.timeout}) |`);
  for (const c of chaos) md.push(`| Chaos: ${c.action}${c.manual ? ' (manual)' : ''} | ${c.recoveredS == null ? `**not recovered** (${c.note || ''})` : `recovered in ${c.recoveredS} s, no intervention`}; errors during ${c.errorsDuring ?? '–'}, socket drops ${c.socketDrops ?? '–'} |`);
  const p = o.pods;
  const f = (x) => (x ? `${x.startMi} -> ${x.endMi} MiB (peak ${x.peakMi})` : '–');
  md.push(`| Memory drift over the soak: relaycast${arm === 'actors' ? ' gateway' : ''} | ${f(p.relaycast)} |`);
  if (arm === 'actors') { md.push(`| Memory drift: control plane | ${f(p.controlPlane)} |`); md.push(`| Memory: all actor hosts (sum) | ${f(p.actorHosts)} |`); }
  md.push('\n| Performance | Value |\n|---|---|');
  md.push(`| Send p50 / p95 / p99 (corrected) | ${ms(o.send.p50)} / ${ms(o.send.p95)} / ${ms(o.send.p99)} |`);
  md.push(`| Delivery p50 / p95 / p99 | ${ms(o.delivery.p50)} / ${ms(o.delivery.p95)} / ${ms(o.delivery.p99)} |`);
  for (const u of o.uploads) md.push(`| ${u.route} | n=${u.n}, errors ${(u.err * 100).toFixed(1)} %, p95 ${ms(u.p95)} |`);
  md.push('');
}
writeFileSync(join(RES, 'aa-table.json'), JSON.stringify(out, null, 1));
process.stdout.write(md.join('\n') + '\n');
