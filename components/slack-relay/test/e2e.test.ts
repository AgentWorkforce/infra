// End to end against a real Relaycast engine (skipped without one):
//   RELAYCAST_E2E_URL=http://localhost:8787 RELAYCAST_E2E_KEY=rk_live_... npm test
// Slack is a local fake Web API; Claude is a fake turn so the run is deterministic.
// Proves: thread -> agent mapping, one agent per thread, follow-ups resume the
// same agent and session, concurrent threads stay separate, replies land in the
// right Slack thread, and a restarted router + host recover their identities.
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { AgentHost, type TurnInput } from "../src/host.ts";
import { Ledger } from "../src/ledger.ts";
import { toEvent } from "../src/main.ts";
import { DeterministicOrchestrator } from "../src/orchestrator.ts";
import { connectAgent, ensureChannel } from "../src/relay.ts";
import { Router } from "../src/router.ts";
import { SlackWeb } from "../src/slack.ts";

const url = process.env.RELAYCAST_E2E_URL;
const key = process.env.RELAYCAST_E2E_KEY;

interface Post {
  channel: string;
  thread_ts?: string;
  text: string;
}

function fakeSlack(): Promise<{ server: Server; base: string; posts: Post[] }> {
  const posts: Post[] = [];
  let n = 0;
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      const method = req.url?.split("/").pop();
      const j = body ? (JSON.parse(body) as Record<string, string>) : {};
      res.setHeader("content-type", "application/json");
      if (method === "auth.test") return void res.end(JSON.stringify({ ok: true, user_id: "UBOT", team_id: "T1", team: "test" }));
      if (method === "chat.postMessage") {
        posts.push({ channel: j.channel!, thread_ts: j.thread_ts, text: j.text! });
        return void res.end(JSON.stringify({ ok: true, ts: `9${++n}.0001` }));
      }
      res.end(JSON.stringify({ ok: false, error: "unknown_method" }));
    });
  });
  return new Promise((r) => server.listen(0, () => r({ server, base: `http://127.0.0.1:${(server.address() as { port: number }).port}/api`, posts })));
}

async function until<T>(fn: () => T | undefined | false, ms = 15_000): Promise<T> {
  const start = Date.now();
  for (;;) {
    const v = fn();
    if (v) return v;
    if (Date.now() - start > ms) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 100));
  }
}

test("slack threads route to resumable per-thread agents over a real relay", { skip: !url || !key }, async () => {
  const suffix = Date.now().toString(36);
  const channel = `slack-e2e-${suffix}`;
  const routerName = `slack-router-${suffix}`;
  const hostName = `slack-host-${suffix}`;
  const prefix = `t${suffix}`;
  const dir = mkdtempSync(join(tmpdir(), "slack-relay-e2e-"));
  const log = process.env.E2E_DEBUG ? (m: string) => console.error(`[e2e] ${m}`) : () => {};
  const { server, base, posts } = await fakeSlack();
  const turns: TurnInput[] = [];

  async function start() {
    const ledger = new Ledger(join(dir, "ledger.sqlite"));
    const r = await connectAgent({ baseUrl: url!, workspaceKey: key!, name: routerName, persona: "router", proofSecret: "e2e", log });
    await ensureChannel(r.agent, channel, "e2e");
    const router = new Router({
      ledger,
      relay: r.agent,
      slack: new SlackWeb("xoxb-test", base),
      orchestrator: new DeterministicOrchestrator(prefix),
      channel,
      selfName: routerName,
      log,
    });
    r.agent.subscribe([channel], (raw: unknown) => { log(`router event ${JSON.stringify(raw).slice(0, 400)}`); void router.fromRelay(toEvent(raw as Record<string, unknown>)); });

    const h = await connectAgent({ baseUrl: url!, workspaceKey: key!, name: hostName, persona: "host", proofSecret: "e2e", log });
    await ensureChannel(h.agent, channel, "e2e");
    const host = new AgentHost({
      routerName,
      channel,
      dataDir: dir,
      log,
      getMessage: (id) => h.agent.message(id) as never,
      connect: async (name) => {
        const a = await connectAgent({ baseUrl: url!, workspaceKey: key!, name, persona: "thread agent", proofSecret: "e2e", log });
        await ensureChannel(a.agent, channel, "e2e");
        return { client: a.agent, token: a.token };
      },
      runTurn: async (t) => {
        turns.push(t);
        const said = t.prompt.split("\n")[0]!.replace(/^\[slack [^\]]*\]\s*/, "");
        return { text: `${t.agent} heard: ${said}${t.resume ? " (resumed)" : ""}`, sessionId: t.sessionId, error: false };
      },
    });
    h.agent.subscribe([channel], (raw: unknown) => { log(`host event ${JSON.stringify(raw).slice(0, 600)}`); void host.onEvent(toEvent(raw as Record<string, unknown>)).catch((e) => log(`host err ${e}`)); });
    await new Promise((r) => setTimeout(r, 1500)); // let both sockets subscribe
    return { ledger, router, host, stop: async () => {
      await r.agent.disconnect().catch(() => undefined);
      await h.agent.disconnect().catch(() => undefined);
      await host.disconnectAll();
      ledger.close();
    } };
  }

  let s: Awaited<ReturnType<typeof start>> | null = null;
  try {
    s = await start();
    // Two people start two threads at once.
    await Promise.all([
      s.router.fromSlack({ team: "T1", channel: "C1", threadTs: "100.1", ts: "100.1", user: "U1", text: "the password is fluffy bunny", kind: "mention" }),
      s.router.fromSlack({ team: "T1", channel: "C1", threadTs: "200.1", ts: "200.1", user: "U2", text: "what is 2+2", kind: "mention" }),
    ]);
    await until(() => posts.length >= 2);
    const a1 = s.ledger.thread({ team: "T1", channel: "C1", threadTs: "100.1" })!.agentName!;
    const a2 = s.ledger.thread({ team: "T1", channel: "C1", threadTs: "200.1" })!.agentName!;
    assert.notEqual(a1, a2, "each thread has its own agent");
    assert.ok(posts.some((p) => p.thread_ts === "100.1" && p.text === `${a1} heard: the password is fluffy bunny`));
    assert.ok(posts.some((p) => p.thread_ts === "200.1" && p.text === `${a2} heard: what is 2+2`));

    // A Slack retry of the same message is routed once.
    assert.equal(await s.router.fromSlack({ team: "T1", channel: "C1", threadTs: "100.1", ts: "100.1", user: "U1", text: "the password is fluffy bunny", kind: "mention" }), null);

    // A follow-up from someone else in thread 1 goes to the same agent and resumes its session.
    await s.router.fromSlack({ team: "T1", channel: "C1", threadTs: "100.1", ts: "100.2", user: "U3", text: "what did they say?", kind: "thread" });
    await until(() => posts.length >= 3);
    assert.deepEqual(posts[2], { channel: "C1", thread_ts: "100.1", text: `${a1} heard: what did they say? (resumed)` });
    assert.deepEqual(s.ledger.participants({ team: "T1", channel: "C1", threadTs: "100.1" }), ["U1", "U3"]);
    const t1 = turns.filter((t) => t.agent === a1);
    assert.equal(t1.length, 2);
    assert.equal(t1[0]!.sessionId, t1[1]!.sessionId, "same Claude session across turns");

    // Restart everything (pod restarts): identities recover, the ledger survives, the thread resumes.
    await s.stop();
    s = await start();
    await s.router.fromSlack({ team: "T1", channel: "C1", threadTs: "100.1", ts: "100.3", user: "U1", text: "still there?", kind: "thread" });
    await until(() => posts.length >= 4);
    assert.deepEqual(posts[3], { channel: "C1", thread_ts: "100.1", text: `${a1} heard: still there? (resumed)` });
    assert.equal(s.ledger.agent(a1)?.status, "active");
    assert.ok(s.ledger.events(100).some((e) => e.kind === "assign"));

    // Another agent on the relay DMs a1: the host wakes a1 for it, in a1's own
    // session, and a1 answers by DM. The answer itself triggers no reply back.
    const peer = await connectAgent({ baseUrl: url!, workspaceKey: key!, name: `peer-${suffix}`, persona: "peer", proofSecret: "e2e", log });
    const peerInbox: Array<{ text: string; kind?: unknown }> = [];
    peer.agent.subscribe(["@self"], (raw: unknown) => {
      const e = raw as { type?: string; message?: { text?: string; metadata?: Record<string, unknown>; data?: Record<string, unknown> } };
      if (e.type === "dm.received") peerInbox.push({ text: e.message?.text ?? "", kind: (e.message?.metadata ?? e.message?.data)?.kind });
    });
    await new Promise((r) => setTimeout(r, 1000));
    const before = turns.length;
    await peer.agent.dm(a1, "what are you working on?");
    await until(() => peerInbox.length >= 1);
    assert.equal(peerInbox[0]!.text, `${a1} heard: Direct message on the relay from peer-${suffix}: (resumed)`);
    const dmTurn = turns.slice(before).find((t) => t.agent === a1)!;
    assert.equal(dmTurn.resume, true, "the DM resumes a1's existing session");
    assert.equal(dmTurn.sessionId, t1[0]!.sessionId);
    // A peer's automatic answer back to a1 is taken in without another reply.
    await peer.agent.dm(a1, "thanks", { data: { kind: "agent.dm.reply" } });
    await until(() => turns.length >= before + 2);
    await new Promise((r) => setTimeout(r, 1500));
    assert.equal(peerInbox.length, 1, "no reply to an automatic answer");
    await peer.agent.disconnect().catch(() => undefined);
  } finally {
    await s?.stop().catch(() => undefined);
    server.close();
  }
});
