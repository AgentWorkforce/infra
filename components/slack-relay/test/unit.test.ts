import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { test } from "node:test";
import { promptFor, systemFor } from "../src/host.ts";
import { Ledger, threadAgentName } from "../src/ledger.ts";
import { ClaudeOrchestrator, DeterministicOrchestrator, ThreadPolicy, type Orchestrator } from "../src/orchestrator.ts";
import { dataOf, inboundOf } from "../src/protocol.ts";
import { sessionIdFor } from "../src/router.ts";
import { normalizeSlackEvent, verifySlackSignature } from "../src/slack.ts";

const key = { team: "T1", channel: "C1", threadTs: "100.1" };

test("ledger routes a thread deterministically once assigned", () => {
  let now = 1_000;
  const l = new Ledger(":memory:", { now: () => now });
  const first = l.recordInbound({ ...key, ts: "100.1", user: "U1", text: "hi" });
  assert.equal(first?.kind, "unowned");
  l.assign(key, "slack-c1-1001", "test");
  l.setAgentStatus("slack-c1-1001", "active", { sessionId: "s1" });
  now = 2_000;
  const second = l.recordInbound({ ...key, ts: "100.2", user: "U2", text: "more" });
  assert.equal(second?.kind, "owned");
  assert.equal(second?.kind === "owned" && second.agent.agentName, "slack-c1-1001");
  assert.equal(second?.kind === "owned" && second.wake, false);
  assert.deepEqual(l.participants(key), ["U1", "U2"]);
  // A Slack retry of the same message records nothing.
  assert.equal(l.recordInbound({ ...key, ts: "100.2", user: "U2", text: "more" }), null);
});

test("ledger releases idle agents and wakes them on the next message", () => {
  let now = 0;
  const l = new Ledger(":memory:", { now: () => now });
  l.recordInbound({ ...key, ts: "100.1", user: "U1", text: "hi" });
  l.assign(key, "a1", "test");
  l.setAgentStatus("a1", "active");
  now = 60 * 60_000;
  assert.deepEqual(l.idleAgents(30 * 60_000).map((a) => a.agentName), ["a1"]);
  l.setAgentStatus("a1", "released");
  const r = l.recordInbound({ ...key, ts: "100.9", user: "U1", text: "back" });
  assert.equal(r?.kind === "owned" && r.wake, true);
  assert.equal(l.roster()[0]?.threads.length, 1);
  assert.ok(l.events().some((e) => e.kind === "agent.released"));
});

test("thread agent names and session ids are stable and relay-safe", () => {
  assert.equal(threadAgentName(key), "slack-c1-1001");
  assert.equal(sessionIdFor("a"), sessionIdFor("a"));
  assert.notEqual(sessionIdFor("a"), sessionIdFor("b"));
  assert.match(sessionIdFor("a"), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-a[0-9a-f]{3}-[0-9a-f]{12}$/);
});

test("slack signature verification", () => {
  const secret = "s3cret";
  const ts = "1700000000";
  const body = '{"type":"event_callback"}';
  const sig = `v0=${createHmac("sha256", secret).update(`v0:${ts}:${body}`).digest("hex")}`;
  assert.ok(verifySlackSignature({ signingSecret: secret, timestamp: ts, signature: sig, rawBody: body, nowSeconds: 1700000010 }));
  assert.ok(!verifySlackSignature({ signingSecret: secret, timestamp: ts, signature: sig, rawBody: body + " ", nowSeconds: 1700000010 }));
  assert.ok(!verifySlackSignature({ signingSecret: secret, timestamp: ts, signature: sig, rawBody: body, nowSeconds: 1700009999 }));
});

test("slack events: mentions, DMs, tracked thread replies; bots and edits ignored", () => {
  const o = { botUserId: "UBOT", teamId: "T1", isTrackedThread: (c: string, t: string) => c === "C1" && t === "100.1" };
  assert.equal(normalizeSlackEvent({ type: "app_mention", channel: "C1", ts: "100.1", user: "U1", text: "<@UBOT> hello" }, o)?.text, "hello");
  assert.equal(normalizeSlackEvent({ type: "message", channel_type: "im", channel: "D1", ts: "1.1", user: "U1", text: "hi" }, o)?.kind, "dm");
  assert.equal(normalizeSlackEvent({ type: "message", channel: "C1", ts: "100.2", thread_ts: "100.1", user: "U2", text: "more" }, o)?.kind, "thread");
  // untracked thread, top-level chatter, our own posts, bots and edits are ignored
  assert.equal(normalizeSlackEvent({ type: "message", channel: "C1", ts: "300.2", thread_ts: "300.1", user: "U2", text: "x" }, o), null);
  assert.equal(normalizeSlackEvent({ type: "message", channel: "C1", ts: "300.2", user: "U2", text: "x" }, o), null);
  assert.equal(normalizeSlackEvent({ type: "message", channel: "C1", ts: "100.3", thread_ts: "100.1", user: "UBOT", text: "x" }, o), null);
  assert.equal(normalizeSlackEvent({ type: "message", channel: "C1", ts: "100.3", thread_ts: "100.1", user: "U2", bot_id: "B1", text: "x" }, o), null);
  assert.equal(normalizeSlackEvent({ type: "message", subtype: "message_changed", channel: "C1", ts: "100.3" }, o), null);
  // a mention inside a tracked thread arrives as app_mention too; the message twin is dropped
  assert.equal(normalizeSlackEvent({ type: "message", channel: "C1", ts: "100.4", thread_ts: "100.1", user: "U2", text: "<@UBOT> hey" }, o), null);
});

test("orchestrator falls back to one agent per thread when the model is unavailable", async () => {
  const d = await new DeterministicOrchestrator().decide({ thread: key, text: "x", user: "U1", participants: ["U1"], roster: [] });
  assert.equal(d.agent, "slack-c1-1001");
  const logs: string[] = [];
  // Point the SDK at a closed port so the call fails fast.
  process.env.ANTHROPIC_BASE_URL = "http://127.0.0.1:9";
  const r = await new ClaudeOrchestrator({ apiKey: "sk-ant-invalid", model: "claude-fable-5-2", log: (m) => logs.push(m) }).decide({
    thread: key, text: "x", user: "U1", participants: ["U1"], roster: [],
  });
  delete process.env.ANTHROPIC_BASE_URL;
  assert.equal(r.agent, "slack-c1-1001");
  assert.match(r.reason, /unavailable/);
});

test("protocol reads data wherever the engine puts it", () => {
  const inbound = { kind: "slack.inbound", target: "a", slack: { team: "T", channel: "C", thread_ts: "1", ts: "1", user: "U", participants: ["U"] }, session: { id: "s", resume: false }, roster: [] };
  assert.equal(inboundOf(dataOf({ id: "1", metadata: inbound }))?.target, "a");
  assert.equal(inboundOf(dataOf({ id: "1", data: inbound }))?.target, "a");
  assert.equal(inboundOf(dataOf({ id: "1", metadata: { data: inbound } }))?.target, "a");
  assert.equal(inboundOf(dataOf({ id: "1" })), null);
});

test("agent prompt carries the roster, brief and thread people", () => {
  const inbound = inboundOf({ kind: "slack.inbound", target: "a1", brief: "Help U1 debug", slack: { team: "T", channel: "C1", thread_ts: "1.1", ts: "1.1", user: "U1", participants: ["U1", "U2"] }, session: { id: "s", resume: false }, roster: [{ name: "a2", status: "active", summary: "billing question", threads: 1 }] })!;
  const sys = systemFor("a1", "Be kind.", inbound);
  assert.match(sys, /a2 \(active\): billing question/);
  assert.match(sys, /Orchestrator brief for this thread: Help U1 debug/);
  assert.match(promptFor(inbound, "@a1 [slack <@U1>] why?"), /^\[slack <@U1>\] why\?\n\n\(slack channel C1, thread 1.1; people in the thread: <@U1>, <@U2>\)$/);
});

test("one agent per thread: reuse is refused, pinned agents allowed, no model call without pinned agents", async () => {
  let calls = 0;
  const reusing = (agent: string): Orchestrator => ({ decide: async () => (calls++, { agent, reason: "same user", by: "orchestrator:test" }) });
  const t2 = { team: "T1", channel: "C1", threadTs: "200.1" };
  const input = { thread: t2, text: "x", user: "U1", participants: ["U1"], roster: [] };

  const none = await new ThreadPolicy({ inner: reusing("slack-c1-1001") }).decide(input);
  assert.equal(none.agent, "slack-c1-2001");
  assert.equal(calls, 0, "no pinned agents: the model is not asked");

  const refused = await new ThreadPolicy({ inner: reusing("slack-c1-1001"), known: [{ name: "brain", description: "kb" }] }).decide(input);
  assert.equal(refused.agent, "slack-c1-2001");
  assert.match(refused.reason, /one agent per thread/);

  const pinned = await new ThreadPolicy({ inner: reusing("brain"), known: [{ name: "brain", description: "kb" }] }).decide(input);
  assert.equal(pinned.agent, "brain");

  const reuse = await new ThreadPolicy({ inner: reusing("slack-c1-1001"), allowReuse: true }).decide(input);
  assert.equal(reuse.agent, "slack-c1-1001");
});

test("ingest appends each message to its channel-day page, creating it once, idempotently", async () => {
  const { SlackIngest, pageSlug, requestId } = await import("../src/ingest.ts");
  const { McpToolError } = await import("../src/mcp.ts");
  const pages = new Map<string, string>();
  const seen = new Set<string>();
  const calls: string[] = [];
  const brain = {
    async callTool(name: string, a: Record<string, unknown>) {
      calls.push(name);
      const slug = a.slug as string;
      if (seen.has(a.request_id as string)) return {};
      if (name === "append_page") {
        if (!pages.has(slug)) throw new McpToolError(`page_not_found: ${slug}`, name);
        pages.set(slug, `${pages.get(slug)}${a.text}\n`);
      } else if (name === "put_page") {
        pages.set(slug, a.content as string);
      }
      seen.add(a.request_id as string);
      return {};
    },
  };
  const ing = new SlackIngest({ brain, sourceId: "company" });
  const ts1 = "1794693736.001989";
  const slug = pageSlug("slack", "Market Research", ts1);
  assert.equal(slug, "slack/market-research/2026-11-14");
  await ing.add({ channel: "C1", channelName: "Market Research", ts: ts1, user: "U1", text: "competitor X raised" });
  await ing.add({ channel: "C1", channelName: "Market Research", ts: "1794693740.000100", threadTs: ts1, user: "U2", text: "how much?" });
  await ing.add({ channel: "C1", channelName: "Market Research", ts: "1794693740.000100", threadTs: ts1, user: "U2", text: "how much?" }); // Slack retry
  assert.equal(await ing.add({ channel: "C1", channelName: "Market Research", ts: "1794693741.0", user: "U3", text: "key xoxb-1234567890-abcdefghij" }), null);
  const page = pages.get(slug)!;
  assert.match(page, /^# #Market Research: 2026-11-14/);
  assert.match(page, /<@U1>: competitor X raised/);
  assert.equal(page.match(/how much\?/g)?.length, 1, "retry appended once");
  assert.doesNotMatch(page, /xoxb/);
  assert.equal(requestId("append", "C1", ts1), requestId("append", "C1", ts1));
});

test("MCP responses parse from JSON or SSE", async () => {
  const { parseRpcBody } = await import("../src/mcp.ts");
  assert.deepEqual(parseRpcBody('{"jsonrpc":"2.0","id":3,"result":{"ok":1}}', 3)?.result, { ok: 1 });
  assert.deepEqual(parseRpcBody('event: message\ndata: {"jsonrpc":"2.0","id":4,"result":{"ok":2}}\n\n', 4)?.result, { ok: 2 });
  assert.equal(parseRpcBody("", 1), null);
});

test("shared or unknown channels are treated as shared; channel messages skip bots and DMs", async () => {
  const { channelInfoOf, channelMessageOf } = await import("../src/slack.ts");
  assert.equal(channelInfoOf({ id: "C1", name: "market-research", is_shared: false, is_ext_shared: false }).isShared, false);
  assert.equal(channelInfoOf({ id: "C2", name: "ext-acme", is_shared: true, is_ext_shared: true }).isShared, true);
  assert.equal(channelInfoOf({ id: "C3", name: "x" }).isShared, true, "missing flags fail closed");
  assert.equal(channelInfoOf({ id: "C4", name: "x", is_shared: false, is_ext_shared: false, pending_shared: ["T9"] }).isShared, true);
  assert.equal(channelMessageOf({ type: "message", channel: "C1", ts: "1.1", user: "U1", text: "hi" })?.text, "hi");
  assert.equal(channelMessageOf({ type: "message", channel: "C1", ts: "1.2", thread_ts: "1.1", user: "U1", text: "re" })?.threadTs, "1.1");
  assert.equal(channelMessageOf({ type: "message", channel_type: "im", channel: "D1", ts: "1.1", user: "U1", text: "hi" }), null);
  assert.equal(channelMessageOf({ type: "message", channel: "C1", ts: "1.1", user: "U1", bot_id: "B", text: "hi" }), null);
  assert.equal(channelMessageOf({ type: "message", channel: "C1", ts: "1.1", user: "UBOT", text: "hi" }, "UBOT"), null);
});

test("long channel ids still give each thread its own agent name", async () => {
  const { threadAgentName } = await import("../src/ledger.ts");
  const prefix = "a-very-long-agent-prefix-for-a-deployment-name";
  const a = threadAgentName({ team: "T1", channel: "C1234567890", threadTs: "1794693736.001989" }, prefix);
  const b = threadAgentName({ team: "T1", channel: "C1234567890", threadTs: "1794693753.480599" }, prefix);
  assert.ok(a.length <= 63 && b.length <= 63);
  assert.notEqual(a, b);
  assert.equal(threadAgentName({ team: "T1", channel: "C1", threadTs: "100.1" }), "slack-c1-1001", "short names unchanged");
});

test("mentions are removed without flattening multiline messages", () => {
  const m = normalizeSlackEvent({ type: "app_mention", channel: "C1", ts: "1.1", user: "U1", text: "<@UBOT> why does this fail?\n```\n  if (x) {\n    y()\n  }\n```" }, { botUserId: "UBOT" });
  assert.equal(m?.text, "why does this fail?\n```\n  if (x) {\n    y()\n  }\n```");
});

test("an undelivered Slack message is forgotten, so it can be routed again, and the thread is told", async () => {
  const { Router } = await import("../src/router.ts");
  const ledger = new Ledger(":memory:");
  const posts: string[] = [];
  let sends = 0;
  const router = new Router({
    ledger,
    relay: { send: async () => { sends++; throw new Error("relay down"); }, reply: async () => ({ id: "r" }) },
    slack: { postMessage: async (a) => { posts.push(a.text); return {}; } },
    orchestrator: new DeterministicOrchestrator(),
    channel: "slack",
    selfName: "router",
    retryDelaysMs: [1, 1],
  });
  const msg = { team: "T1", channel: "C1", threadTs: "9.1", ts: "9.1", user: "U1", text: "hi", kind: "mention" as const };
  await assert.rejects(router.fromSlack(msg), /relay down/);
  assert.equal(sends, 3, "two retries");
  assert.match(posts[0]!, /couldn't reach the agent/);
  // Routed again (not a duplicate) once the relay is back.
  assert.notEqual(ledger.recordInbound({ team: "T1", channel: "C1", threadTs: "9.1", ts: "9.1", user: "U1", text: "hi" }), null);
  assert.ok(router.isTrackedThread("T1", "C1", "9.1"), "a recorded thread is tracked even before it has an owner");
});
