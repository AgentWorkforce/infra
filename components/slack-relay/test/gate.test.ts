// relaygate client against a fake gate that follows docs/contract.md:
// register (+recovery, 409 otherwise, name scope), /v1/check allow/deny/503.
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import { test } from "node:test";
import { checkWithRetry, GateDenied, GateUnavailable, kbStreamId, RelaygateClient, slackStreamId } from "../src/gate.ts";
import { Ledger } from "../src/ledger.ts";
import { DeterministicOrchestrator } from "../src/orchestrator.ts";
import { Router } from "../src/router.ts";
import { SlackIngest } from "../src/ingest.ts";

interface FakeGate {
  server: Server;
  url: string;
  checks: Array<{ token: string; body: Record<string, unknown> }>;
  decide: (body: Record<string, unknown>) => number; // status for /v1/check
}

function fakeGate(): Promise<FakeGate> {
  const agents = new Map<string, { id: string; recovery?: string; token: string }>();
  const g: Partial<FakeGate> = { checks: [], decide: () => 200 };
  let n = 0;
  const server = createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      const body = raw ? (JSON.parse(raw) as Record<string, unknown>) : {};
      const auth = (req.headers.authorization ?? "").replace(/^Bearer /, "");
      const send = (status: number, j: unknown) => res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(j));
      if (req.url === "/v1/register") {
        if (auth !== "ek_pit") return send(401, { error: "relaygate_unauthorized" });
        const name = String(body.name);
        if (!name.startsWith("slack-")) return send(403, { error: "relaygate_name_scope" });
        const existing = agents.get(name);
        if (existing && (!body.recovery || body.recovery !== existing.recovery)) return send(409, { error: "relaygate_name_taken" });
        const token = `rg_${++n}`;
        const id = existing?.id ?? `ag_${n}`;
        agents.set(name, { id, recovery: (body.recovery as string) ?? existing?.recovery, token });
        return send(200, { agent_id: id, gid: 22, token });
      }
      if (req.url === "/v1/check") {
        g.checks!.push({ token: auth, body });
        const status = g.decide!(body);
        if (status === 200) return send(200, { decision: "allow" });
        if (status === 403) return send(403, { error: "relaygate_classified" });
        return send(503, { error: "relaygate_unavailable" });
      }
      send(404, {});
    });
  });
  return new Promise((r) =>
    server.listen(0, () => {
      g.server = server;
      g.url = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
      r(g as FakeGate);
    }),
  );
}

test("register: group from the key, same identity back with the recovery proof, 409 without, name scope", async () => {
  const g = await fakeGate();
  try {
    const gate = new RelaygateClient({ url: g.url, enrollmentKey: "ek_pit" });
    const a = await gate.register("slack-c1-1001", "proof-1");
    assert.equal(a.gid, 22);
    const again = await gate.register("slack-c1-1001", "proof-1");
    assert.equal(again.agentId, a.agentId);
    assert.notEqual(again.token, a.token, "a new token on recovery");
    await assert.rejects(gate.register("slack-c1-1001", "wrong"), (e) => e instanceof GateDenied && e.code === "relaygate_name_taken");
    await assert.rejects(gate.register("other-agent", "p"), (e) => e instanceof GateDenied && e.code === "relaygate_name_scope");
    await assert.rejects(new RelaygateClient({ url: g.url, enrollmentKey: "nope" }).register("slack-x", "p"), GateDenied);
  } finally {
    g.server.close();
  }
});

test("check: allow resolves, deny is final, unavailable is retried then fails closed", async () => {
  const g = await fakeGate();
  try {
    const gate = new RelaygateClient({ url: g.url, enrollmentKey: "ek_pit" });
    const req = { op: "w" as const, resource: { kind: "stream" as const, id: "slack:T/C/1.1" }, content: "hi" };
    await gate.check("rg_1", req);
    g.decide = () => 403;
    await assert.rejects(checkWithRetry(gate, "rg_1", req, [1, 1]), GateDenied);
    assert.equal(g.checks.length, 2, "a denial isn't retried");
    g.decide = () => 503;
    await assert.rejects(checkWithRetry(gate, "rg_1", req, [1, 1]), GateUnavailable);
    assert.equal(g.checks.length, 5, "unavailable retried twice, then not sent");
    await assert.rejects(new RelaygateClient({ url: "http://127.0.0.1:9", enrollmentKey: "x" }).check("rg", req), GateUnavailable);
  } finally {
    g.server.close();
  }
});

test("router: every Slack post is checked; a withheld answer never reaches Slack and is recorded", async () => {
  const g = await fakeGate();
  try {
    const gate = new RelaygateClient({ url: g.url, enrollmentKey: "ek_pit" });
    const ledger = new Ledger(":memory:");
    const posts: string[] = [];
    const router = new Router({
      ledger,
      relay: { send: async () => ({ id: "p1" }), reply: async () => ({ id: "r1" }) },
      slack: { postMessage: async (a) => (posts.push(a.text), { ts: "9.9" }) },
      orchestrator: new DeterministicOrchestrator(),
      channel: "slack",
      selfName: "router",
      egress: (ref, text) => checkWithRetry(gate, "rg_router", { op: "w", resource: { kind: "stream", id: slackStreamId(ref) }, content: text }, [1]),
    });
    await router.fromSlack({ team: "T1", channel: "C1", threadTs: "1.1", ts: "1.1", user: "U1", text: "hi", kind: "mention" });
    const agent = ledger.thread({ team: "T1", channel: "C1", threadTs: "1.1" })!.agentName!;
    const reply = (text: string, id: string) => router.fromRelay({ type: "thread.reply", channel: "slack", parentId: "p1", message: { id, agentName: agent, text } });

    assert.equal(await reply("the weather is fine", "m1"), true);
    assert.deepEqual(posts, ["the weather is fine"]);
    assert.equal(g.checks.at(-1)!.body.content, "the weather is fine");
    assert.deepEqual(g.checks.at(-1)!.body.resource, { kind: "stream", id: "slack:T1/C1/1.1" });

    g.decide = (b) => (String(b.content).includes("SSN") ? 403 : 200);
    assert.equal(await reply("the patient's SSN is 123-45-6789", "m2"), false);
    assert.deepEqual(posts, ["the weather is fine", "That answer was withheld by policy."], "only the notice reached Slack");
    assert.ok(ledger.events(50).some((e) => e.kind === "outbound.withheld"));
  } finally {
    g.server.close();
  }
});

test("ingest: a denied write is skipped, an allowed one goes through", async () => {
  const g = await fakeGate();
  try {
    const gate = new RelaygateClient({ url: g.url, enrollmentKey: "ek_pit" });
    const writes: string[] = [];
    const ing = new SlackIngest({
      brain: { callTool: async (name, a) => (writes.push(`${name}:${a.text ?? a.content}`), {}) },
      beforeWrite: (slug, text) => checkWithRetry(gate, "rg_router", { op: "w", resource: { kind: "stream", id: kbStreamId("brain-write", slug) }, content: text }, [1]),
    });
    g.decide = (b) => (String(b.content).includes("secret plan") ? 403 : 200);
    await ing.add({ channel: "C1", channelName: "general", ts: "1794693736.0", user: "U1", text: "hello" });
    await assert.rejects(ing.add({ channel: "C1", channelName: "general", ts: "1794693737.0", user: "U1", text: "the secret plan" }), GateDenied);
    assert.equal(writes.length, 1);
    assert.match((g.checks.at(-1)!.body.resource as { id: string }).id, /^kb:brain-write\/slack\/general-c1\//);
  } finally {
    g.server.close();
  }
});
