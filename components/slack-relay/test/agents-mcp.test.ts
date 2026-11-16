// The agents' relay directory tools (agents-mcp.ts) against a fake relaygate, and the reason they exist:
// @relaycast/mcp's agent.list refuses without a workspace key, which a gated agent never has.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer, type IncomingHttpHeaders, type Server } from "node:http";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { agentsMcpServer, AgentsTools, GATED_RELAYCAST_DENIED, handleRpc, TOOLS } from "../src/agents-mcp.ts";
import { GATED_AGENTS_NOTE, systemFor } from "../src/host.ts";
import type { InboundData } from "../src/protocol.ts";

const AGENT = "rg_agent_slack_thread";
const here = dirname(fileURLToPath(import.meta.url));

interface Seen {
  method: string;
  path: string;
  query: URLSearchParams;
  headers: IncomingHttpHeaders;
}

const ROSTER = [
  { name: "slack-c1-t1", type: "agent", status: "online", persona: "Slack thread agent", metadata: { card: { skills: ["triage"] } } },
  // An agent outside the pit (a person's editor agent): visible, not messageable. A leaked credential field is dropped.
  { name: "editor-dana", type: "agent", status: "offline", persona: "Dana's editor", token: "at_live_leak", metadata: { api_key: "x", cwd: "/w" } },
];

/** relaygate: GET /v1/agents (filtered by policy, here fixed) and /v1/agents/:name; 404 for agents it hides. */
async function fakeGate(): Promise<{ url: string; seen: Seen[]; close: () => Promise<void> }> {
  const seen: Seen[] = [];
  const server: Server = createServer((req, res) => {
    const u = new URL(req.url ?? "/", "http://x");
    seen.push({ method: req.method ?? "", path: u.pathname, query: u.searchParams, headers: req.headers });
    const send = (status: number, body: unknown) => res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
    if (req.headers.authorization !== `Bearer ${AGENT}`) return send(401, { ok: false, error: { code: "relaygate_unauthenticated" } });
    if (req.method !== "GET") return send(404, { ok: false, error: { code: "relaygate_route_not_proxied" } });
    if (u.pathname === "/v1/agents") return send(200, { ok: true, data: ROSTER.filter((a) => !u.searchParams.get("status") || u.searchParams.get("status") === "all" || a.status === u.searchParams.get("status")) });
    const one = ROSTER.find((a) => u.pathname === `/v1/agents/${encodeURIComponent(a.name)}`);
    if (one) return send(200, { ok: true, data: one });
    return send(404, { ok: false, error: { code: "relaygate_not_found" } });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  return { url: `http://127.0.0.1:${(server.address() as { port: number }).port}`, seen, close: () => new Promise((r) => server.close(() => r())) };
}

const body = (r: { content: Array<{ text: string }> }) => JSON.parse(r.content[0]!.text);

test("list_agents asks relaygate as the agent and shows every agent it returns, without credential fields", async () => {
  const g = await fakeGate();
  try {
    const tools = new AgentsTools({ baseUrl: `${g.url}/`, token: AGENT });
    const all = await tools.call("list_agents", {});
    assert.equal(all.isError, undefined);
    const out = body(all);
    assert.equal(out.count, 2);
    assert.deepEqual(out.agents.map((a: any) => a.name), ["slack-c1-t1", "editor-dana"]);
    assert.deepEqual(out.agents[0].metadata, { card: { skills: ["triage"] } });
    assert.equal(out.agents[1].token, undefined);
    assert.deepEqual(out.agents[1].metadata, { cwd: "/w" });
    assert.ok(!JSON.stringify(out).includes("at_live_"));

    const online = body(await tools.call("list_agents", { status: "online", include_stale: true }));
    assert.deepEqual(online.agents.map((a: any) => a.name), ["slack-c1-t1"]);
    const q = g.seen.at(-1)!.query;
    assert.equal(q.get("status"), "online");
    assert.equal(q.get("include_stale"), "1");
    assert.equal(q.get("include_metadata"), "1");

    // Read-only: only GETs, always with the agent's own token.
    assert.ok(g.seen.every((s) => s.method === "GET" && s.headers.authorization === `Bearer ${AGENT}`));
  } finally {
    await g.close();
  }
});

test("get_agent returns one card; hidden or unknown agents and bad input are plain errors", async () => {
  const g = await fakeGate();
  try {
    const tools = new AgentsTools({ baseUrl: g.url, token: AGENT });
    assert.equal(body(await tools.call("get_agent", { name: "editor-dana" })).agent.persona, "Dana's editor");
    const hidden = await tools.call("get_agent", { name: "someone-hidden" });
    assert.equal(hidden.isError, true);
    assert.match(hidden.content[0]!.text, /not let you see it|no such agent/);
    const before = g.seen.length;
    assert.equal((await tools.call("get_agent", { name: "../v1/dm" })).isError, true);
    assert.equal((await tools.call("list_agents", { status: "everyone" })).isError, true);
    assert.equal(g.seen.length, before, "invalid input never reaches relaygate");
    // A bad token: no workspace-key talk, a plain error.
    const bad = await new AgentsTools({ baseUrl: g.url, token: "rg_other" }).call("list_agents");
    assert.equal(bad.isError, true);
    assert.doesNotMatch(bad.content[0]!.text, /workspace key/i);
  } finally {
    await g.close();
  }
  // relaygate down.
  const down = await new AgentsTools({ baseUrl: "http://127.0.0.1:1", token: AGENT }).call("list_agents");
  assert.equal(down.isError, true);
});

test("the MCP surface: two read-only tools, and the config carries only relaygate's URL and the agent's token", async () => {
  const tools = new AgentsTools({ baseUrl: "http://gate", token: AGENT });
  const list = (await handleRpc(tools, { jsonrpc: "2.0", id: 1, method: "tools/list" })) as any;
  assert.deepEqual(list.result.tools.map((t: any) => t.name), ["list_agents", "get_agent"]);
  assert.deepEqual(TOOLS.map((t) => t.name), ["list_agents", "get_agent"]);
  assert.equal(await handleRpc(tools, { jsonrpc: "2.0", method: "notifications/initialized" }), null);
  const cfg = agentsMcpServer({ entry: "/x/agents-mcp.ts", baseUrl: "http://gate", token: AGENT, node: "node" });
  assert.deepEqual(cfg.env, { RELAY_BASE_URL: "http://gate", RELAY_AGENT_TOKEN: AGENT });
  // The relaycast tools that can only fail without a workspace key are taken away behind the gate.
  assert.ok(GATED_RELAYCAST_DENIED.includes("mcp__relaycast__agent_list"));
  assert.ok(GATED_RELAYCAST_DENIED.every((t) => t.startsWith("mcp__relaycast__agent_list") || t.startsWith("mcp__relaycast__workspace_")));
});

test("over stdio, as Claude Code runs it", async () => {
  const g = await fakeGate();
  const cfg = agentsMcpServer({ entry: join(here, "..", "src", "agents-mcp.ts"), baseUrl: g.url, token: AGENT }) as { command: string; args: string[]; env: Record<string, string> };
  const child = spawn(cfg.command, cfg.args, { env: { PATH: process.env.PATH, ...cfg.env }, stdio: ["pipe", "pipe", "inherit"] });
  try {
    const replies = await rpc(child, [
      { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } } },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "list_agents", arguments: {} } },
    ], 2);
    assert.equal(replies.get(1).result.serverInfo.name, "relay_agents");
    assert.equal(JSON.parse(replies.get(2).result.content[0].text).count, 2);
  } finally {
    child.kill();
    await g.close();
  }
});

test("why: @relaycast/mcp's agent.list refuses with an agent token alone (no workspace key behind relaygate)", async () => {
  const g = await fakeGate();
  const entry = join(here, "..", "node_modules", "@relaycast", "mcp", "dist", "stdio.js");
  const child = spawn(process.execPath, [entry], {
    env: { PATH: process.env.PATH, RELAY_BASE_URL: g.url, RELAY_AGENT_TOKEN: AGENT, RELAY_AGENT_NAME: "slack-c1-t1", RELAY_SKIP_BOOTSTRAP: "1", RELAYCAST_TELEMETRY_DISABLED: "1" },
    stdio: ["pipe", "pipe", "ignore"],
  });
  try {
    const replies = await rpc(child, [
      { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } } },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "agent.list", arguments: {} } },
    ], 2);
    const text = JSON.stringify(replies.get(2));
    assert.match(text, /Workspace key not configured/);
    assert.ok(!g.seen.some((s) => s.path === "/v1/agents"), "it refuses before asking relaygate");
  } finally {
    child.kill();
    await g.close();
  }
});

test("behind relaygate the system prompt says what the agent sees and whom it can message, never a workspace key", () => {
  const inbound = {
    target: "slack-c1-t1",
    roster: [],
    slack: { team: "T", channel: "C", thread_ts: "1.1", participants: [] },
  } as unknown as InboundData;
  const gated = systemFor("slack-c1-t1", "p", inbound, true, true);
  assert.ok(gated.includes(GATED_AGENTS_NOTE));
  assert.match(GATED_AGENTS_NOTE, /mcp__relay_agents__list_agents/);
  assert.match(GATED_AGENTS_NOTE, /can't message agents outside your group/);
  assert.match(GATED_AGENTS_NOTE, /Never say a workspace key is missing/);
  const open = systemFor("slack-c1-t1", "p", inbound);
  assert.ok(!open.includes(GATED_AGENTS_NOTE));
  assert.match(open, /see and message them with the relaycast tools/);
});

async function rpc(child: ReturnType<typeof spawn>, msgs: unknown[], expect: number): Promise<Map<unknown, any>> {
  const replies: any[] = [];
  let buf = "";
  child.stdout!.on("data", (d) => {
    buf += d;
    for (let i; (i = buf.indexOf("\n")) >= 0; ) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      try {
        replies.push(JSON.parse(line));
      } catch {
        // not a JSON-RPC line
      }
    }
  });
  for (const m of msgs) child.stdin!.write(`${JSON.stringify(m)}\n`);
  const deadline = Date.now() + 15_000;
  while (replies.filter((r) => r.id !== undefined).length < expect && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
  return new Map(replies.map((r) => [r.id, r]));
}
