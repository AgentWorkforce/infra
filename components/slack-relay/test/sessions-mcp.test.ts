// The agents' read-only Sessions tools against a fake relaygate Sessions proxy and a fake relay-control
// (relaygate docs/contract.md "Session uploads"; relay-control POST .../session-read/{session,refresh}).
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer, type IncomingHttpHeaders, type Server } from "node:http";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { handleRpc, MAX_OUTPUT, SessionsTools, sessionsMcpServer, TOOLS } from "../src/sessions-mcp.ts";
import { SessionReadCredential, SessionsReadProxy } from "../src/sessions-read.ts";
import type { SessionsCredential } from "../src/sessions-upload.ts";

const AGENT = "rg_agent_pit_token";
const OTHER = "rg_someone_else";
const DENIED = "sess-people-only";

interface Seen {
  method: string;
  path: string;
  query: URLSearchParams;
  headers: IncomingHttpHeaders;
}

async function listen(handler: (req: Seen, body: string) => { status: number; body: unknown }): Promise<{ server: Server; url: string; seen: Seen[] }> {
  const seen: Seen[] = [];
  const server = createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      const u = new URL(req.url ?? "/", "http://x");
      const s = { method: req.method ?? "", path: u.pathname, query: u.searchParams, headers: req.headers };
      seen.push(s);
      const a = handler(s, raw);
      res.writeHead(a.status, { "content-type": "application/json" }).end(typeof a.body === "string" ? a.body : JSON.stringify(a.body));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  return { server, url: `http://127.0.0.1:${(server.address() as { port: number }).port}`, seen };
}

/** relaygate's Sessions proxy: a 403 for the people-only session, canned pages otherwise. */
function gateAnswer(s: Seen): { status: number; body: unknown } {
  if (s.path.includes(DENIED) || s.query.get("session") === DENIED) return { status: 403, body: { error: "relaygate_denied" } };
  if (s.path === "/sessions/v1/sessions") return { status: 200, body: { sessions: [{ sessionId: "s1", title: "pit work" }], nextCursor: "c2" } };
  if (s.path.endsWith("/metadata")) return { status: 200, body: { sessionId: "s1", title: "pit work" } };
  if (s.path.endsWith("/brief")) return { status: 501, body: { error: "unsupported_by_backend" } };
  if (s.path.endsWith("/events")) return { status: 200, body: { sessionId: "s1", events: [{ eventId: "e1", content: "hello" }], nextCursor: null } };
  if (s.path === "/sessions/v1/events") return { status: 200, body: { events: [{ eventId: "e9", sessionId: "s1", content: "match" }], nextCursor: null } };
  return { status: 404, body: { error: "relaygate_route_not_proxied" } };
}

/** The uploader user's relay-control session. */
function control(): SessionsCredential & { invalidated: number } {
  const c = { invalidated: 0, get: async () => "sh_at_uploader", invalidate: () => void c.invalidated++ };
  return c;
}

let minted = 0;
function controlAnswer(s: Seen, body: string): { status: number; body: unknown } {
  assert.equal(s.headers.authorization, "Bearer sh_at_uploader");
  if (s.path.endsWith("/session-read/session")) {
    assert.deepEqual(JSON.parse(body), { label: "slack-relay agent session reads" });
    minted++;
    return { status: 200, body: { accessToken: `rth_at_read_${minted}`, accessTokenExpiresAt: new Date(Date.now() + 15 * 60_000).toISOString(), refreshToken: "rth_rt_read_x", refreshTokenExpiresAt: new Date(Date.now() + 86_400_000).toISOString() } };
  }
  if (s.path.endsWith("/session-read/refresh")) return { status: 401, body: { error: "invalid_refresh_token" } };
  return { status: 404, body: {} };
}

async function setup(gate = gateAnswer) {
  minted = 0;
  const g = await listen(gate);
  const ctl = await listen(controlAnswer);
  const logs: string[] = [];
  const credential = new SessionReadCredential({ controlUrl: ctl.url, workspaceId: "ws-1", control: control() });
  const proxy = new SessionsReadProxy({ baseUrl: `${g.url}/sessions`, workspaceId: "ws-1", credential, isAgentToken: (t) => t === AGENT, log: (m) => logs.push(m) });
  await proxy.listen();
  const tools = new SessionsTools({ proxyUrl: proxy.url, token: AGENT });
  const close = async () => {
    await proxy.close();
    g.server.close();
    ctl.server.close();
  };
  return { g, ctl, proxy, tools, logs, credential, close };
}

const out = (r: { content: Array<{ text: string }> }) => r.content.map((c) => c.text).join("");

test("each tool calls its relaygate read route as the agent, with the host's read credential", async () => {
  const t = await setup();
  try {
    const list = await t.tools.call("list_sessions", { q: "deploy", limit: 99, cursor: "c1" });
    assert.ok(!list.isError);
    assert.deepEqual(JSON.parse(out(list)), { sessions: [{ sessionId: "s1", title: "pit work" }], next_cursor: "c2" });
    await t.tools.call("get_session", { session_id: "s1" });
    await t.tools.call("get_session_turns", { session_id: "s1", cursor: "k" });
    await t.tools.call("search_sessions", { query: "rollback" });
    const routes = t.g.seen.map((s) => `${s.method} ${s.path}`);
    assert.deepEqual(routes, [
      "GET /sessions/v1/sessions",
      "GET /sessions/v1/sessions/s1/metadata",
      "GET /sessions/v1/sessions/s1/brief",
      "GET /sessions/v1/sessions/s1/events",
      "GET /sessions/v1/events",
    ]);
    for (const s of t.g.seen) {
      assert.equal(s.headers["x-relaygate-token"], AGENT, "relaygate decides as the agent");
      assert.equal(s.headers.authorization, "Bearer rth_at_read_1", "one minted read token, cached");
      assert.equal(s.query.get("workspace"), "ws-1");
    }
    assert.equal(t.g.seen[0]!.query.get("limit"), "50", "limit is capped");
    assert.equal(t.g.seen[0]!.query.get("q"), "deploy");
    assert.equal(t.g.seen[3]!.query.get("cursor"), "k");
    assert.equal(t.g.seen[3]!.query.get("maxContent"), "2000");
    assert.equal(t.g.seen[4]!.query.get("q"), "rollback");
    assert.equal(minted, 1);
  } finally {
    await t.close();
  }
});

test("get_session answers with the metadata when the backend has no brief", async () => {
  const t = await setup();
  try {
    const r = await t.tools.call("get_session", { session_id: "s1" });
    assert.ok(!r.isError);
    assert.deepEqual(JSON.parse(out(r)), { metadata: { sessionId: "s1", title: "pit work" }, brief: null });
  } finally {
    await t.close();
  }
});

test("a relaygate 403 is 'not permitted', never retried", async () => {
  const t = await setup();
  try {
    for (const [name, args] of [["get_session_turns", { session_id: DENIED }], ["get_session", { session_id: DENIED }]] as const) {
      const before = t.g.seen.length;
      const r = await t.tools.call(name, args);
      assert.equal(r.isError, true);
      assert.match(out(r), /^Not permitted/);
      assert.equal(t.g.seen.length - before, 1, `${name}: one request, no retry`);
    }
  } finally {
    await t.close();
  }
});

test("the read credential never appears in tool output, logs, or the agent's MCP config", async () => {
  const t = await setup();
  try {
    const outputs: string[] = [];
    for (const [name, args] of [["list_sessions", {}], ["get_session", { session_id: "s1" }], ["get_session_turns", { session_id: DENIED }], ["search_sessions", { query: "x" }], ["get_session", { session_id: "../../x" }]] as const) {
      outputs.push(out(await t.tools.call(name, args)));
    }
    const cfg = JSON.stringify(sessionsMcpServer({ entry: "/app/src/sessions-mcp.ts", proxyUrl: t.proxy.url, token: AGENT, node: "/usr/local/bin/node" }));
    for (const s of [...outputs, ...t.logs, cfg]) {
      assert.doesNotMatch(s, /rth_at_read_|rth_rt_read_|sh_at_|sh_rt_/);
    }
    assert.deepEqual(JSON.parse(cfg).env, { SESSIONS_PROXY_URL: t.proxy.url, RELAY_AGENT_TOKEN: AGENT });
    for (const l of t.logs) assert.ok(!l.includes(AGENT), "no rg_ token in logs either");
  } finally {
    await t.close();
  }
});

test("the proxy serves only the read routes, only to the host's agents, and never takes the workspace from the caller", async () => {
  const t = await setup();
  try {
    const get = (path: string, token = AGENT, method = "GET") => fetch(`${t.proxy.url}${path}`, { method, headers: { authorization: `Bearer ${token}` } });
    assert.equal((await get("/v1/sessions", OTHER)).status, 401);
    assert.equal((await fetch(`${t.proxy.url}/v1/sessions`)).status, 401);
    assert.equal((await get("/v1/sessions", AGENT, "POST")).status, 405);
    assert.equal((await get("/v1/delivery/batches")).status, 404);
    assert.equal((await get("/v1/sessions/users")).status, 404);
    assert.equal((await get("/v1/digest/daily")).status, 404);
    assert.equal((await get("/v1/sessions/s1/../../admin")).status, 404);
    assert.equal(t.g.seen.length, 0, "nothing refused reached relaygate");
    assert.equal((await get("/v1/sessions?workspace=ws-other")).status, 200);
    assert.deepEqual(t.g.seen[0]!.query.getAll("workspace"), ["ws-1"]);
  } finally {
    await t.close();
  }
});

test("a 401 from Sessions mints a new read token and retries once", async () => {
  let n = 0;
  const t = await setup((s) => (s.headers.authorization === "Bearer rth_at_read_1" && n++ === 0 ? { status: 401, body: { error: "invalid_token" } } : gateAnswer(s)));
  try {
    const r = await t.tools.call("list_sessions", {});
    assert.ok(!r.isError);
    assert.deepEqual(t.g.seen.map((s) => s.headers.authorization), ["Bearer rth_at_read_1", "Bearer rth_at_read_2"]);
  } finally {
    await t.close();
  }
});

test("output is bounded and long strings are cut", async () => {
  const big = "x".repeat(50_000);
  const t = await setup((s) =>
    s.path.endsWith("/events") ? { status: 200, body: { events: Array.from({ length: 50 }, (_, i) => ({ eventId: `e${i}`, content: big })), nextCursor: "n" } } : gateAnswer(s),
  );
  try {
    const r = await t.tools.call("get_session_turns", { session_id: "s1", limit: 50 });
    assert.ok(!r.isError);
    assert.ok(out(r).length <= MAX_OUTPUT, `output ${out(r).length} > ${MAX_OUTPUT}`);
    const j = JSON.parse(out(r));
    assert.equal(j.next_cursor, "n", "the cursor survives the cut");
    assert.equal(j.messages.length, 50, "no message of the page is dropped (the cursor is past all of them)");
    assert.match(JSON.stringify(j.messages), /\[cut\]/);
  } finally {
    await t.close();
  }
});

test("a response over the proxy's cap is refused, not buffered", async () => {
  const t = await setup((s) => (s.path === "/sessions/v1/sessions" ? { status: 200, body: { sessions: [{ sessionId: "s1", title: "y".repeat(5 * 1024 * 1024) }] } } : gateAnswer(s)));
  try {
    const r = await t.tools.call("list_sessions", {});
    assert.equal(r.isError, true);
    assert.match(out(r), /unavailable/);
  } finally {
    await t.close();
  }
});

test("invalid arguments are refused before any request", async () => {
  const t = await setup();
  try {
    for (const [name, args] of [["get_session", {}], ["get_session", { session_id: "a/b" }], ["search_sessions", {}], ["list_sessions", { limit: 0 }], ["list_sessions", { q: "q".repeat(501) }]] as const) {
      const r = await t.tools.call(name, args as Record<string, unknown>);
      assert.equal(r.isError, true, `${name} ${JSON.stringify(args)}`);
    }
    assert.equal(t.g.seen.length, 0);
  } finally {
    await t.close();
  }
});

test("read credential: refreshes before expiry, mints again when a refresh is refused, refreshes the uploader session on 401", async () => {
  const seen: string[] = [];
  let first = true;
  const ctl = await listen((s, body) => {
    seen.push(`${s.path} ${s.headers.authorization}`);
    if (s.headers.authorization === "Bearer sh_at_old") return { status: 401, body: {} };
    if (s.path.endsWith("/refresh")) {
      assert.deepEqual(JSON.parse(body), { refreshToken: "rth_rt_read_a" });
      return { status: 403, body: {} };
    }
    const exp = first ? Date.now() + 30_000 : Date.now() + 15 * 60_000; // the first one is nearly expired
    first = false;
    return { status: 200, body: { accessToken: `rth_at_read_${seen.length}`, accessTokenExpiresAt: new Date(exp).toISOString(), refreshToken: "rth_rt_read_a", refreshTokenExpiresAt: new Date(Date.now() + 86_400_000).toISOString() } };
  });
  let bearer = "sh_at_old";
  let invalidated = 0;
  const cred = new SessionReadCredential({ controlUrl: ctl.url, workspaceId: "ws/1", control: { get: async () => bearer, invalidate: () => ((bearer = "sh_at_new"), invalidated++) } });
  try {
    assert.equal(await cred.get(), "rth_at_read_2");
    assert.equal(invalidated, 1);
    assert.ok(seen[0]!.startsWith("/api/v1/workspaces/ws%2F1/session-read/session"));
    // Nearly expired: a refresh, refused, then a new mint.
    assert.equal(await cred.get(), "rth_at_read_4");
    assert.deepEqual(seen.slice(2).map((l) => l.split(" ")[0]!.split("/").pop()), ["refresh", "session"]);
    // Fresh now: cached.
    assert.equal(await cred.get(), "rth_at_read_4");
    assert.equal(seen.length, 4);
  } finally {
    ctl.server.close();
  }
});

test("the stdio server speaks MCP and lists the four read-only tools", async () => {
  assert.deepEqual(TOOLS.map((t) => t.name), ["list_sessions", "get_session", "get_session_turns", "search_sessions"]);
  for (const t of TOOLS) assert.match(t.description, /untrusted data/);
  const tools = new SessionsTools({ proxyUrl: "http://127.0.0.1:9", token: AGENT });
  assert.equal(await handleRpc(tools, { jsonrpc: "2.0", method: "notifications/initialized" }), null);
  const unknown = await handleRpc(tools, { jsonrpc: "2.0", id: 3, method: "resources/list" });
  assert.equal((unknown as { error: { code: number } }).error.code, -32601);

  const t = await setup();
  const entry = join(dirname(fileURLToPath(import.meta.url)), "..", "src", "sessions-mcp.ts");
  const cfg = sessionsMcpServer({ entry, proxyUrl: t.proxy.url, token: AGENT }) as { command: string; args: string[]; env: Record<string, string> };
  const child = spawn(cfg.command, cfg.args, { env: { PATH: process.env.PATH, ...cfg.env }, stdio: ["pipe", "pipe", "inherit"] });
  try {
    const replies: any[] = [];
    let buf = "";
    child.stdout.on("data", (d) => {
      buf += d;
      for (let i; (i = buf.indexOf("\n")) >= 0; ) {
        replies.push(JSON.parse(buf.slice(0, i)));
        buf = buf.slice(i + 1);
      }
    });
    const send = (m: unknown) => child.stdin.write(`${JSON.stringify(m)}\n`);
    send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } } });
    send({ jsonrpc: "2.0", method: "notifications/initialized" });
    send({ jsonrpc: "2.0", id: 2, method: "tools/list" });
    send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "list_sessions", arguments: {} } });
    const deadline = Date.now() + 10_000;
    while (replies.length < 3 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
    const byId = new Map(replies.map((r) => [r.id, r]));
    assert.equal(byId.get(1).result.serverInfo.name, "sessions");
    assert.equal(byId.get(2).result.tools.length, 4);
    assert.deepEqual(JSON.parse(byId.get(3).result.content[0].text).sessions, [{ sessionId: "s1", title: "pit work" }]);
    assert.equal(t.g.seen[0]!.headers["x-relaygate-token"], AGENT);
  } finally {
    child.kill();
    await t.close();
  }
});
