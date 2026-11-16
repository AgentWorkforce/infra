/**
 * Audit shipping (ship.ts): new lines go to CloudWatch verbatim and in order,
 * the cursor only moves after a batch is accepted, and a local log that was
 * edited (chain broken, or rewritten after shipping) ships nothing.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendAudit, type AuditLine } from "../broker/src/audit.ts";
import { cursorPath, MAX_BATCH_EVENTS, shipAudit, type LogEvent, type LogSink } from "../broker/src/ship.ts";

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

test("no audit log yet: nothing to do; a corrupt cursor is reported, not trusted", async () => {
  const dir = mkdtempSync(join(tmpdir(), "broker-ship-"));
  const sink: LogSink = { async put() { throw new Error("must not be called"); } };
  assert.deepEqual(await shipAudit(join(dir, "audit.jsonl"), dir, sink), { ok: true, shipped: 0, problems: [] });
  writeFileSync(cursorPath(dir), JSON.stringify({ seq: 0, hash: "nope" }));
  const r = await shipAudit(join(dir, "audit.jsonl"), dir, sink);
  assert.equal(r.ok, false);
  assert.match(r.problems[0]!, /not a valid cursor/);
});
