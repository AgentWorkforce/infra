// A thread agent may receive DMs from agents outside its relaygate group, but
// never sends anything back to them: the host asks the gate (/v1/check on the
// sender's inbox) before any DM answer and sends only on allow.
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { checkWithRetry, inboxStreamId, RelaygateClient } from "../src/gate.ts";
import { AgentHost, OUTSIDE_NOTE, systemFor, type TurnInput } from "../src/host.ts";

/** A fake relaygate: pit inboxes (slack-, pit-) allow, local- inboxes deny, `down` answers 503. */
async function fakeGate(): Promise<{ server: Server; url: string; checks: Array<{ token: string; body: Record<string, unknown> }>; down: boolean }> {
  const g = { checks: [] as Array<{ token: string; body: Record<string, unknown> }>, down: false, url: "", server: undefined as unknown as Server };
  g.server = createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      const send = (status: number, j: unknown) => res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(j));
      if (req.url !== "/v1/check") return send(404, {});
      const body = JSON.parse(raw || "{}") as Record<string, unknown>;
      g.checks.push({ token: (req.headers.authorization ?? "").replace(/^Bearer /, ""), body });
      if (g.down) return send(503, { error: "relaygate_unavailable" });
      const id = String((body.resource as { id?: string })?.id ?? "");
      if (/^relaycast:inbox\/(slack-|pit-)/.test(id)) return send(200, { decision: "allow" });
      return send(403, { error: "relaygate_denied" });
    });
  });
  await new Promise<void>((r) => g.server.listen(0, "127.0.0.1", r));
  g.url = `http://127.0.0.1:${(g.server.address() as { port: number }).port}`;
  return g;
}

interface Sent {
  to: string;
  text: string;
}

function mkHost(opts: { gate?: RelaygateClient; dm?: boolean }) {
  const sent: Sent[] = [];
  const turns: TurnInput[] = [];
  const uploads: string[] = [];
  const logs: string[] = [];
  const host = new AgentHost({
    routerName: "slack-router",
    channel: "slack",
    dataDir: mkdtempSync(join(tmpdir(), "sr-dm-")),
    gated: Boolean(opts.gate),
    dmCheck: opts.gate ? (token, to, content) => checkWithRetry(opts.gate!, token, { op: "w", resource: { kind: "stream", id: inboxStreamId(to) }, content }, []) : undefined,
    connect: async (name) => ({
      token: `rg_${name}`,
      client: {
        reply: async () => ({ id: "r1" }),
        dm: async (to: string, text: string) => void sent.push({ to, text }),
        message: async (id: string) => ({ id }),
      },
    }),
    runTurn: async (t) => {
      turns.push(t);
      return { text: "the answer", sessionId: t.sessionId, error: false };
    },
    sessionUpload: async (u) => void uploads.push(u.agent),
    log: (m) => logs.push(m),
  });
  return { host, sent, turns, uploads, logs };
}

const dm = (id: string, from: string) => ({ id, from, text: "secret question" });

test("a DM from outside the group: the turn runs and uploads, nothing is sent back", async (t) => {
  const g = await fakeGate();
  t.after(() => g.server.close());
  const h = mkHost({ gate: new RelaygateClient({ url: g.url, enrollmentKey: "ek" }) });
  assert.equal(await h.host.onDm("slack-a", dm("d1", "local-x")), null);
  await new Promise((r) => setImmediate(r));
  assert.equal(h.turns.length, 1, "the agent still takes the message in");
  assert.match(h.turns[0]!.prompt, /Nothing is sent back to local-x/);
  assert.match(h.turns[0]!.prompt, /Don't promise them a reply/);
  assert.ok(h.turns[0]!.system.includes(OUTSIDE_NOTE));
  assert.deepEqual(h.uploads, ["slack-a"], "the session still uploads");
  assert.deepEqual(h.sent, [], "no DM is attempted");
  // Only the pre-turn check ran, as the agent, on the sender's inbox; no check for an answer that is never sent.
  assert.deepEqual(g.checks, [{ token: "rg_slack-a", body: { op: "w", resource: { kind: "stream", id: "relaycast:inbox/local-x" }, content: "" } }]);
  assert.ok(h.logs.some((l) => l === "slack-a: reply withheld: recipient outside group (local-x; denied)"));
  assert.ok(!h.logs.join("\n").includes("secret question"), "logs carry names only");
  await h.host.disconnectAll();
});

test("a DM from inside the group is answered, after the gate allows the exact text", async (t) => {
  const g = await fakeGate();
  t.after(() => g.server.close());
  const h = mkHost({ gate: new RelaygateClient({ url: g.url, enrollmentKey: "ek" }) });
  assert.equal(await h.host.onDm("slack-a", dm("d1", "slack-b")), "slack-b");
  assert.match(h.turns[0]!.prompt, /Your answer is sent back to slack-b/);
  assert.deepEqual(h.sent, [{ to: "slack-b", text: "the answer" }]);
  assert.deepEqual(
    g.checks.map((c) => c.body.content),
    ["", "the answer"],
  );
  assert.ok(g.checks.every((c) => c.token === "rg_slack-a" && (c.body.resource as { id: string }).id === "relaycast:inbox/slack-b"));
  await h.host.disconnectAll();
});

test("the answer's own check fails: withheld", async (t) => {
  const g = await fakeGate();
  t.after(() => g.server.close());
  let n = 0;
  const gate = new RelaygateClient({ url: g.url, enrollmentKey: "ek" });
  const orig = gate.check.bind(gate);
  gate.check = async (token, req) => {
    if (n++ === 1) g.down = true; // the second check (the real answer) fails
    return orig(token, req);
  };
  const h = mkHost({ gate });
  assert.equal(await h.host.onDm("slack-a", dm("d1", "slack-b")), null);
  assert.equal(h.turns.length, 1);
  assert.deepEqual(h.sent, []);
  assert.ok(h.logs.some((l) => l === "slack-a: reply withheld: recipient outside group (slack-b; gate unavailable)"));
  await h.host.disconnectAll();
});

test("the gate errors: fail closed, no send", async (t) => {
  const g = await fakeGate();
  t.after(() => g.server.close());
  g.down = true;
  const h = mkHost({ gate: new RelaygateClient({ url: g.url, enrollmentKey: "ek" }) });
  assert.equal(await h.host.onDm("slack-a", dm("d1", "slack-b")), null);
  assert.equal(h.turns.length, 1, "the turn still runs");
  assert.deepEqual(h.sent, []);
  // A gate that isn't there at all is the same.
  const gone = mkHost({ gate: new RelaygateClient({ url: "http://127.0.0.1:1", enrollmentKey: "ek", timeoutMs: 500 }) });
  assert.equal(await gone.host.onDm("slack-a", dm("d2", "slack-b")), null);
  assert.deepEqual(gone.sent, []);
  await h.host.disconnectAll();
  await gone.host.disconnectAll();
});

test("without relaygate, DMs are answered as before", async () => {
  const h = mkHost({});
  assert.equal(await h.host.onDm("slack-a", dm("d1", "local-x")), "local-x");
  assert.match(h.turns[0]!.prompt, /Your answer is sent back to local-x/);
  assert.ok(!h.turns[0]!.system.includes(OUTSIDE_NOTE));
  assert.deepEqual(h.sent, [{ to: "local-x", text: "the answer" }]);
  // An agent's automatic answer still gets no reply.
  const auto = mkHost({});
  await auto.host.onDm("slack-a", { ...dm("d2", "local-x"), data: { kind: "agent.dm.reply" } });
  assert.deepEqual(auto.sent, []);
  await h.host.disconnectAll();
  await auto.host.disconnectAll();
});

test("an automatic answer from outside the group is taken in without any check or send", async (t) => {
  const g = await fakeGate();
  t.after(() => g.server.close());
  const h = mkHost({ gate: new RelaygateClient({ url: g.url, enrollmentKey: "ek" }) });
  await h.host.onDm("slack-a", { ...dm("d1", "local-x"), data: { kind: "agent.dm.reply" } });
  assert.equal(h.turns.length, 1);
  assert.deepEqual(g.checks, []);
  assert.deepEqual(h.sent, []);
  await h.host.disconnectAll();
});

test("Slack thread turns carry the outside note only behind relaygate", () => {
  const inbound = { kind: "slack.inbound", target: "slack-a", session: { id: "s", resume: false }, roster: [], slack: { team: "T", channel: "C", thread_ts: "1", ts: "1", user: "U", participants: ["U"] } } as never;
  assert.ok(systemFor("slack-a", "p", inbound, true).includes(OUTSIDE_NOTE));
  assert.ok(!systemFor("slack-a", "p", inbound).includes(OUTSIDE_NOTE));
});
