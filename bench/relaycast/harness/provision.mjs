#!/usr/bin/env node
// Creates the benchmark fixture: workspaces (through the internal create
// route), producer agents, channels, nodes and the receiver plan, and records
// the latency of each control-plane route. Writes the fixture (it holds
// tokens: keep it in a Secret or a 0600 file, never in git or logs) to
// RCB_FIXTURE and timings to RCB_OUT.
//
// Env:
//   RCB_BASE_URL               Relaycast origin reachable from the load pods
//   RCB_INTERNAL_SECRET_FILE   file holding RELAYCAST_INTERNAL_SECRET
//   RCB_RUN                    run id (names are rcb-<run>-<n>)
//   RCB_WORKSPACES             workspaces (default 1)
//   RCB_PRODUCERS              producer agents per workspace (default 5)
//   RCB_RECEIVERS              receiver agents per workspace (default 5)
//   RCB_AGENTS_PER_NODE        receivers per node socket (default 1)
//   RCB_CHANNELS               channels per workspace (default 2)
//   RCB_CHANNEL_MEMBERS        receivers joined to each channel (default min(10, receivers))
//   RCB_FANOUT_MEMBERS         0, or members of a "fanout" channel in workspace 0
//   RCB_BACKLOG_RECEIVERS      receivers in workspace 0 used for backlog/reconnect tests (own node each)
//   RCB_SINK_SHARDS            sink pods; nodes are spread over them (default 1)
//   RCB_CONCURRENCY            parallel provisioning requests (default 16)
import { env, envInt, httpClient, readSecretFile, writeJsonAtomic, HistMap, Counter, log, hr } from './lib.mjs';

const base = env('RCB_BASE_URL');
const internal = readSecretFile(env('RCB_INTERNAL_SECRET_FILE'));
const run = env('RCB_RUN');
const W = envInt('RCB_WORKSPACES', 1);
const P = envInt('RCB_PRODUCERS', 5);
const R = envInt('RCB_RECEIVERS', 5);
const PER_NODE = envInt('RCB_AGENTS_PER_NODE', 1);
const C = envInt('RCB_CHANNELS', 2);
const CM = Math.min(envInt('RCB_CHANNEL_MEMBERS', Math.min(10, R)), R);
const FANOUT = envInt('RCB_FANOUT_MEMBERS', 0);
const BACKLOG = envInt('RCB_BACKLOG_RECEIVERS', 0);
const SHARDS = envInt('RCB_SINK_SHARDS', 1);
const CONC = envInt('RCB_CONCURRENCY', 16);
// 1: every producer is also bound to its own node socket (held by the sinks),
// so every channel member is delivery-ready (no queued/retried deliveries to
// HTTP-only members). Default 0: producers are HTTP-only members.
const PRODUCERS_ON_NODES = envInt('RCB_PRODUCERS_ON_NODES', 0) === 1;
if (FANOUT > R) throw new Error(`RCB_FANOUT_MEMBERS ${FANOUT} > RCB_RECEIVERS ${R}`);

const call = httpClient(base, { timeoutMs: 60000 });
const lat = new HistMap();
const status = new Counter();

async function req(route, method, path, token, body, okStatuses = [200, 201]) {
  for (let attempt = 0; attempt < 8; attempt++) {
    const r = await call(method, path, token, body);
    lat.add(route, r.ms);
    status.inc(`${route} ${r.status}`);
    if (okStatuses.includes(r.status)) return r.body?.data ?? r.body;
    if (r.status === 429 || r.status === 0 || r.status >= 500) {
      await new Promise((s) => setTimeout(s, Math.min(30000, 500 * 2 ** attempt)));
      continue;
    }
    throw new Error(`${route}: HTTP ${r.status} ${JSON.stringify(r.body?.error ?? r.error)}`);
  }
  throw new Error(`${route}: retries exhausted`);
}

async function pool(items, fn) {
  const out = new Array(items.length);
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(CONC, items.length) }, async () => {
    while (i < items.length) { const k = i++; out[k] = await fn(items[k], k); }
  }));
  return out;
}

const t0 = hr();
const fixture = { version: 1, run, baseUrl: base, createdAt: new Date().toISOString(), shards: SHARDS, workspaces: [] };

const wsList = await pool([...Array(W).keys()], async (i) => {
  const ws = await req('POST /internal/workspaces', 'POST', '/internal/workspaces', internal, { name: `rcb-${run}-${i}` });
  return { i, id: ws.workspace_id, key: ws.api_key };
});
log(`created ${W} workspaces`);

for (const ws of wsList) {
  const producers = await pool([...Array(P).keys()], async (p) => {
    const a = await req('POST /v1/agents', 'POST', '/v1/agents', ws.key, { name: `p${p}` });
    return { name: `p${p}`, id: a.id, token: a.token };
  });
  const receivers = [...Array(R).keys()].map((r) => `r${r}`);
  const backlog = ws.i === 0 ? [...Array(BACKLOG).keys()].map((b) => `b${b}`) : [];
  const channels = [];
  for (let c = 0; c < C; c++) {
    const members = [...Array(CM).keys()].map((m) => receivers[(c * CM + m) % R]);
    channels.push({ name: `c${c}`, members: [...new Set(members)] });
  }
  if (ws.i === 0 && FANOUT > 0) channels.push({ name: 'fanout', members: receivers.slice(0, FANOUT), fanout: true });
  await pool(channels, (ch) => req('POST /v1/channels', 'POST', '/v1/channels', ws.key, { name: ch.name }));
  // Every producer joins every channel so any producer can post anywhere.
  await pool(channels.flatMap((ch) => producers.map((p) => [ch, p])), ([ch, p]) =>
    req('POST /v1/channels/:name/join', 'POST', `/v1/channels/${ch.name}/join`, p.token));
  // Nodes: receivers grouped PER_NODE to a socket; backlog receivers get one each.
  const groups = [];
  for (let k = 0; k < receivers.length; k += PER_NODE) groups.push(receivers.slice(k, k + PER_NODE));
  for (const b of backlog) groups.push([b]);
  const nodes = await pool(groups, async (agents, n) => {
    const name = `n${n}`;
    const nd = await req('POST /v1/nodes', 'POST', '/v1/nodes', ws.key, { name, max_agents: Math.max(agents.length, 1) });
    return { name, id: nd.id, token: nd.token, agents, shard: (ws.i * 7919 + n) % SHARDS, backlog: agents[0]?.startsWith('b') };
  });
  if (PRODUCERS_ON_NODES) {
    const bound = await pool(producers, async (p, k) => {
      const name = `np${k}`;
      const nd = await req('POST /v1/nodes', 'POST', '/v1/nodes', ws.key, { name, max_agents: 1 });
      await req('POST /v1/nodes/:name/agents', 'POST', `/v1/nodes/${name}/agents`, ws.key, { agent_name: p.name });
      return { name, id: nd.id, token: nd.token, agents: [p.name], shard: (ws.i * 7919 + nodes.length + k) % SHARDS, bound: true };
    });
    nodes.push(...bound);
  }
  fixture.workspaces.push({ ...ws, producers, receivers, backlog, channels, nodes });
  log(`workspace ${ws.i}: ${P} producers, ${R} receivers, ${channels.length} channels, ${nodes.length} nodes`);
}

writeJsonAtomic(env('RCB_FIXTURE'), fixture);
const out = env('RCB_OUT', '');
const result = {
  kind: 'provision', run, params: { W, P, R, PER_NODE, C, CM, FANOUT, BACKLOG, SHARDS, PRODUCERS_ON_NODES },
  wallMs: hr() - t0, status: status.toJSON(),
  latency: Object.fromEntries([...lat.m].map(([k, h]) => [k, h.summary()])), hist: lat.toJSON(),
};
if (out) writeJsonAtomic(out, result);
log('provision done', { wallMs: Math.round(result.wallMs), latency: result.latency });
