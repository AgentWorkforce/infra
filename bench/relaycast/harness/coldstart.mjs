#!/usr/bin/env node
// Cold versus warm request latency per workspace. On the actors arm each
// workspace is one Workspace actor: the first request after creation, and the
// first after the actor host has been idle past durable-actors
// actors.hostIdleTimeoutMs, pay activation. On the Postgres arm the same
// sequence is the baseline (no activation step).
//
// Per workspace, sequentially (so activations do not overlap):
//   create      POST /internal/workspaces
//   first       first POST /v1/agents (cold on actors)
//   warm        the next 5 GET /v1/agent calls
// then after RCB_IDLE_WAIT_S (default 180 s > the 120 s idle timeout):
//   after_idle  first GET /v1/agent per workspace
//   rewarm      the next 5 GET /v1/agent calls
import { env, envInt, httpClient, readSecretFile, writeJsonAtomic, HistMap, Counter, log, sleep } from './lib.mjs';

const base = env('RCB_BASE_URL');
const internal = readSecretFile(env('RCB_INTERNAL_SECRET_FILE'));
const run = env('RCB_RUN');
const N = envInt('RCB_COLD_WORKSPACES', 20);
const IDLE = envInt('RCB_IDLE_WAIT_S', 180);
const call = httpClient(base, { timeoutMs: 120000 });
const h = new HistMap();
const status = new Counter();
const rows = [];

async function timed(label, method, path, token, body) {
  const r = await call(method, path, token, body);
  h.add(label, r.ms); status.inc(`${label} ${r.status}`);
  return r;
}

const wss = [];
for (let i = 0; i < N; i++) {
  const c = await timed('create', 'POST', '/internal/workspaces', internal, { name: `rcb-${run}-cold-${i}` });
  if (c.status !== 201) { log(`create ${i}: ${c.status}`); continue; }
  const key = c.body.data.api_key;
  const first = await timed('first', 'POST', '/v1/agents', key, { name: 'cold-a' });
  if (first.status !== 201) { log(`first ${i}: ${first.status}`); continue; }
  const tok = first.body.data.token;
  const warm = [];
  for (let k = 0; k < 5; k++) warm.push((await timed('warm', 'GET', '/v1/agent', tok)).ms);
  wss.push({ i, tok, workspaceId: c.body.data.workspace_id });
  rows.push({ i, create: c.ms, first: first.ms, warm });
}
log(`created ${wss.length}; idling ${IDLE}s`);
await sleep(IDLE * 1000);
for (const w of wss) {
  const a = await timed('after_idle', 'GET', '/v1/agent', w.tok);
  const re = [];
  for (let k = 0; k < 5; k++) re.push((await timed('rewarm', 'GET', '/v1/agent', w.tok)).ms);
  Object.assign(rows.find((r) => r.i === w.i), { afterIdle: a.ms, rewarm: re });
}
const result = { kind: 'coldstart', run, idleWaitS: IDLE, status: status.toJSON(),
  latency: Object.fromEntries([...h.m].map(([k, x]) => [k, x.summary()])), rows };
writeJsonAtomic(env('RCB_OUT'), result);
log('coldstart done', result.latency);
