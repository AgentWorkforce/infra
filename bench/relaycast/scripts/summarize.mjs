#!/usr/bin/env node
// Builds the comparison tables for docs/benchmarks/relaycast-postgres-vs-actors.md
// from bench/relaycast/results/<arm>/<suite>/** (summary.json written by
// report.mjs, coldstart.json, metrics.csv, rds-cloudwatch.json, steps.txt),
// and writes them between <!-- results:start --> and <!-- results:end -->,
// plus results/comparison.csv (one row per arm/suite/phase).
//
//   node bench/relaycast/scripts/summarize.mjs [--write]
import { existsSync, readdirSync, readFileSync, writeFileSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const BENCH = join(dirname(fileURLToPath(import.meta.url)), '..');
const RES = join(BENCH, 'results');
const DOC = join(BENCH, '..', '..', 'docs', 'benchmarks', 'relaycast-postgres-vs-actors.md');
const ARMS = ['pg', 'actors'];
const ARM_NAME = { pg: 'Postgres', actors: 'Actors' };
const SEND_RE = /^POST \/v1\/(dm|channels\/:name\/messages)$/;
const fmt = (v, d = 0) => (v === null || v === undefined || Number.isNaN(v) ? '–' : Number(v).toFixed(d));
const ms = (v) => (v === null || v === undefined ? '–' : v >= 1000 ? `${(v / 1000).toFixed(1)} s` : `${Math.round(v)}`);
const pct = (v) => (v === null || v === undefined ? '–' : `${(v * 100).toFixed(v > 0 && v < 0.001 ? 3 : 1)} %`);
const readJson = (p) => (existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : null);
const dirs = (p) => (existsSync(p) ? readdirSync(p).filter((d) => statSync(join(p, d)).isDirectory()) : []);

// Collect every summary.json: results/<arm>/<suite>/<part>/summary.json
const rows = [];
const steps = {};
for (const arm of ARMS) {
  for (const suite of dirs(join(RES, arm))) {
    const st = join(RES, arm, suite, 'steps.txt');
    if (existsSync(st)) steps[`${arm}/${suite}`] = readFileSync(st, 'utf8').trim().split('\n').map((l) => l.split(' ')).map(([label, ...v]) => ({ label, verdict: v.join(' ') }));
    for (const part of dirs(join(RES, arm, suite))) {
      const s = readJson(join(RES, arm, suite, part, 'summary.json'));
      if (!s) continue;
      for (const ph of s.phases) {
        const sends = s.routes.filter((r) => r.phase === ph.label && SEND_RE.test(r.route));
        const req = sends.reduce((a, r) => a + r.requests, 0);
        const ok = sends.reduce((a, r) => a + r.ok, 0);
        const worst = (k) => (sends.length ? Math.max(...sends.map((r) => r[k] ?? 0)) : null);
        const d = s.delivery.find((x) => x.phase === ph.label) || {};
        const i = s.integrity.find((x) => x.phase === ph.label) || {};
        const other = s.routes.filter((r) => r.phase === ph.label && !SEND_RE.test(r.route));
        const secs = (ph.endedAt - ph.startedAt) / 1000;
        rows.push({
          arm, suite, phase: ph.label, kind: ph.kind, offered: ph.offeredRate ?? ph.replay?.offeredRps ?? null,
          secs: Math.round(secs), sends: req, sends_ok_per_s: secs ? +(ok / secs).toFixed(1) : null,
          send_err: req ? +((req - ok) / req).toFixed(5) : null,
          r429: sends.reduce((a, r) => a + r.r429, 0), r5xx: sends.reduce((a, r) => a + r.r5xx, 0),
          send_p50: worst('corrected_p50'), send_p95: worst('corrected_p95'), send_p99: worst('corrected_p99'),
          deliv_per_s: d.deliveries_per_s ?? null, deliv_p50: d.p50 ?? null, deliv_p95: d.p95 ?? null, deliv_p99: d.p99 ?? null,
          lost: i.lost ?? null, duplicate: i.duplicate ?? null, reordered: i.reordered ?? null, redelivered: i.redelivered ?? null,
          other_routes: other.map((r) => ({ route: r.route, p50: r.p50, p95: r.p95, p99: r.p99, err: r.err_rate, n: r.requests })),
          replay: ph.replay || null,
          drain: s.sinks.flatMap((x) => x.drain || []).filter((x) => x.drainMs !== null),
          drops: s.sinks.reduce((a, x) => a + x.drops, 0),
          reconnect: s.sinks.map((x) => x.reconnect).filter((x) => x.n),
        });
      }
    }
  }
}

// Resource usage per arm/suite from metrics.csv: peak and mean CPU (millicores)
// and memory (MiB) of the Relaycast-side workloads, and RDS from CloudWatch.
const RELAYCAST_POD = /^(relaycast|agent-relay-durable-actors|sandbox|ws-|actor)/;
function resources(arm, suite) {
  const p = join(RES, arm, suite, 'metrics.csv');
  if (!existsSync(p)) return null;
  const byTs = new Map();
  for (const line of readFileSync(p, 'utf8').split('\n').slice(1)) {
    const [ts, kind, ns, name, , cpu, mem] = line.split(',');
    if (kind !== 'pod' || !name) continue;
    const isArm = ns === `arm-${arm}` || ns === `arm-${arm}-agent-relay`;
    if (!isArm || (!RELAYCAST_POD.test(name) && ns !== `arm-${arm}-agent-relay`)) continue;
    const t = byTs.get(ts) || { cpu: 0, mem: 0 };
    t.cpu += Number(cpu) || 0; t.mem += Number(mem) || 0; byTs.set(ts, t);
  }
  const v = [...byTs.values()];
  if (!v.length) return null;
  const rds = readJson(join(RES, arm, suite, 'rds-cloudwatch.json'));
  const series = (id) => rds?.MetricDataResults?.find((m) => m.Id === id)?.Values || [];
  const max = (a) => (a.length ? Math.max(...a) : null);
  return {
    cpu_peak_m: Math.max(...v.map((x) => x.cpu)), cpu_mean_m: Math.round(v.reduce((a, x) => a + x.cpu, 0) / v.length),
    mem_peak_mi: Math.max(...v.map((x) => x.mem)),
    rds_cpu_peak: max(series('cpu')), rds_conns_peak: max(series('conns')), rds_wiops_peak: max(series('wiops')),
  };
}

// Markdown.
const out = [];
const pair = (suite, phase) => ARMS.map((a) => rows.find((r) => r.arm === a && r.suite === suite && r.phase.replace(/^[a-z0-9]+-/, '') === phase.replace(/^[a-z0-9]+-/, '') && r.phase === phase) || null);
const suites = [...new Set(rows.map((r) => r.suite))];
out.push('### Send and delivery, per phase\n');
out.push('Send = POST `/v1/dm` or channel message, corrected latency in ms (from the intended send time; worst of the two routes in mixed phases). Delivery = send to arrival on the receiver\'s node socket. Integrity columns are lost / duplicate / reordered (gate 0) and redelivered (at-least-once, reported).\n');
out.push('| Suite | Phase | Arm | Offered /s | OK sends /s | Err | 429 | 5xx | Send p50 / p95 / p99 | Deliveries /s | Delivery p50 / p95 / p99 | Lost / dup / reord | Redeliv |');
out.push('|---|---|---|---|---|---|---|---|---|---|---|---|---|');
for (const suite of suites) {
  const phases = [...new Set(rows.filter((r) => r.suite === suite).map((r) => r.phase))];
  for (const ph of phases) for (const r of ARMS.map((a) => rows.find((x) => x.arm === a && x.suite === suite && x.phase === ph))) {
    if (!r) continue;
    out.push(`| ${suite} | ${ph} | ${ARM_NAME[r.arm]} | ${fmt(r.offered, r.offered < 10 ? 1 : 0)} | ${fmt(r.sends_ok_per_s, 1)} | ${pct(r.send_err)} | ${r.r429} | ${r.r5xx} | ${ms(r.send_p50)} / ${ms(r.send_p95)} / ${ms(r.send_p99)} | ${fmt(r.deliv_per_s, 1)} | ${ms(r.deliv_p50)} / ${ms(r.deliv_p95)} / ${ms(r.deliv_p99)} | ${r.lost ?? '–'} / ${r.duplicate ?? '–'} / ${r.reordered ?? '–'} | ${r.redelivered ?? '–'} |`);
  }
}

const stepKeys = Object.keys(steps);
if (stepKeys.length) {
  out.push('\n### Stepped suites: where each arm breaks\n');
  out.push('| Arm / suite | Steps (verdict) |');
  out.push('|---|---|');
  for (const k of stepKeys) out.push(`| ${k.replace('pg/', 'Postgres / ').replace('actors/', 'Actors / ')} | ${steps[k].map((s) => `${s.label}: ${s.verdict}`).join('; ')} |`);
}

const others = rows.filter((r) => r.other_routes.length);
if (others.length) {
  out.push('\n### Other routes (raw latency, ms)\n');
  out.push('| Suite | Phase | Arm | Route | n | p50 | p95 | p99 | Err |');
  out.push('|---|---|---|---|---|---|---|---|---|');
  for (const r of others) for (const o of r.other_routes) {
    if (/_raw$/.test(o.route)) continue;
    out.push(`| ${r.suite} | ${r.phase} | ${ARM_NAME[r.arm]} | \`${o.route}\` | ${o.n} | ${ms(o.p50)} | ${ms(o.p95)} | ${ms(o.p99)} | ${pct(o.err)} |`);
  }
}

const drains = rows.filter((r) => r.drain.length);
if (drains.length) {
  out.push('\n### Backlog drain\n');
  out.push('| Arm | Phase | Node | Delivered on reconnect | Drain time |');
  out.push('|---|---|---|---|---|');
  for (const r of drains) for (const d of r.drain) out.push(`| ${ARM_NAME[r.arm]} | ${r.phase} | ${d.node} | ${d.drained} | ${ms(d.drainMs)} |`);
}

const cold = ARMS.map((a) => [a, readJson(join(RES, a, 'coldstart', 'coldstart.json'))]).filter(([, c]) => c);
if (cold.length) {
  out.push('\n### Cold versus warm start (ms)\n');
  out.push('| Arm | Workspace create p50 / p95 | First request p50 / p95 | Warm p50 / p95 | After 180 s idle p50 / p95 | Rewarm p50 / p95 |');
  out.push('|---|---|---|---|---|---|');
  for (const [a, c] of cold) {
    const l = c.latency; const f = (k) => (l[k] ? `${ms(l[k].p50)} / ${ms(l[k].p95)}` : '–');
    out.push(`| ${ARM_NAME[a]} | ${f('create')} | ${f('first')} | ${f('warm')} | ${f('after_idle')} | ${f('rewarm')} |`);
  }
}

out.push('\n### Resources per suite (Relaycast-side pods; RDS from CloudWatch)\n');
out.push('| Arm | Suite | CPU peak / mean (m) | Memory peak (MiB) | RDS CPU peak % | RDS connections peak | RDS write IOPS peak |');
out.push('|---|---|---|---|---|---|---|');
for (const a of ARMS) for (const suite of dirs(join(RES, a))) {
  const r = resources(a, suite);
  if (r) out.push(`| ${ARM_NAME[a]} | ${suite} | ${r.cpu_peak_m} / ${r.cpu_mean_m} | ${r.mem_peak_mi} | ${fmt(r.rds_cpu_peak, 1)} | ${fmt(r.rds_conns_peak)} | ${fmt(r.rds_wiops_peak)} |`);
}

const md = out.join('\n') + '\n';
const csvRows = rows.map(({ other_routes, replay, drain, reconnect, ...r }) => r);
const csv = csvRows.length ? [Object.keys(csvRows[0]).join(','), ...csvRows.map((r) => Object.values(r).map((v) => (v ?? '')).join(','))].join('\n') + '\n' : '';
if (process.argv.includes('--write')) {
  writeFileSync(join(RES, 'comparison.csv'), csv);
  const doc = readFileSync(DOC, 'utf8');
  const re = /<!-- results:start -->[\s\S]*<!-- results:end -->/;
  if (!re.test(doc)) throw new Error('doc has no results markers');
  writeFileSync(DOC, doc.replace(re, `<!-- results:start -->\n${md}<!-- results:end -->`));
  console.error(`wrote ${rows.length} rows`);
} else process.stdout.write(md);
