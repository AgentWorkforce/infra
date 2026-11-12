#!/usr/bin/env node
// Seed, snapshot and compare a Relaycast for the PostgreSQL -> durable-actors
// migration proof (relaycast-pg-to-actors-proof.sh). Zero dependencies (Node 22).
//
//   node relaycast-pg-to-actors.mjs seed     <base url> <state dir>
//   node relaycast-pg-to-actors.mjs snapshot <base url> <state dir> <name>
//   node relaycast-pg-to-actors.mjs compare  <base url> <state dir> <before> <after>
//   node relaycast-pg-to-actors.mjs write    <base url> <state dir>
//   node relaycast-pg-to-actors.mjs realtime <base url> <state dir>
//
// The internal secret is read from <state dir>/internal-secret. Credentials go
// to <state dir>/seed.json (0600) and are never printed; output is counts,
// ids and digests. Signed file URLs point at the in-cluster origin; their
// path and query are replayed against <base url> (the same server).
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const [mode, base, dir, ...rest] = process.argv.slice(2);
if (!mode || !base || !dir) {
  console.error('usage: relaycast-pg-to-actors.mjs seed|snapshot|compare|write <base url> <state dir> ...');
  process.exit(64);
}
const sha = (data) => createHash('sha256').update(data).digest('hex');

async function api(method, path, token, body) {
  for (let attempt = 1; ; attempt += 1) {
    const response = await fetch(`${base}${path}`, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    // PostgreSQL deadlocks under concurrent channel posts (relaycast#651): retry 5xx.
    if (response.status >= 500 && attempt < 6) { await new Promise((r) => setTimeout(r, 250 * attempt)); continue; }
    let json; try { json = JSON.parse(text); } catch { json = { raw: text.slice(0, 200) }; }
    return { status: response.status, json };
  }
}
async function must(method, path, token, body, expect = [200, 201]) {
  const { status, json } = await api(method, path, token, body);
  if (!expect.includes(status)) throw new Error(`${method} ${path}: HTTP ${status} ${JSON.stringify(json).slice(0, 300)}`);
  return json.data;
}
const local = (url) => { const u = new URL(url); return `${base}${u.pathname}${u.search}`; };

async function seed() {
  const internal = (await readFile(join(dir, 'internal-secret'), 'utf8')).trim();
  const state = { workspaces: [] };
  for (const [w, name] of ['armadillo', 'bison'].entries()) {
    const ws = await must('POST', '/internal/workspaces', internal, { name });
    const entry = { id: ws.workspace_id, key: ws.api_key, agents: {}, channels: [], messages: [], files: [] };
    state.workspaces.push(entry);
    const names = Array.from({ length: 12 }, (_, i) => `agent-${w}-${i}`);
    for (const agent of names) entry.agents[agent] = (await must('POST', '/v1/agents', entry.key, { name: agent })).token;
    const tokens = names.map((n) => entry.agents[n]);
    for (const channel of ['ops', 'deploys', 'research', 'random']) {
      await must('POST', '/v1/channels', tokens[0], { name: channel, topic: `${channel} for ${name}` });
      for (const t of tokens.slice(1)) await must('POST', `/v1/channels/${channel}/join`, t, {});
      entry.channels.push(channel);
    }
    // History, one writer at a time (relaycast#651).
    for (let i = 0; i < 240; i += 1) {
      const channel = entry.channels[i % entry.channels.length];
      const m = await must('POST', `/v1/channels/${channel}/messages`, tokens[i % tokens.length], { text: `${channel} #${i} ${'lorem '.repeat(i % 7)}` });
      entry.messages.push(m.id);
    }
    for (let i = 0; i < 30; i += 1) await must('POST', `/v1/messages/${entry.messages[i * 3]}/replies`, tokens[(i + 1) % tokens.length], { text: `reply ${i}` });
    for (let i = 0; i < 30; i += 1) await must('POST', `/v1/messages/${entry.messages[i * 5]}/reactions`, tokens[(i + 2) % tokens.length], { emoji: ['tada', 'eyes', 'rocket'][i % 3] });
    for (let i = 0; i < 20; i += 1) await must('POST', `/v1/messages/${entry.messages[i]}/read`, tokens[3], {}, [200, 201, 204]);
    for (let i = 0; i < 40; i += 1) await must('POST', '/v1/dm', tokens[i % 4], { to: names[4 + (i % 6)], text: `dm ${i}` });
    for (let i = 0; i < 3; i += 1) {
      const bytes = Buffer.from(`file ${i} of ${name}\n`.repeat(200 * (i + 1)));
      const up = await must('POST', '/v1/files/upload', tokens[i], { filename: `notes-${i}.txt`, content_type: 'text/plain', size_bytes: bytes.length });
      const put = await fetch(local(up.upload_url), { method: 'PUT', headers: { 'content-type': 'text/plain' }, body: bytes });
      if (!put.ok) throw new Error(`upload PUT: HTTP ${put.status}`);
      const done = await must('POST', `/v1/files/${up.id}/complete`, tokens[i], {});
      entry.files.push({ id: done.id, sha256: sha(bytes), uploader: names[i] });
      await must('POST', '/v1/channels/ops/messages', tokens[i], { text: `see ${done.filename}`, attachments: [done.id] });
    }
    await must('POST', '/v1/webhooks', entry.key, { name: 'ci', channel: 'deploys' });
    await must('POST', '/v1/subscriptions', entry.key, { events: ['message.created'], url: 'https://hooks.example.com/relaycast' });
    // Realtime goes through observer tokens (/v1/ws) and node tokens (/v1/node/ws); minted here, before the move.
    entry.observer = (await must('POST', '/v1/observer-tokens', entry.key, { name: 'proof-stream', scopes: ['stream:read', 'messages:read', 'channels:read'] })).token;
    console.log(`seeded workspace ${entry.id}: ${names.length} agents, ${entry.channels.length} channels, ${entry.messages.length} channel messages + 30 replies, 30 reactions, 40 DMs, ${entry.files.length} files, 1 webhook, 1 subscription, 1 observer token`);
  }
  await writeFile(join(dir, 'seed.json'), JSON.stringify(state), { mode: 0o600 });
}

/** Fields computed at read time from the clock or live presence, not stored. */
function strip(value) {
  if (Array.isArray(value)) return value.map(strip);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value)
      .filter(([k]) => !['online', 'presence', 'is_online', 'status', 'last_seen', 'download_url', 'expires_at'].includes(k))
      .map(([k, v]) => [k, strip(v)]));
  }
  return value;
}

async function snapshot(name) {
  const state = JSON.parse(await readFile(join(dir, 'seed.json'), 'utf8'));
  const out = {};
  for (const ws of state.workspaces) {
    const tokens = Object.values(ws.agents);
    const reads = {
      agents: ['/v1/agents', ws.key],
      channels: ['/v1/channels', tokens[1]],
      inbox: ['/v1/inbox', tokens[5]],
      dms: ['/v1/dm/conversations', tokens[0]],
      thread: [`/v1/messages/${ws.messages[3]}/replies`, tokens[2]],
      files: ['/v1/files', ws.key],
    };
    for (const channel of ws.channels) reads[`channel:${channel}`] = [`/v1/channels/${channel}/messages?limit=100`, tokens[1]];
    for (const [label, [path, token]] of Object.entries(reads)) {
      const { status, json } = await api('GET', path, token);
      out[`${ws.id} ${label}`] = { status, body: strip(json) };
    }
    for (const file of ws.files) {
      const meta = await must('GET', `/v1/files/${file.id}`, ws.key);
      const bytes = Buffer.from(await (await fetch(local(meta.download_url))).arrayBuffer());
      out[`${ws.id} file:${file.id}`] = { status: 200, body: { sha256: sha(bytes), expected: file.sha256 } };
    }
  }
  await writeFile(join(dir, `snapshot-${name}.json`), JSON.stringify(out, null, 1), { mode: 0o600 });
  const bad = Object.entries(out).filter(([, v]) => v.status !== 200 || (v.body.expected && v.body.expected !== v.body.sha256));
  console.log(`snapshot ${name}: ${Object.keys(out).length} reads, ${bad.length} failed${bad.length ? `: ${bad.map(([k]) => k).join(', ')}` : ''}`);
  if (bad.length) process.exit(1);
}

/**
 * Lists whose order the engine leaves to the database, so PostgreSQL and
 * SQLite may differ: the inbox's unread_channels and a DM's participants (no
 * ORDER BY) and the inbox's recent_reactions (ordered by a one-second
 * created_at, no tiebreak). Compared as sets (sorted by their key); every
 * other list keeps its order, and any difference in the members still fails.
 */
const UNORDERED = {
  unread_channels: (r) => r.channel_name,
  participants: (r) => r.agent_id,
  recent_reactions: (r) => `${r.created_at} ${r.message_id} ${r.emoji} ${r.agent_name}`,
};
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => {
      const c = canonical(v);
      return [k, Array.isArray(c) && UNORDERED[k] ? [...c].sort((x, y) => String(UNORDERED[k](x)).localeCompare(String(UNORDERED[k](y)))) : c];
    }));
  }
  return value;
}

async function compare(before, after) {
  const a = JSON.parse(await readFile(join(dir, `snapshot-${before}.json`), 'utf8'));
  const b = JSON.parse(await readFile(join(dir, `snapshot-${after}.json`), 'utf8'));
  const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])].sort();
  const exact = keys.filter((k) => JSON.stringify(a[k]) === JSON.stringify(b[k]));
  const diff = keys.filter((k) => JSON.stringify(canonical(a[k])) !== JSON.stringify(canonical(b[k])));
  const reordered = keys.length - exact.length - diff.length;
  console.log(`compare ${before} -> ${after}: ${exact.length}/${keys.length} reads byte-identical, ${reordered} identical up to the order of unordered lists (${Object.keys(UNORDERED).join(', ')})${diff.length ? `; DIFFER: ${diff.join(', ')}` : ''}`);
  for (const k of diff.slice(0, 3)) console.log(`  ${k}\n    before ${JSON.stringify(a[k]).slice(0, 400)}\n    after  ${JSON.stringify(b[k]).slice(0, 400)}`);
  if (diff.length) process.exit(1);
}

async function write() { // messaging works after the move, with the pre-move credentials
  const state = JSON.parse(await readFile(join(dir, 'seed.json'), 'utf8'));
  for (const ws of state.workspaces) {
    const tokens = Object.values(ws.agents);
    const names = Object.keys(ws.agents);
    const posted = await must('POST', '/v1/channels/ops/messages', tokens[2], { text: 'after the move' });
    await must('POST', '/v1/dm', tokens[0], { to: names[7], text: 'dm after the move' });
    const read = await must('GET', '/v1/channels/ops/messages?limit=1', tokens[1]);
    if (read[0]?.id !== posted.id) throw new Error(`${ws.id}: the new message is not the newest`);
    const agent = await must('POST', '/v1/agents', ws.key, { name: `late-${ws.id.slice(-4)}` });
    await must('POST', '/v1/channels/ops/join', agent.token, {});
    console.log(`write ${ws.id}: post, DM, read-back and a new agent work with pre-move credentials`);
  }
}

async function realtime() { // a realtime round trip: a pre-move observer token on /v1/ws sees a new post
  const state = JSON.parse(await readFile(join(dir, 'seed.json'), 'utf8'));
  for (const ws of state.workspaces) {
    const tokens = Object.values(ws.agents);
    const text = `realtime ${Date.now()}`;
    const socket = new WebSocket(`${base.replace(/^http/, 'ws')}/v1/ws?token=${encodeURIComponent(ws.observer)}`);
    const received = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${ws.id}: no realtime event within 20s`)), 20_000);
      socket.addEventListener('message', (event) => {
        if (String(event.data).includes(text)) { clearTimeout(timer); resolve(); }
      });
      socket.addEventListener('close', (event) => { clearTimeout(timer); reject(new Error(`${ws.id}: socket closed ${event.code} ${event.reason}`)); });
    });
    await new Promise((resolve, reject) => { socket.addEventListener('open', resolve); socket.addEventListener('error', () => reject(new Error(`${ws.id}: WebSocket upgrade failed`))); });
    socket.send(JSON.stringify({ type: 'subscribe', channels: ['ops'] }));
    await new Promise((r) => setTimeout(r, 1000));
    await must('POST', '/v1/channels/ops/messages', tokens[2], { text });
    await received;
    socket.close();
    console.log(`realtime ${ws.id}: a pre-move observer token streamed a new post over /v1/ws`);
  }
}

if (mode === 'seed') await seed();
else if (mode === 'realtime') await realtime();
else if (mode === 'snapshot') await snapshot(rest[0]);
else if (mode === 'compare') await compare(rest[0], rest[1]);
else if (mode === 'write') await write();
else { console.error(`unknown mode ${mode}`); process.exit(64); }
