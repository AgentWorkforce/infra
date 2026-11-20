// Step 0 of the router: an :eyes: reaction on each message it takes.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { Ledger } from "../src/ledger.ts";
import { DeterministicOrchestrator } from "../src/orchestrator.ts";
import { Router } from "../src/router.ts";
import { normalizeSlackEvent, SlackApiError, SlackWeb, type SlackWebLike } from "../src/slack.ts";

type Reaction = { channel: string; timestamp: string; name: string };

function setup(opts: { addReaction?: SlackWebLike["addReaction"]; ackReaction?: string } = {}) {
  const ledger = new Ledger(":memory:");
  const reactions: Reaction[] = [];
  const logs: string[] = [];
  let n = 0;
  const slack: SlackWebLike = {
    postMessage: async () => ({}),
    addReaction: opts.addReaction ?? (async (a) => void reactions.push(a)),
  };
  const router = new Router({
    ledger,
    relay: { send: async () => ({ id: `r${++n}` }), reply: async () => ({ id: `r${++n}` }) },
    slack,
    orchestrator: new DeterministicOrchestrator(),
    channel: "slack",
    selfName: "router",
    log: (m) => logs.push(m),
    retryDelaysMs: [1],
    ...(opts.ackReaction !== undefined ? { ackReaction: opts.ackReaction } : {}),
  });
  // What the router's Slack handler does: normalize, then route what isn't ignored.
  const onEvent = async (event: Record<string, unknown>) => {
    const m = normalizeSlackEvent(event, { botUserId: "UBOT", teamId: "T1", isTrackedThread: (ch, ts) => router.isTrackedThread("T1", ch, ts) });
    return m ? router.fromSlack({ ...m, team: "T1" }) : null;
  };
  return { ledger, router, reactions, logs, onEvent };
}

const tick = () => new Promise((r) => setImmediate(r));

test("a routed mention and a reply in its thread each get :eyes:", async () => {
  const { reactions, onEvent } = setup();
  assert.ok(await onEvent({ type: "app_mention", channel: "C1", ts: "1.1", user: "U1", text: "<@UBOT> help" }));
  assert.ok(await onEvent({ type: "message", channel: "C1", ts: "1.2", thread_ts: "1.1", user: "U1", text: "more detail" }));
  assert.ok(await onEvent({ type: "message", channel_type: "im", channel: "D1", ts: "2.1", user: "U1", text: "a dm" }));
  await tick();
  assert.deepEqual(reactions, [
    { channel: "C1", timestamp: "1.1", name: "eyes" },
    { channel: "C1", timestamp: "1.2", name: "eyes" },
    { channel: "D1", timestamp: "2.1", name: "eyes" },
  ]);
});

test("ignored messages get no reaction", async () => {
  const { reactions, onEvent } = setup();
  // Plain channel message, reply in a thread the router doesn't hold, bot message, edit.
  assert.equal(await onEvent({ type: "message", channel: "C1", ts: "1.1", user: "U1", text: "chatter" }), null);
  assert.equal(await onEvent({ type: "message", channel: "C1", ts: "1.3", thread_ts: "1.2", user: "U1", text: "elsewhere" }), null);
  assert.equal(await onEvent({ type: "message", channel: "C1", ts: "1.4", user: "U2", bot_id: "B1", text: "bot" }), null);
  assert.equal(await onEvent({ type: "message", subtype: "message_changed", channel: "C1", ts: "1.5", user: "U1", text: "edit" }), null);
  await tick();
  assert.deepEqual(reactions, []);
});

test("ackReaction '' turns the reaction off; a custom name is used as given", async () => {
  const off = setup({ ackReaction: "" });
  await off.onEvent({ type: "app_mention", channel: "C1", ts: "1.1", user: "U1", text: "<@UBOT> hi" });
  await tick();
  assert.deepEqual(off.reactions, []);
  const custom = setup({ ackReaction: ":robot_face:" });
  await custom.onEvent({ type: "app_mention", channel: "C1", ts: "1.1", user: "U1", text: "<@UBOT> hi" });
  await tick();
  assert.equal(custom.reactions[0]?.name, "robot_face");
});

test("missing_scope is logged once and the router stops trying; routing goes on", async () => {
  let calls = 0;
  const { onEvent, logs } = setup({
    addReaction: async () => {
      calls++;
      throw new SlackApiError("reactions.add", 200, "missing_scope");
    },
  });
  assert.ok(await onEvent({ type: "app_mention", channel: "C1", ts: "1.1", user: "U1", text: "<@UBOT> one secret" }));
  await tick();
  assert.ok(await onEvent({ type: "app_mention", channel: "C1", ts: "2.1", user: "U1", text: "<@UBOT> two" }));
  await tick();
  assert.equal(calls, 1, "not asked again after missing_scope");
  const scopeLogs = logs.filter((l) => l.includes("reactions:write"));
  assert.equal(scopeLogs.length, 1);
  assert.match(scopeLogs[0]!, /add reactions:write and reinstall the app/);
  assert.ok(!logs.some((l) => l.includes("secret")), "message text is never logged");
});

test("already_reacted is ignored; other failures log the code only", async () => {
  const codes = ["already_reacted", "ratelimited"];
  const { onEvent, logs } = setup({
    addReaction: async () => {
      throw new SlackApiError("reactions.add", 200, codes.shift()!);
    },
  });
  await onEvent({ type: "app_mention", channel: "C1", ts: "1.1", user: "U1", text: "<@UBOT> private words" });
  await onEvent({ type: "app_mention", channel: "C1", ts: "2.1", user: "U1", text: "<@UBOT> private words" });
  await tick();
  const ack = logs.filter((l) => l.startsWith("ack reaction"));
  assert.deepEqual(ack, ["ack reaction failed for C1:2.1 (ratelimited)"]);
  assert.ok(!logs.some((l) => l.includes("private words")));
});

test("a slow or failing reaction never blocks or fails routing", async () => {
  // Never settles.
  const slow = setup({ addReaction: () => new Promise<void>(() => {}) });
  const routed = await Promise.race([
    slow.onEvent({ type: "app_mention", channel: "C1", ts: "1.1", user: "U1", text: "<@UBOT> hi" }),
    new Promise((r) => setTimeout(() => r("timeout"), 1000)),
  ]);
  assert.match(String(routed), /^r\d+$/, "routed while the reaction is still pending");
  // Throws synchronously, and rejects with a non-Slack error.
  const sync = setup({ addReaction: () => { throw new Error("boom"); } });
  assert.ok(await sync.onEvent({ type: "app_mention", channel: "C1", ts: "1.1", user: "U1", text: "<@UBOT> hi" }));
  const net = setup({ addReaction: async () => { throw new TypeError("fetch failed"); } });
  assert.ok(await net.onEvent({ type: "app_mention", channel: "C1", ts: "1.1", user: "U1", text: "<@UBOT> hi" }));
  await tick();
  assert.deepEqual(net.logs.filter((l) => l.startsWith("ack")), ["ack reaction failed for C1:1.1 (request_failed)"]);
});

test("SlackWeb.addReaction posts reactions.add and surfaces Slack's error code", async () => {
  const seen: string[] = [];
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      seen.push(`${req.url} ${body}`);
      const ok = !body.includes("timestamp=2.2");
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(ok ? { ok: true } : { ok: false, error: "missing_scope" }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  try {
    const web = new SlackWeb("xoxb-test", `http://127.0.0.1:${(server.address() as AddressInfo).port}`);
    await web.addReaction({ channel: "C1", timestamp: "1.1", name: "eyes" });
    assert.deepEqual(seen, ["/reactions.add channel=C1&timestamp=1.1&name=eyes"]);
    await assert.rejects(web.addReaction({ channel: "C1", timestamp: "2.2", name: "eyes" }), (err: unknown) => err instanceof SlackApiError && err.code === "missing_scope");
  } finally {
    server.close();
  }
});
