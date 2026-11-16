// The headless session uploader against a fake relaygate Sessions proxy
// (POST /sessions/v1/delivery/batches, relaygate docs/contract.md "Session uploads").
import assert from "node:assert/strict";
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer, type IncomingHttpHeaders, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { AgentHost } from "../src/host.ts";
import { accountId, EnrollmentCredential, eventOf, notLuhn, SessionUploader, transcriptPath } from "../src/sessions-upload.ts";

interface Req {
  headers: IncomingHttpHeaders;
  body: any;
}

interface FakeGate {
  server: Server;
  url: string;
  reqs: Req[];
  /** Status (and headers) for the next request; default 200. */
  answers: Array<{ status: number; headers?: Record<string, string> }>;
}

async function fakeGate(): Promise<FakeGate> {
  const g = { reqs: [] as Req[], answers: [] as FakeGate["answers"] } as FakeGate;
  g.server = createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      assert.equal(req.url, "/sessions/v1/delivery/batches");
      g.reqs.push({ headers: req.headers, body: JSON.parse(raw) });
      const a = g.answers.shift() ?? { status: 200 };
      res.writeHead(a.status, { "content-type": "application/json", ...a.headers });
      res.end(JSON.stringify(a.status === 200 ? { protocolVersion: 1, acceptanceLevel: "durable" } : { error: a.status === 403 ? "relaygate_denied" : "busy" }));
    });
  });
  await new Promise<void>((r) => g.server.listen(0, "127.0.0.1", r));
  const port = (g.server.address() as { port: number }).port;
  g.url = `http://127.0.0.1:${port}/sessions`;
  return g;
}

const SID = "11111111-2222-4333-8444-555555555555";

function setup() {
  const dir = mkdtempSync(join(tmpdir(), "sr-up-"));
  const home = join(dir, "home");
  const workdir = join(dir, "agents", "slack-c1-1700000000-000100");
  mkdirSync(workdir, { recursive: true });
  const proj = join(home, ".claude", "projects", workdir.replace(/[^A-Za-z0-9]/g, "-"));
  mkdirSync(proj, { recursive: true });
  const file = join(proj, `${SID}.jsonl`);
  writeFileSync(file, "");
  return { dir, home, workdir, file, stateDir: join(dir, "state") };
}

let n = 0;
const line = (type: "user" | "assistant", text: string, extra: Record<string, unknown> = {}) =>
  JSON.stringify({ type, uuid: `u-${++n}`, timestamp: new Date(1_763_000_000_000 + n * 1000).toISOString(), sessionId: SID, message: { role: type, content: type === "user" ? text : [{ type: "text", text }], ...(type === "assistant" ? { model: "claude-opus-5-5" } : {}) }, ...extra }) + "\n";

function uploader(g: FakeGate, s: ReturnType<typeof setup>, extra: Partial<ConstructorParameters<typeof SessionUploader>[0]> = {}) {
  const waits: number[] = [];
  const logs: string[] = [];
  const up = new SessionUploader({
    baseUrl: g.url,
    stateDir: s.stateDir,
    home: s.home,
    orgId: "org-1",
    workspaceId: "ws-1",
    sleep: async (ms) => void waits.push(ms),
    log: (m) => logs.push(m),
    ...extra,
  });
  return { up, waits, logs };
}

const target = (s: ReturnType<typeof setup>) => ({ agent: "slack-c1-1700000000-000100", token: "rg_agent", sessionId: SID, workdir: s.workdir, slack: { channel: "C1", thread_ts: "1700000000.000100" } });

test("uploads the transcript as the agent (rg_ in Authorization) in the native delivery format", async () => {
  const g = await fakeGate();
  const s = setup();
  writeFileSync(s.file, line("user", "hello there") + line("assistant", "hi") + JSON.stringify({ type: "summary", summary: "x" }) + "\n");
  const { up } = uploader(g, s);
  assert.equal(await up.upload(target(s)), "uploaded");
  assert.equal(g.reqs.length, 1);
  const { headers, body } = g.reqs[0]!;
  // No Sessions credential of our own: rg_ goes in Authorization and relaygate uses SESSIONS_TOKEN.
  assert.equal(headers.authorization, "Bearer rg_agent");
  assert.equal(headers["x-relaygate-token"], undefined);
  assert.equal(body.protocolVersion, 1);
  assert.equal(body.batch.mapping_version, "relayhistory-delivery-v1");
  assert.equal(body.batch.account_id, accountId("org-1", "ws-1"));
  const recs = body.batch.records;
  assert.equal(recs.length, 3);
  assert.ok(recs.every((r: any) => r.session_id === SID && r.origin_id === body.batch.origin_id));
  assert.equal(recs[0].kind, "session");
  assert.equal(recs[0].payload.title, "slack-c1-1700000000-000100 · Slack C1 thread 1700000000.000100");
  assert.equal(recs[0].payload.first_prompt, "hello there");
  assert.deepEqual(recs.slice(1).map((r: any) => [r.kind, r.payload.role, r.payload.text]), [["session_event", "user", "hello there"], ["session_event", "assistant", "hi"]]);
  g.server.close();
});

test("with its own Sessions credential: rg_ in X-Relaygate-Token, the credential in Authorization", async () => {
  const g = await fakeGate();
  const s = setup();
  writeFileSync(s.file, line("user", "q"));
  const { up } = uploader(g, s, { credential: { get: async () => "sh_at_device", invalidate: () => {} } });
  await up.upload(target(s));
  assert.equal(g.reqs[0]!.headers["x-relaygate-token"], "rg_agent");
  assert.equal(g.reqs[0]!.headers.authorization, "Bearer sh_at_device");
  g.server.close();
});

test("incremental: the cursor survives a restart, only new complete lines go up", async () => {
  const g = await fakeGate();
  const s = setup();
  writeFileSync(s.file, line("user", "one") + line("assistant", "two"));
  assert.equal(await uploader(g, s).up.upload(target(s)), "uploaded");
  // Nothing new, and a fresh uploader (a restart) reads the cursor from disk.
  assert.equal(await uploader(g, s).up.upload(target(s)), "nothing");
  // A partial line (Claude still writing) is not sent until it is complete.
  appendFileSync(s.file, line("user", "three") + '{"type":"assistant","uu');
  assert.equal(await uploader(g, s).up.upload(target(s)), "uploaded");
  assert.deepEqual(g.reqs[1]!.body.batch.records.slice(1).map((r: any) => r.payload.text), ["three"]);
  assert.equal(g.reqs.length, 2);
  g.server.close();
});

test("splits large transcripts into batches and advances the cursor per batch", async () => {
  const g = await fakeGate();
  const s = setup();
  writeFileSync(s.file, Array.from({ length: 7 }, (_, i) => line(i % 2 ? "assistant" : "user", `m${i}`)).join(""));
  // Second batch fails for good: the first batch's lines are not sent again.
  g.answers.push({ status: 200 }, { status: 400 });
  const { up } = uploader(g, s, { maxRecords: 4 });
  assert.equal(await up.upload(target(s)), "failed");
  assert.equal(g.reqs.length, 2);
  assert.deepEqual(g.reqs[0]!.body.batch.records.slice(1).map((r: any) => r.payload.text), ["m0", "m1", "m2"]);
  assert.equal(await up.upload(target(s)), "uploaded");
  assert.deepEqual(g.reqs.slice(2).flatMap((r) => r.body.batch.records.slice(1).map((x: any) => x.payload.text)), ["m3", "m4", "m5", "m6"]);
  g.server.close();
});

test("a retried batch is byte-identical (idempotent), and 429/503 honor Retry-After", async () => {
  const g = await fakeGate();
  const s = setup();
  writeFileSync(s.file, line("user", "q") + line("assistant", "a"));
  g.answers.push({ status: 429, headers: { "retry-after": "7" } }, { status: 503, headers: { "retry-after": "2" } }, { status: 502 });
  const { up, waits } = uploader(g, s);
  assert.equal(await up.upload(target(s)), "uploaded");
  assert.equal(g.reqs.length, 4);
  assert.deepEqual(waits, [7000, 2000, 4000]);
  const first = JSON.stringify(g.reqs[0]!.body);
  assert.ok(g.reqs.every((r) => JSON.stringify(r.body) === first));
  g.server.close();
});

test("gives up after the attempt budget without moving the cursor", async () => {
  const g = await fakeGate();
  const s = setup();
  writeFileSync(s.file, line("user", "q"));
  g.answers.push({ status: 503 }, { status: 503 }, { status: 503 }, { status: 503 });
  const { up } = uploader(g, s);
  assert.equal(await up.upload(target(s)), "failed");
  assert.equal(g.reqs.length, 4);
  assert.equal(await up.upload(target(s)), "uploaded");
  g.server.close();
});

test("a 403 is final: logged without content, never retried, not even after a restart", async () => {
  const g = await fakeGate();
  const s = setup();
  writeFileSync(s.file, line("user", "secret question"));
  g.answers.push({ status: 403 });
  const { up, logs, waits } = uploader(g, s);
  assert.equal(await up.upload(target(s)), "denied");
  appendFileSync(s.file, line("assistant", "secret answer"));
  assert.equal(await uploader(g, s).up.upload(target(s)), "denied");
  assert.equal(g.reqs.length, 1);
  assert.deepEqual(waits, []);
  assert.ok(logs.some((l) => l.includes("403 relaygate_denied")));
  assert.ok(!logs.join("\n").includes("secret") && !logs.join("\n").includes("rg_agent"));
  g.server.close();
});

test("a 403 from Sessions behind the gate (not relaygate's) is not final", async () => {
  const g = await fakeGate();
  const s = setup();
  writeFileSync(s.file, line("user", "q"));
  g.answers.push({ status: 403, headers: { "x-test": "1" } });
  const { up } = uploader(g, s);
  // The fake answers relaygate_denied for 403s; make this one look like Sessions' own.
  g.server.removeAllListeners("request");
  g.server.on("request", (req, res) => {
    req.resume();
    req.on("end", () => {
      g.reqs.push({ headers: req.headers, body: null });
      const sessions403 = g.reqs.length === 1;
      res.writeHead(sessions403 ? 403 : 200, { "content-type": "application/json" }).end(JSON.stringify(sessions403 ? { error: { code: "forbidden" } } : {}));
    });
  });
  assert.equal(await up.upload(target(s)), "failed");
  assert.equal(await up.upload(target(s)), "uploaded");
  g.server.close();
});

test("a 401 refreshes the host's credential once", async () => {
  const g = await fakeGate();
  const s = setup();
  writeFileSync(s.file, line("user", "q"));
  g.answers.push({ status: 401 });
  let v = 0;
  const { up } = uploader(g, s, { credential: { get: async () => `sh_at_${v}`, invalidate: () => void v++ } });
  assert.equal(await up.upload(target(s)), "uploaded");
  assert.deepEqual(g.reqs.map((r) => r.headers.authorization), ["Bearer sh_at_0", "Bearer sh_at_1"]);
  g.server.close();
});

test("transcript parsing: tool results and meta lines are not messages; tool calls are named", () => {
  assert.equal(eventOf(JSON.stringify({ type: "user", uuid: "a", message: { content: [{ type: "tool_result", content: "x" }] } })), null);
  assert.equal(eventOf(JSON.stringify({ type: "user", uuid: "a", isMeta: true, message: { content: "x" } })), null);
  assert.equal(eventOf("not json"), null);
  const e = eventOf(JSON.stringify({ type: "assistant", uuid: "b", timestamp: "2026-11-16T00:00:00Z", message: { model: "m", content: [{ type: "text", text: "looking" }, { type: "tool_use", name: "Read" }] } }));
  assert.deepEqual(e, { id: "b", role: "assistant", text: "looking\n[tool: Read]", ts: Date.parse("2026-11-16T00:00:00Z"), model: "m" });
});

test("transcriptPath finds the session file under any project directory", () => {
  const s = setup();
  assert.equal(transcriptPath(s.home, s.workdir, SID), s.file);
  assert.equal(transcriptPath(s.home, "/elsewhere", SID), s.file);
  assert.equal(transcriptPath(s.home, s.workdir, "nope"), null);
});

test("enrollment credential: exchanges the key once, stores and refreshes the rotating session", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sr-cred-"));
  const calls: Array<{ path: string; body: any }> = [];
  let i = 0;
  const fetchFn = (async (url: string, init: RequestInit) => {
    const path = new URL(url).pathname;
    const body = JSON.parse(init.body as string);
    calls.push({ path, body });
    const exp = new Date(Date.now() + 24 * 3600_000).toISOString();
    i++;
    if (path === "/api/v1/auth/enrollment/token") return Response.json({ access_token: `sh_at_${i}`, refresh_token: `sh_rt_${i}`, access_token_expires_at: exp });
    return Response.json({ accessToken: `sh_at_${i}`, refreshToken: `sh_rt_${i}`, accessTokenExpiresAt: exp });
  }) as typeof fetch;
  const stateFile = join(dir, "cred.json");
  const mk = () => new EnrollmentCredential({ controlUrl: "http://control", enrollmentKey: () => "sh_ek_once", stateFile, hostName: "host", fetch: fetchFn });
  const c = mk();
  assert.equal(await c.get(), "sh_at_1");
  assert.equal(await mk().get(), "sh_at_1"); // still fresh, from disk
  c.invalidate();
  assert.equal(await c.get(), "sh_at_2");
  assert.deepEqual(calls.map((x) => x.path), ["/api/v1/auth/enrollment/token", "/api/v1/auth/token/refresh"]);
  assert.equal(calls[1]!.body.refreshToken, "sh_rt_1");
  assert.equal(JSON.parse(readFileSync(stateFile, "utf8")).refreshToken, "sh_rt_2");
});

test("the host uploads after each turn and on rejoin, with the agent's own token and its Slack thread", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sr-host-"));
  const uploads: Array<Record<string, unknown>> = [];
  const mkHost = () =>
    new AgentHost({
      routerName: "slack-router",
      channel: "slack",
      dataDir: dir,
      connect: async (name) => ({ token: `rg_${name}`, client: { reply: async () => ({ id: "r1" }) } }),
      runTurn: async (t) => ({ text: "ok", sessionId: t.sessionId, error: false }),
      sessionUpload: async (u) => void uploads.push(u),
    });
  const host = mkHost();
  await host.onEvent({
    type: "message.created",
    channel: "slack",
    message: {
      id: "m1",
      agentName: "slack-router",
      text: "hi",
      data: { kind: "slack.inbound", target: "slack-a", session: { id: SID, resume: false }, roster: [], slack: { team: "T1", channel: "C1", thread_ts: "1.2", ts: "1.2", user: "U1", participants: ["U1"] } },
    },
  });
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(uploads, [{ agent: "slack-a", token: "rg_slack-a", sessionId: SID, workdir: join(dir, "agents", "slack-a"), slack: { channel: "C1", thread_ts: "1.2" } }]);
  await mkHost().rejoinKnown();
  await new Promise((r) => setImmediate(r));
  assert.equal(uploads.length, 2);
  assert.deepEqual(uploads[1], { agent: "slack-a", token: "rg_slack-a", sessionId: SID, workdir: join(dir, "agents", "slack-a") });
});

test("timestamps are kept clear of the Luhn check Sessions scrubs", () => {
  // 1763000000000 + k: find one that passes Luhn, and check it is moved by the smallest step.
  let ms = 1_763_000_000_000;
  const luhn = (n: number) => String(n).split("").reverse().map(Number).reduce((s, d, i) => s + (i % 2 ? (d * 2 > 9 ? d * 2 - 9 : d * 2) : d), 0) % 10 === 0;
  while (!luhn(ms)) ms++;
  assert.ok(notLuhn(ms) > ms && notLuhn(ms) - ms < 10 && !luhn(notLuhn(ms)));
  assert.equal(notLuhn(ms + 1), luhn(ms + 1) ? notLuhn(ms + 1) : ms + 1);
});
