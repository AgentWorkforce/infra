// Local isolated fixture only. Credentials and response bodies never enter reports.
import fs from 'node:fs';
import { randomUUID } from 'node:crypto';
import { performance, monitorEventLoopDelay } from 'node:perf_hooks';

const base = 'http://relaycast-bench.relaycast-bench.svc:8787';
const config = JSON.parse(fs.readFileSync('/scripts/config.json', 'utf8'));
const internal = fs.readFileSync('/credentials/internal', 'utf8').trim();
const workspaces = [], sockets = new Set(), socketKeys = new Map(), pendingMarkers = new Map();
const deliveryMs = [];
const calibrated = new Map();
let sequence = 0, totalFrames = 0, socketsOpened = 0, socketsClosed = 0, socketAcks = 0;
let lastSetupOperation = null;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const quantiles = values => {
  const sorted = [...values].sort((a, b) => a - b);
  return Object.fromEntries([.5, .95, .99].map(q => ['p' + Math.round(q * 100), sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] : null]));
};
async function http(method, path, token, body, headers = {}) {
  const response = await fetch(base + path, {method,
    headers: {authorization: 'Bearer ' + token, 'content-type': 'application/json', ...headers},
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(10000)});
  const text = await response.text();
  let json;
  try { json = text ? JSON.parse(text) : null; } catch { json = null; }
  return {status: response.status, data: json?.data};
}
async function required(method, path, token, body) {
  lastSetupOperation = method + ' ' + path;
  const result = await http(method, path, token, body);
  if (result.status < 200 || result.status >= 300) throw Error('fixture_request_failed_' + result.status);
  return result.data;
}
function marker() {
  const value = 'bench-' + sequence++;
  if (pendingMarkers.size < 10000) pendingMarkers.set(value, performance.now());
  return value;
}
function socket(path, token, node) {
  return new Promise((resolve, reject) => {
    const key = path + ':' + (node?.nodeId ?? token);
    const ws = new WebSocket(base.replace(/^http/, 'ws') + path + '?token=' + encodeURIComponent(token));
    const timer = setTimeout(() => { ws.close(); reject(Error('socket_timeout')); }, 10000);
    ws.addEventListener('error', () => {clearTimeout(timer); reject(Error('socket_failed'));}, {once: true});
    ws.addEventListener('open', () => {
      clearTimeout(timer); socketsOpened++;
      if (path === '/v1/node/ws') ws.send(JSON.stringify({v: 1, id: 'bench-register-' + sequence++, type: 'node.register',
        node_id: node.nodeId, name: node.nodeName, capabilities: [], max_agents: 1, tags: ['implicit', 'direct', 'sdk'], version: 'benchmark'}));
      // Bound concurrent sockets. Churn replaces a previous connection.
      const replaced = socketKeys.get(key) ?? (sockets.size >= config.population.websockets ? [...sockets][0] : null);
      if (replaced) {sockets.delete(replaced);replaced.close();}
      socketKeys.set(key, ws);
      sockets.add(ws); resolve({status: 101});
      const heartbeat = setInterval(() => {
        if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(path === '/v1/node/ws'
          ? {v: 1, type: 'node.heartbeat', node_id: node.nodeId} : {type: 'ping'}));
      }, 27000);
      ws.addEventListener('close', () => clearInterval(heartbeat), {once: true});
    }, {once: true});
    ws.addEventListener('close', () => {sockets.delete(ws); if (socketKeys.get(key) === ws) socketKeys.delete(key); socketsClosed++;});
    ws.addEventListener('message', event => {
      totalFrames++;
      const text = String(event.data);
      try {
        const frame = JSON.parse(text);
        if (frame.type === 'deliver' && typeof frame.agent === 'string' && Number.isFinite(frame.seq)) {
          ws.send(JSON.stringify({v: 1, type: 'delivery.ack', agent: frame.agent, up_to_seq: frame.seq}));socketAcks++;
        }
      } catch {}
      for (const match of text.matchAll(/bench-\d+/g)) {
        const sent = pendingMarkers.get(match[0]);
        if (sent !== undefined) {deliveryMs.push(performance.now() - sent); pendingMarkers.delete(match[0]);}
      }
    });
  });
}
async function setup() {
  for (let n = 0; n < config.population.workspaces; n++) {
    const created = await required('POST', '/internal/workspaces', internal, {name: 'benchmark-' + randomUUID()});
    const w = {key: created.api_key, id: created.workspace_id, agents: [], nodeEnrolls: new Map()};
    workspaces.push(w);
    for (let i = 0; i < config.population.agentsPerWorkspace; i++) {
      const agent = await required('POST', '/v1/agents', w.key, {name: 'bench-agent-' + i});
      const direct = await required('POST', '/v1/agent/node-token', agent.token, {});
      w.agents.push({...agent, name: 'bench-agent-' + i, nodeToken: direct.token, nodeId: direct.node_id, nodeName: direct.node_name});
    }
    const message = await required('POST', '/v1/channels/general/messages', w.agents[0].token, {text: 'benchmark seed'});
    w.messageId = message.id ?? message.message?.id;
    await required('POST', '/v1/dm', w.agents[0].token, {to: w.agents[1].name, text: 'benchmark DM seed'});
    const conversations = await required('GET', '/v1/dm/conversations', w.agents[0].token);
    w.dmId = (Array.isArray(conversations) ? conversations : conversations.conversations)?.[0]?.id;
    const observer = await required('POST', '/v1/observer-tokens', w.key,
      {name: 'benchmark observer', scopes: ['messages:read', 'dms:read', 'stream:read']});
    w.observerToken = observer.token;
    // Dedicated disposable identities keep destructive/credential-churn routes
    // from invalidating the agents used for polling and connected sockets.
    w.spare = await required('POST', '/v1/agents', w.key, {name: 'bench-churn'});
    if (!w.messageId || !w.dmId || !w.observerToken) throw Error('fixture_response_shape');
  }
  // An actor-backed round trip is a prerequisite, not inferred from readiness.
  const w = workspaces[0], text = 'roundtrip-' + randomUUID();
  await required('POST', '/v1/channels/general/messages', w.agents[0].token, {text});
  const seen = await required('GET', '/v1/channels/general/messages', w.agents[1].token);
  if (!JSON.stringify(seen).includes(text)) throw Error('actor_roundtrip_missing');
  for (let i = 0; i < config.population.websockets; i++) {
    const workspace = workspaces[i % workspaces.length];
    const agent = workspace.agents[Math.floor(i / workspaces.length) % workspace.agents.length];
    await socket('/v1/node/ws', agent.nodeToken, agent);
  }
}

// Routes requiring a hosted-only control-plane mount, signed Relayfile input,
// terminal or actual spawn invocation are not replaced with a cheap GET.
function binding(route, index) {
  const w = workspaces[index % workspaces.length], a = w.agents[Math.floor(index / workspaces.length) % w.agents.length];
  const b = w.agents[(Math.floor(index / workspaces.length) + 1) % w.agents.length];
  let path = route.pathTemplate, token = a.token, body;
  if (path.startsWith('/internal/') || path.startsWith('/v1/integrations/') || path.startsWith('/v1/actions/')
      || path === '/v1/node/terminal/ws' || path === '/v1/agents/:id/takeover'
      || path === '/v1/workspaces' || route.method === 'DELETE'
      || (path === '/v1/agents/:id' && route.method === 'POST')) return null;
  if (path === '/v1/node/ws') return () => socket(path, a.nodeToken, a);
  if (path === '/v1/ws') return () => socket(path, w.observerToken);
  if (['/v1/agents', '/v1/workspace', '/v1/workspace/events', '/v1/nodes', '/v1/observer-tokens'].includes(path)) token = w.key;
  if (path.startsWith('/v1/agents/:id')) {path = path.replace(':id', a.name); token = w.key;}
  if (path.startsWith('/v1/messages/:id')) path = path.replace(':id', w.messageId);
  if (path === '/v1/dm/:id/messages') {path = path.replace(':id', w.dmId); token = w.agents[0].token;}
  path = path.replace(':channel', 'general');
  if (route.method === 'POST') {
    if (path === '/v1/agents/heartbeat') body = {};
    else if (path === '/v1/agents') body = {name: 'bench-register-' + (index % 20)};
    else if (path === '/v1/agent/node-token') {token = w.spare.token; body = {};}
    else if (path === '/v1/nodes') {
      const name = 'bench-node-' + (index % 20);
      if (!w.nodeEnrolls.has(name)) w.nodeEnrolls.set(name, {pending: Promise.resolve()});
      const entry = w.nodeEnrolls.get(name);
      return () => {
        const pending = entry.pending.then(async () => {
          const response = await http('POST', path, w.key, {name, kind: 'ws'}, entry.token ? {'X-Relaycast-Node-Token': entry.token} : {});
          if (response.data?.token) entry.token = response.data.token;
          return response;
        });
        entry.pending = pending.catch(() => {});
        return pending;
      };
    }
    else if (path === '/v1/dm') body = {to: b.name, text: '$MARKER'};
    else if (path.endsWith('/messages') || path.endsWith('/replies')) body = {text: '$MARKER'};
    else if (path.endsWith('/read') || path.endsWith('/join')) body = {};
    else if (path === '/v1/observer-tokens') body = {name: 'observer-' + index, scopes: ['messages:read', 'stream:read']};
    else return null;
  } else if (route.method === 'PATCH') body = {status: 'idle'};
  return () => http(route.method, path, token, body?.text === '$MARKER' ? {...body, text: marker()} : body);
}

async function step(input) {
  const routes = input.routes.map(route => ({...route, scheduled: 0, completed: 0, completedInWindow: 0, dropped: 0,
    status: {}, latencies: [], supported: binding(route, 0) !== null}));
  for (const route of routes) {
    const key = route.method + ' ' + route.pathTemplate;
    if (!calibrated.has(key)) {
      if (route.supported) {
        try {
          const probe = await binding(route, 0)();
          route.probeStatus = probe.status;
          if (probe.status !== 101 && !(probe.status >= 200 && probe.status < 300)) route.supported = false;
        } catch {route.supported = false;route.probeStatus = 'network_error';}
      }
      calibrated.set(key, {supported: route.supported, probeStatus: route.probeStatus ?? 'not_bound'});
    }
    Object.assign(route, calibrated.get(key));
  }
  const lag = monitorEventLoopDelay({resolution: 10});lag.enable();
  const cpu = process.cpuUsage(), start = performance.now();
  let inflight = 0, index = 0, maximumInflight = 0, maximumLagMs = 0;
  const outstanding = new Set();
  function launch(route) {
    route.scheduled++;
    if (inflight >= config.maxInflight) {route.dropped++;return;}
    const operation = binding(route, index++), before = performance.now();
    inflight++; maximumInflight = Math.max(maximumInflight, inflight);
    const promise = operation().then(response => {
      route.status[response.status] = (route.status[response.status] ?? 0) + 1;
    }).catch(() => {route.status.network_error = (route.status.network_error ?? 0) + 1;}).finally(() => {
      route.completed++;inflight--;
      if (performance.now() - start <= config.seconds * 1000) route.completedInWindow++;
      if (route.latencies.length < 100000) route.latencies.push(performance.now() - before);
      outstanding.delete(promise);
    });
    outstanding.add(promise);
  }
  while (performance.now() - start < config.seconds * 1000) {
    const elapsed = (performance.now() - start) / 1000;
    for (const route of routes.filter(r => r.supported)) {
      const due = Math.floor(Math.min(config.seconds, elapsed) * route.targetRps) - route.scheduled;
      if (due > 0) maximumLagMs = Math.max(maximumLagMs, (elapsed - (route.scheduled + 1) / route.targetRps) * 1000);
      // Skip an overloaded generator's backlog explicitly, rather than hide a
      // coordinated-omission gap behind a closed-loop request count.
      for (let n = 0; n < Math.min(due, 1000); n++) launch(route);
      if (due > 1000) {route.scheduled += due - 1000;route.dropped += due - 1000;}
    }
    await delay(5);
  }
  const offeredSeconds = (performance.now() - start) / 1000;
  await Promise.allSettled([...outstanding]);
  const drainSeconds = (performance.now() - start) / 1000 - offeredSeconds;
  const used = process.cpuUsage(cpu);lag.disable();
  const result = routes.map(route => ({method: route.method, pathTemplate: route.pathTemplate,
    supported: route.supported, probeStatus: route.probeStatus ?? 'not_bound', intendedRps: route.targetRps, scheduled: route.scheduled,
    completed: route.completed, completedInWindow: route.completedInWindow, droppedByGenerator: route.dropped,
    achievedRps: route.completedInWindow / offeredSeconds,
    status: route.status, latencyMs: quantiles(route.latencies), latencySamples: route.latencies.length}));
  const completed = routes.reduce((n, r) => n + r.completed, 0);
  const supportedRps = routes.filter(r => r.supported).reduce((n, r) => n + r.targetRps, 0);
  const bad = routes.reduce((n, r) => n + Object.entries(r.status).filter(([code]) => code !== '101' && !(Number(code) >= 200 && Number(code) < 300)).reduce((m, [, count]) => m + count, 0), 0);
  const latencyMs = quantiles(routes.flatMap(r => r.latencies));
  const dropped = routes.reduce((n, r) => n + r.dropped, 0);
  const achievedRps = routes.reduce((n, r) => n + r.completedInWindow, 0) / offeredSeconds;
  const generatorLimited = dropped > 0 || lag.percentile(99) / 1e6 > 25 || maximumLagMs > 100;
  const sloPass = completed > 0 && bad / completed <= .01 && achievedRps >= supportedRps * .95
    && latencyMs.p95 <= 200 && drainSeconds <= 5 && !generatorLimited;
  return {requestedScale: input.requestedScale, requestedGlobalRps: input.requestedPeakRps,
    startedAt: new Date(performance.timeOrigin + start).toISOString(),
    offeredSupportedRps: supportedRps, routeCoverageShare: supportedRps / input.targetPeakRps,
    populationMode: 'fixed_assumed', seconds: offeredSeconds, completed,
    achievedRps, latencyMs, sloPass,
    limitSignal: generatorLimited ? 'generator_limited' : sloPass ? 'none' : 'backend_or_policy_limit',
    drainAdjustedRps: completed / (offeredSeconds + drainSeconds),
    errorFraction: completed ? bad / completed : 1, drainSeconds, maximumInflight,
    activeSocketsAtEnd: sockets.size,
    generator: {cpuSeconds: (used.user + used.system) / 1e6, maximumScheduleLagMs: maximumLagMs,
      eventLoopP99Ms: lag.percentile(99) / 1e6, rssBytes: process.memoryUsage().rss,
      dropped}, routes: result};
}

const report = {schema: 'agent-relay.actor-benchmark/v1', status: 'fail', startedAt: new Date().toISOString(),
  workloadKind: config.plan.workloadKind ?? 'production_replay',
  productionReplay: 'partial until every hosted route has a valid self-host binding',
  population: config.population, populationMode: 'fixed_assumed', planSha256: config.plan.profileSha256,
  harness: config.harness,
  payloadModel: 'short synthetic messages and default API pagination; hosted payload sizes unmeasured',
  actorAnalytics: 'unsupported_skipped', steps: []};
report.slo = {maximumErrorFraction: .01, minimumAchievedFraction: .95, maximumP95Ms: 200,
  maximumDrainSeconds: 5, maximumGeneratorLoopP99Ms: 25, maximumGeneratorScheduleLagMs: 100, maximumGeneratorDrops: 0};
try {
  await setup();report.actorMessageRoundTrip = true;
  for (const input of config.plan.steps) {
    const result = await step(input);report.steps.push(result);
    console.log(JSON.stringify({event: 'step_finished', requestedRps: result.requestedGlobalRps,
      supportedRps: result.offeredSupportedRps, achievedRps: result.achievedRps, p95Ms: result.latencyMs.p95,
      errorFraction: result.errorFraction, limitSignal: result.limitSignal}));
    await delay(10000);
  }
  try {
    const w = workspaces[0], text = 'postload-' + randomUUID();
    await required('POST', '/v1/channels/general/messages', w.agents[0].token, {text});
    report.postLoadMessageRoundTrip = JSON.stringify(await required('GET', '/v1/channels/general/messages', w.agents[1].token)).includes(text);
  } catch {report.postLoadMessageRoundTrip = false;}
  report.status = 'measured';
} catch (error) {
  report.failure = 'fixture_or_generator_failed';
  report.failureCode = /^[a-z_]+(?:_\d{3})?$/.test(error?.message ?? '') ? error.message : 'unexpected_error';
  report.lastSetupOperation = lastSetupOperation;
} finally {
  for (const ws of sockets) ws.close();
  report.websockets = {opened: socketsOpened, closed: socketsClosed, frames: totalFrames,
    deliveryAcks: socketAcks, deliveredMarkers: deliveryMs.length, deliveryMs: quantiles(deliveryMs), pendingMarkers: pendingMarkers.size};
  report.workspaceCleanup = {deleted: 0, failed: 0};
  for (const w of workspaces) {
    try {
      const response = await http('DELETE', '/internal/workspaces/' + encodeURIComponent(w.id), internal);
      report.workspaceCleanup[response.status === 204 ? 'deleted' : 'failed']++;
    } catch {report.workspaceCleanup.failed++;}
  }
  report.finishedAt = new Date().toISOString();
  fs.writeFileSync('/results/report.json', JSON.stringify(report), {mode: 0o600});
  // Keep the pod available for its read-only result collector.
  setInterval(() => {}, 60000);
}
