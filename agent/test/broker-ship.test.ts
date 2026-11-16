/**
 * Audit shipping (ship.ts): new lines go to CloudWatch verbatim and in order,
 * the cursor only moves after a batch is accepted, and a local log that was
 * edited (chain broken, or rewritten after shipping) ships nothing.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendAudit, MAX_AUDIT_LIST, verifyAudit, type AuditLine } from "../broker/src/audit.ts";
import { withLock } from "../broker/src/lock.ts";
import { awsCliLogs, cursorPath, MAX_BATCH_EVENTS, MAX_EVENT_BYTES, shipAudit, type LogEvent, type LogSink } from "../broker/src/ship.ts";

const NOW = new Date("2026-11-16T12:00:00Z");

function setup(n: number) {
  const dir = mkdtempSync(join(tmpdir(), "broker-ship-"));
  const audit = join(dir, "audit.jsonl");
  for (let i = 0; i < n; i++) appendAudit(audit, { kind: "requested", requestId: `cb-${i.toString(16).padStart(12, "0")}`, purpose: "ship test" }, NOW);
  const batches: LogEvent[][] = [];
  const sink: LogSink = { async put(events) { batches.push(events); } };
  return { dir, audit, batches, sink };
}

test("ships every line verbatim, in order, then only the new ones", async () => {
  const { dir, audit, batches, sink } = setup(3);
  const r = await shipAudit(audit, dir, sink, () => NOW);
  assert.deepEqual([r.ok, r.shipped], [true, 3]);
  const local = readFileSync(audit, "utf8").split("\n").filter(Boolean);
  assert.deepEqual(batches.flat().map((e) => e.message), local);
  assert.equal(r.cursor!.seq, 3);
  assert.equal(r.cursor!.hash, (JSON.parse(local[2]!) as AuditLine).hash);

  const again = await shipAudit(audit, dir, sink, () => NOW);
  assert.deepEqual([again.ok, again.shipped], [true, 0], "nothing new: nothing sent");
  assert.equal(batches.length, 1);

  appendAudit(audit, { kind: "denied", requestId: "cb-00000000000a" }, NOW);
  const next = await shipAudit(audit, dir, sink, () => NOW);
  assert.deepEqual([next.ok, next.shipped, next.cursor!.seq], [true, 1, 4]);
  assert.match(batches[1]![0]!.message, /"seq":4/);
});

test("a failed batch keeps the cursor where it was; the next run sends it again", async () => {
  const { dir, audit, batches } = setup(2);
  const failing: LogSink = { async put() { throw new Error("AccessDeniedException"); } };
  const r = await shipAudit(audit, dir, failing, () => NOW);
  assert.equal(r.ok, false);
  assert.match(r.problems[0]!, /AccessDeniedException/);
  assert.ok(!existsSync(cursorPath(dir)), "no cursor until CloudWatch accepts a batch");
  const ok = await shipAudit(audit, dir, { async put(e) { batches.push(e); } }, () => NOW);
  assert.deepEqual([ok.ok, ok.shipped], [true, 2]);
});

test("large logs go in batches under CloudWatch's limits", async () => {
  const { dir, audit, batches, sink } = setup(MAX_BATCH_EVENTS + 5);
  const r = await shipAudit(audit, dir, sink, () => NOW);
  assert.deepEqual([r.ok, r.shipped], [true, MAX_BATCH_EVENTS + 5]);
  assert.deepEqual(batches.map((b) => b.length), [MAX_BATCH_EVENTS, 5]);
});

test("an edited local log ships nothing: a broken chain, or a line rewritten after it was shipped", async () => {
  // Broken chain before anything was shipped.
  {
    const { dir, audit, batches, sink } = setup(3);
    const lines = readFileSync(audit, "utf8").split("\n").filter(Boolean);
    lines[1] = lines[1]!.replace("ship test", "edited");
    writeFileSync(audit, lines.join("\n") + "\n");
    const r = await shipAudit(audit, dir, sink, () => NOW);
    assert.equal(r.ok, false);
    assert.match(r.problems[0]!, /does not verify; nothing was shipped/);
    assert.equal(batches.length, 0);
  }
  // Shipped, then the whole file was rebuilt as a new valid chain (so verifyAudit alone passes).
  {
    const { dir, audit, batches, sink } = setup(2);
    await shipAudit(audit, dir, sink, () => NOW);
    writeFileSync(audit, "");
    appendAudit(audit, { kind: "requested", requestId: "cb-0000000000ff", purpose: "forged history" }, NOW);
    appendAudit(audit, { kind: "requested", requestId: "cb-0000000000fe", purpose: "forged history" }, NOW);
    appendAudit(audit, { kind: "requested", requestId: "cb-0000000000fd", purpose: "forged history" }, NOW);
    const r = await shipAudit(audit, dir, sink, () => NOW);
    assert.equal(r.ok, false);
    assert.match(r.problems[0]!, /no longer has line 2 as shipped/);
    assert.equal(batches.length, 1, "nothing after the first, honest batch");
  }
});

test("review fixes: a half-written last line waits, the state lock isn't needed, an oversized old line ships as a stub", async () => {
  // A line still being appended (no newline yet) isn't shipped and isn't a broken chain.
  {
    const { dir, audit, batches, sink } = setup(2);
    appendFileSync(audit, '{"seq":3,"ts":"2026-11-16T12:00:00.000Z","pr');
    const r = await shipAudit(audit, dir, sink, () => NOW);
    assert.deepEqual([r.ok, r.shipped, r.cursor!.seq], [true, 2, 2]);
    assert.equal(batches.flat().length, 2);
  }
  // Shipping runs while a request holds the broker's state lock.
  {
    const { dir, audit, sink } = setup(1);
    const r = await withLock(dir, () => shipAudit(audit, dir, sink, () => NOW), 5_000);
    assert.equal(r.ok, true);
  }
  // A line over CloudWatch's limit (written before lines were bounded) goes as a stub and the cursor moves on.
  {
    const { dir, audit, batches, sink } = setup(1);
    const prevLine = JSON.parse(readFileSync(audit, "utf8").trim()) as AuditLine;
    const body = { seq: 2, ts: NOW.toISOString(), prev: prevLine.hash, kind: "denied", requestId: "cb-0000000000aa", reasons: Array.from({ length: 12_000 }, () => "resources: an entry is empty") };
    const hash = createHash("sha256").update(body.prev).update("\n").update(JSON.stringify(body)).digest("hex");
    appendFileSync(audit, JSON.stringify({ ...body, hash }) + "\n");
    appendAudit(audit, { kind: "requested", requestId: "cb-0000000000ab" }, NOW);
    const r = await shipAudit(audit, dir, sink, () => NOW);
    assert.deepEqual([r.ok, r.shipped, r.cursor!.seq], [true, 3, 3]);
    const stub = JSON.parse(batches.flat()[1]!.message) as { seq: number; hash: string; oversized: { bytes: number; sha256: string } };
    assert.deepEqual([stub.seq, stub.hash], [2, hash]);
    assert.ok(stub.oversized.bytes > MAX_EVENT_BYTES);
    assert.ok(batches.flat().every((e) => Buffer.byteLength(e.message) <= MAX_EVENT_BYTES));
  }
});

test("new audit lines are bounded before hashing: 10,000 reasons can't make a line CloudWatch rejects", () => {
  const dir = mkdtempSync(join(tmpdir(), "broker-ship-"));
  const line = appendAudit(join(dir, "audit.jsonl"), { kind: "denied", requestId: "cb-0000000000ac", purpose: "x".repeat(50_000), reasons: Array.from({ length: 10_000 }, () => "resources: an entry is empty") }, NOW);
  assert.equal(line.reasons!.length, MAX_AUDIT_LIST + 1);
  assert.match(line.reasons!.at(-1)!, /9900 more/);
  assert.match(line.purpose!, /48000 more characters/);
  assert.ok(Buffer.byteLength(JSON.stringify(line)) < 64 * 1024);
  assert.deepEqual(verifyAudit(join(dir, "audit.jsonl")), [], "the chain covers the bounded line");
});

test("the AWS CLI sink: the batch goes in a 0600 file it removes, never on stdin or a command line; a missing stream is created", async () => {
  const dir = mkdtempSync(join(tmpdir(), "broker-ship-"));
  const bin = join(dir, "bin");
  mkdirSync(bin);
  // A fake aws: logs its arguments, copies the --cli-input-json file, and says the stream is missing once.
  const fake = [
    "#!/bin/sh",
    `echo "$*" >> ${dir}/calls`,
    'for a in "$@"; do case "$a" in file://*) f=${a#file://}; stat -c %a "$f" >> ' + dir + "/modes; cat \"$f\" >> " + dir + "/sent; echo >> " + dir + "/sent;; esac; done",
    `if [ "$2" = put-log-events ] && [ ! -f ${dir}/created ]; then echo "An error occurred (ResourceNotFoundException) when calling the PutLogEvents operation" >&2; exit 254; fi`,
    `if [ "$2" = create-log-stream ]; then touch ${dir}/created; fi`,
    "echo '{}'",
  ].join("\n");
  writeFileSync(join(bin, "aws"), fake + "\n", { mode: 0o755 });
  const oldPath = process.env.PATH;
  process.env.PATH = `${bin}:${oldPath}`;
  try {
    const shipTo = join(dir, "state", "ship");
    mkdirSync(shipTo, { recursive: true });
    await awsCliLogs("/aws-cred-broker/audit", "layered-infra-ops", shipTo, "aws-cred-broker", "us-east-1").put([{ timestamp: 1, message: '{"seq":1}' }]);
  } finally {
    process.env.PATH = oldPath;
  }
  const calls = readFileSync(join(dir, "calls"), "utf8").trim().split("\n");
  assert.equal(calls.length, 3, "put, create stream, put again");
  assert.match(calls[0]!, /^logs put-log-events --cli-input-json file:\/\/\S+\/ship\/batch\.json --profile aws-cred-broker --region us-east-1/);
  assert.match(calls[1]!, /^logs create-log-stream --log-group-name \/aws-cred-broker\/audit --log-stream-name layered-infra-ops/);
  assert.ok(calls.every((c) => !c.includes('"seq"')), "events never on a command line");
  assert.deepEqual(readFileSync(join(dir, "modes"), "utf8").trim().split("\n"), ["600", "600"]);
  const sent = JSON.parse(readFileSync(join(dir, "sent"), "utf8").trim().split("\n")[0]!) as { logGroupName: string; logStreamName: string; logEvents: LogEvent[] };
  assert.deepEqual(sent, { logGroupName: "/aws-cred-broker/audit", logStreamName: "layered-infra-ops", logEvents: [{ timestamp: 1, message: '{"seq":1}' }] });
  assert.ok(!existsSync(join(dir, "state", "ship", "batch.json")), "the batch file is removed");
});

test("cli.ts ship-audit sends to BROKER_AUDIT_LOG_REGION, not the host's AWS_REGION", () => {
  const dir = mkdtempSync(join(tmpdir(), "broker-ship-cli-"));
  const bin = join(dir, "bin");
  mkdirSync(bin);
  writeFileSync(join(bin, "aws"), `#!/bin/sh\necho "$*" >> ${dir}/calls\necho '{}'\n`, { mode: 0o755 });
  mkdirSync(join(dir, "state"));
  appendAudit(join(dir, "state", "audit.jsonl"), { kind: "requested", requestId: "cb-0000000000b1" }, NOW);
  const cli = new URL("../broker/src/cli.ts", import.meta.url).pathname;
  const env: NodeJS.ProcessEnv = { ...process.env, PATH: `${bin}:${process.env.PATH}`, BROKER_STATE_DIR: join(dir, "state"), BROKER_DELIVERY_DIR: join(dir, "creds"), AWS_REGION: "us-west-2", BROKER_AUDIT_LOG_REGION: "us-east-1", BROKER_AUDIT_LOG_GROUP: "/aws-cred-broker/audit", BROKER_AUDIT_LOG_STREAM: "layered-infra-ops" };
  delete env.BROKER_RELAY_TOKEN_FILE;
  const out = JSON.parse(execFileSync(process.execPath, ["--no-warnings", cli, "ship-audit"], { env, encoding: "utf8" })) as { ok: boolean; shipped: number };
  assert.deepEqual([out.ok, out.shipped], [true, 1]);
  const calls = readFileSync(join(dir, "calls"), "utf8").trim().split("\n");
  assert.equal(calls.length, 1);
  assert.match(calls[0]!, /--region us-east-1\b/);
  assert.doesNotMatch(calls[0]!, /us-west-2/);
});

test("no audit log yet: nothing to do; a corrupt cursor is reported, not trusted", async () => {
  const dir = mkdtempSync(join(tmpdir(), "broker-ship-"));
  const sink: LogSink = { async put() { throw new Error("must not be called"); } };
  assert.deepEqual(await shipAudit(join(dir, "audit.jsonl"), dir, sink), { ok: true, shipped: 0, problems: [] });
  writeFileSync(cursorPath(dir), JSON.stringify({ seq: 0, hash: "nope" }));
  const r = await shipAudit(join(dir, "audit.jsonl"), dir, sink);
  assert.equal(r.ok, false);
  assert.match(r.problems[0]!, /cursor is not valid/);
});
