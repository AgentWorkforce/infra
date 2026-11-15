// Group isolation through relaygate's Relaycast proxy (build 2), end to end:
// a real relaygate proxying a real Relaycast, with the chart's default policy.
// Two agents through the gate: a pit agent (bridge key, gid 22, "slack-") and a
// local agent (local key, gid 11, "local-"). Every request goes through the
// proxy, so this is what agents can actually do, not just what /v1/check says.
//   RELAYGATE_E2E_URL=... RELAYGATE_E2E_BRIDGE_KEY=... RELAYGATE_E2E_LOCAL_KEY=... RELAYGATE_E2E_PROXY=1 npm test
import assert from "node:assert/strict";
import { after, test } from "node:test";
import { RelaygateClient } from "../src/gate.ts";
import { connectAgent, ensureChannel } from "../src/relay.ts";

const url = process.env.RELAYGATE_E2E_URL;
const bridgeKey = process.env.RELAYGATE_E2E_BRIDGE_KEY;
const localKey = process.env.RELAYGATE_E2E_LOCAL_KEY;
const skip = !url || !bridgeKey || !localKey || process.env.RELAYGATE_E2E_PROXY !== "1";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const denied = (e: unknown) => {
  const s = (e as { statusCode?: number; status?: number }).statusCode ?? (e as { status?: number }).status;
  return s === 403 || s === 404;
};

const open: Array<{ disconnect: () => Promise<unknown> }> = [];
after(async () => {
  await Promise.allSettled(open.map((a) => a.disconnect()));
});

async function agents() {
  const sfx = Date.now().toString(36);
  const log = () => {};
  const pitGate = new RelaygateClient({ url: url!, enrollmentKey: bridgeKey! });
  const localGate = new RelaygateClient({ url: url!, enrollmentKey: localKey! });
  const pit = await connectAgent({ baseUrl: url!, workspaceKey: "", name: `slack-agent-${sfx}`, persona: "pit", proofSecret: "p".repeat(32), log, gate: pitGate });
  const local = await connectAgent({ baseUrl: url!, workspaceKey: "", name: `local-laptop-${sfx}`, persona: "local", proofSecret: "l".repeat(32), log, gate: localGate });
  open.push(pit.agent as never, local.agent as never);
  return { sfx, pit: pit.agent, local: local.agent, pitName: `slack-agent-${sfx}`, localName: `local-laptop-${sfx}` };
}

test("pit channel (relaycast:channel/slack…): the pit posts and reads; local can't join, read or receive it", { skip, timeout: 60_000 }, async () => {
  const { sfx, pit, local } = await agents();
  const ch = `slack-${sfx}`;
  await ensureChannel(pit, ch, "pit only");
  const localEvents: string[] = [];
  await assert.rejects(local.channels.join(ch), denied, "local can't join a pit channel");
  local.subscribe([ch], (raw: unknown) => { localEvents.push(JSON.stringify(raw)); });
  await sleep(2000);
  const m = await pit.send(ch, "pit-only note", { idempotencyKey: `pit-${sfx}` });
  await pit.reply(m.id, "pit-only reply");
  assert.equal((await pit.messages(ch)).length >= 1, true, "the pit reads its channel");
  await assert.rejects(local.messages(ch), denied, "local can't list a pit channel's messages");
  await assert.rejects(local.message(m.id), denied, "local can't fetch a pit message by id");
  await assert.rejects(local.send(ch, "sneaking in"), denied, "local can't post into the Slack routing channel");
  await sleep(2500);
  assert.deepEqual(localEvents, [], "no pit channel events reach a local agent over the node WebSocket");
});

test("local channel (relaycast:channel/…): the pit may read it but not write", { skip, timeout: 60_000 }, async () => {
  const { sfx, pit, local } = await agents();
  const ch = `dev-${sfx}`;
  await ensureChannel(local, ch, "a local channel");
  const m = await local.send(ch, "local design notes");
  assert.equal((await local.messages(ch)).length >= 1, true);
  await pit.channels.join(ch).catch(() => undefined);
  const seen = await pit.messages(ch);
  assert.ok(seen.some((x: { id?: string }) => x.id === m.id), "the pit can read a local channel");
  await assert.rejects(pit.send(ch, "pit writing into local"), denied, "the pit can't post into a local channel");
  await assert.rejects(pit.reply(m.id, "pit replying in local"), denied, "the pit can't reply in a local thread");
});

test("inboxes: local may DM a pit agent; the pit may not DM a local agent", { skip, timeout: 60_000 }, async () => {
  const { sfx, pit, local, pitName, localName } = await agents();
  const got: string[] = [];
  pit.subscribe([], (raw: unknown) => {
    const e = raw as { type?: string; message?: { text?: string } };
    if (e.type === "dm.received") got.push(e.message?.text ?? "");
  });
  await sleep(2000);
  await local.dm(pitName, `question ${sfx}`);
  await assert.rejects(pit.dm(localName, `answer ${sfx}`), denied, "the pit can't write into a local inbox");
  await sleep(2500);
  assert.ok(got.some((t) => t.includes(`question ${sfx}`)), "the local agent's DM reached the pit agent");
});

test("agent listing is filtered to what the caller may message or read", { skip, timeout: 60_000 }, async () => {
  const { pit, local, pitName, localName } = await agents();
  const list = async (a: typeof pit) =>
    ((await (a as unknown as { client: { get: (p: string) => Promise<unknown> } }).client.get("/v1/agents")) as Array<{ name: string }>).map((x) => x.name);
  assert.ok((await list(local)).includes(pitName), "local sees the pit agent it may DM");
  assert.ok((await list(pit)).includes(localName), "the pit sees the local agent it may read");
});
