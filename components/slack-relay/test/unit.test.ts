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
