// The headless session uploader against a fake relaygate Sessions proxy
// (POST /sessions/v1/delivery/batches, relaygate docs/contract.md "Session uploads").
import assert from "node:assert/strict";
import fs, { appendFileSync, mkdirSync, mkdtempSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { createServer, type IncomingHttpHeaders, type Server } from "node:http";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { AgentHost } from "../src/host.ts";
import { accountId, EnrollmentCredential, eventOf, notLuhn, readLinesFrom, SessionUploader, transcriptPath } from "../src/sessions-upload.ts";

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

test("an unexpected error (cursor write fails) resolves as failed: no rejection, the queue keeps working", async () => {
  const g = await fakeGate();
  const s = setup();
  writeFileSync(s.file, line("user", "q"));
  const { up, logs } = uploader(g, s);
  // A directory where the cursor's temp file goes: writing the cursor throws EISDIR.
  mkdirSync(join(s.stateDir, `${SID}.json.tmp`), { recursive: true });
  const unhandled: unknown[] = [];
  const onUnhandled = (e: unknown) => void unhandled.push(e);
  process.on("unhandledRejection", onUnhandled);
  try {
    assert.equal(await up.upload(target(s)), "failed");
    await new Promise((r) => setTimeout(r, 20));
    assert.deepEqual(unhandled, []);
    assert.ok(logs.some((l) => l.includes("EISDIR")));
    // The next upload for the same session still runs.
    assert.equal(await up.upload(target(s)), "failed");
    assert.equal(g.reqs.length, 2);
  } finally {
    process.off("unhandledRejection", onUnhandled);
    g.server.close();
  }
});

test("batches are measured in UTF-8 bytes, envelope and session record included", async () => {
  const g = await fakeGate();
  const s = setup();
  // 20 messages of 3000 CJK characters: 9000 UTF-8 bytes each, but only 3000 UTF-16 units.
  writeFileSync(s.file, Array.from({ length: 20 }, (_, i) => line(i % 2 ? "assistant" : "user", "汉".repeat(3000))).join(""));
  const raw: number[] = [];
  const fetchFn = (async (url: string, init: RequestInit) => {
    raw.push(Buffer.byteLength(init.body as string, "utf8"));
    return fetch(url, init);
  }) as typeof fetch;
  const maxBytes = 64 * 1024;
  const { up } = uploader(g, s, { maxBytes, fetch: fetchFn });
  try {
    assert.equal(await up.upload(target(s)), "uploaded");
    assert.ok(raw.length > 1);
    for (const n of raw) assert.ok(n <= maxBytes, `request of ${n} bytes exceeds ${maxBytes}`);
    assert.equal(g.reqs.flatMap((r) => r.body.batch.records.slice(1)).length, 20);
  } finally {
    g.server.close();
  }
});

test("reads a bounded window: a backlog goes up window by window, one batch at a time", async () => {
  const g = await fakeGate();
  const s = setup();
  const lines = Array.from({ length: 12 }, (_, i) => line(i % 2 ? "assistant" : "user", `w${i}`));
  writeFileSync(s.file, lines.join(""));
  // A window smaller than the file: it holds a few lines at a time.
  const window = Buffer.byteLength(lines[0]!) * 3 + 10;
  const { up } = uploader(g, s, { readBytes: window });
  try {
    assert.equal(await up.upload(target(s)), "uploaded");
    assert.ok(g.reqs.length >= 4);
    assert.deepEqual(g.reqs.flatMap((r) => r.body.batch.records.slice(1).map((x: any) => x.payload.text)), lines.map((_, i) => `w${i}`));
    // The session record moves forward with each batch (newer revision wins).
    const revs = g.reqs.map((r) => r.body.batch.records[0].revision);
    assert.deepEqual([...revs].sort((a, b) => a - b), revs);
  } finally {
    g.server.close();
  }
});

test("readLinesFrom grows the window for a line longer than it, and holds back a partial tail", () => {
  const dir = mkdtempSync(join(tmpdir(), "sr-read-"));
  const f = join(dir, "t.jsonl");
  writeFileSync(f, "x".repeat(100) + "\nab\ncd");
  const r = readLinesFrom(f, 0, 8);
  // The window doubled until it held the long line whole (here, to the whole file).
  assert.deepEqual(r.lines.map((l) => [l.text.length, l.start, l.end]), [[100, 0, 101], [2, 101, 104]]);
  assert.equal(r.end, 104);
  const r2 = readLinesFrom(f, 101, 8);
  assert.deepEqual(r2.lines.map((l) => l.text), ["ab"]);
  assert.equal(r2.end, 104);
  assert.deepEqual(readLinesFrom(f, 104, 8).lines, []);
});

/** Counts window reads (and the bytes each one covered) through the uploader's reader seam. */
function countingReader() {
  const reads: Array<{ offset: number; bytes: number }> = [];
  const readLines: typeof readLinesFrom = (file, offset, maxBytes) => {
    const r = readLinesFrom(file, offset, maxBytes);
    reads.push({ offset, bytes: r.readEnd - offset });
    return r;
  };
  return { reads, readLines };
}

test("a backlog of short lines is read once per window, not once per batch", async () => {
  const g = await fakeGate();
  const s = setup();
  const lines = Array.from({ length: 400 }, (_, i) => line(i % 2 ? "assistant" : "user", `s${i}`));
  writeFileSync(s.file, lines.join(""));
  const size = Buffer.byteLength(lines.join(""));
  const { reads, readLines } = countingReader();
  // 4 events per batch (100 batches); a window holding the whole backlog.
  const { up } = uploader(g, s, { maxRecords: 5, readBytes: size + 1, readLines });
  try {
    assert.equal(await up.upload(target(s)), "uploaded");
    assert.equal(g.reqs.length, 100);
    assert.deepEqual(g.reqs.flatMap((r) => r.body.batch.records.slice(1).map((x: any) => x.payload.text)), lines.map((_, i) => `s${i}`));
    // One window read plus the final empty read: before, this was one read of the remaining window per batch
    // (101 reads, about 50 times the file size in bytes).
    assert.equal(reads.length, 2);
    assert.equal(reads.reduce((a, r) => a + r.bytes, 0), size);
  } finally {
    g.server.close();
  }
});

test("the cursor after each batch is the end of the last line sent, windowed or not", async () => {
  const lines = Array.from({ length: 12 }, (_, i) => line(i % 2 ? "assistant" : "user", `c${i}`));
  const ends = lines.map((_, i) => Buffer.byteLength(lines.slice(0, i + 1).join("")));
  for (const readBytes of [Buffer.byteLength(lines[0]!) * 3 + 10, 1 << 20]) {
    const g = await fakeGate();
    const s = setup();
    writeFileSync(s.file, lines.join(""));
    const cursors: number[] = [];
    // The cursor on disk when each request arrives is the one persisted by the batch before it.
    const fetchFn = (async (url: string, init: RequestInit) => {
      let off = 0;
      try {
        off = JSON.parse(readFileSync(join(s.stateDir, `${SID}.json`), "utf8")).offset;
      } catch {}
      cursors.push(off);
      return fetch(url, init);
    }) as typeof fetch;
    const { up } = uploader(g, s, { maxRecords: 4, readBytes, fetch: fetchFn });
    try {
      assert.equal(await up.upload(target(s)), "uploaded");
      // Before each request the cursor is the end of the last line of everything sent so far (all events here).
      let sent = 0;
      cursors.forEach((c, k) => {
        assert.equal(c, sent ? ends[sent - 1] : 0, `cursor before batch ${k}`);
        sent += g.reqs[k]!.body.batch.records.length - 1;
      });
      assert.equal(sent, 12);
      assert.ok(cursors.length >= 4);
      assert.equal(JSON.parse(readFileSync(join(s.stateDir, `${SID}.json`), "utf8")).offset, ends[11]);
    } finally {
      g.server.close();
    }
  }
});

test("a window carried across batches is dropped when the file shrinks or is replaced", async () => {
  const lines = Array.from({ length: 12 }, (_, i) => line(i % 2 ? "assistant" : "user", `m${i}`));
  const texts = (g: FakeGate) => g.reqs.flatMap((r) => r.body.batch.records.slice(1).map((x: any) => x.payload.text));
  const afterFirst = (s: ReturnType<typeof setup>, change: () => void) =>
    (async (url: string, init: RequestInit) => {
      const res = await fetch(url, init);
      if (!changed.has(s)) {
        changed.add(s);
        change();
      }
      return res;
    }) as typeof fetch;
  const changed = new WeakSet<object>();

  // Truncated after the first batch to less than the cursor: nothing more goes up (no stale lines from memory).
  {
    const g = await fakeGate();
    const s = setup();
    writeFileSync(s.file, lines.join(""));
    const { up } = uploader(g, s, { maxRecords: 5, readBytes: 1 << 20, fetch: afterFirst(s, () => writeFileSync(s.file, lines[0]!)) });
    try {
      assert.equal(await up.upload(target(s)), "uploaded");
      assert.deepEqual(texts(g), ["m0", "m1", "m2", "m3"]);
    } finally {
      g.server.close();
    }
  }
  // Replaced by a new file (new inode) with the same line lengths: the next batch comes from the new file.
  {
    const g = await fakeGate();
    const s = setup();
    writeFileSync(s.file, lines.join(""));
    const swap = () => {
      writeFileSync(`${s.file}.new`, lines.join("").replace(/"m(\d)/g, '"z$1'));
      renameSync(`${s.file}.new`, s.file);
    };
    const { up } = uploader(g, s, { maxRecords: 5, readBytes: 1 << 20, fetch: afterFirst(s, swap) });
    try {
      assert.equal(await up.upload(target(s)), "uploaded");
      assert.deepEqual(texts(g), ["m0", "m1", "m2", "m3", ...Array.from({ length: 8 }, (_, i) => `z${i + 4}`)]);
    } finally {
      g.server.close();
    }
  }
});

test("readLinesFrom rejects a window that is not a positive integer, instead of looping", () => {
  const dir = mkdtempSync(join(tmpdir(), "sr-read-"));
  const f = join(dir, "t.jsonl");
  writeFileSync(f, "abc\n");
  for (const bad of [0, -1, 1.5, NaN, Infinity]) assert.throws(() => readLinesFrom(f, 0, bad), { name: "RangeError", message: /positive integer/ });
  assert.equal(readLinesFrom(f, 0, 1).lines.length, 1);
});

test("readLinesFrom stops at a short read when the file shrank after its size was taken", () => {
  const dir = mkdtempSync(join(tmpdir(), "sr-read-"));
  const f = join(dir, "t.jsonl");
  writeFileSync(f, "abc\ndef");
  // A truncation between fstat and read, made deterministic: fstat reports more bytes than the file holds.
  const real = fs.fstatSync;
  fs.fstatSync = ((fd: number) => {
    const st = real(fd);
    st.size += 1000;
    return st;
  }) as typeof real;
  syncBuiltinESMExports();
  try {
    // "def" has no newline and the read comes back short of the reported size: return, do not grow the window forever.
    const r = readLinesFrom(f, 4, 2);
    assert.deepEqual([r.lines.length, r.end, r.readEnd], [0, 4, 7]);
    // At the real end of the file the read returns nothing at all.
    const r0 = readLinesFrom(f, 7, 2);
    assert.deepEqual([r0.lines.length, r0.end, r0.readEnd], [0, 7, 7]);
    // Complete lines before the short tail are still returned.
    assert.deepEqual(readLinesFrom(f, 0, 64).lines.map((l) => l.text), ["abc"]);
  } finally {
    fs.fstatSync = real;
    syncBuiltinESMExports();
  }
});
